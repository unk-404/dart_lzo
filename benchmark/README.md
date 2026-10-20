# Benchmarks: `lzo_neo` (Dart) vs `liblzo2` 2.10 (C)

This directory is a development-only benchmark pipeline: it measures the public
`Lzo1x` API of this package against liblzo2 2.10 and renders one deterministic
SVG card (`assets/benchmarks.svg`) in CI. Nothing here is part of the published
package.

```
benchmark/
  dart/
    corpus.dart                 deterministic corpus shared with the C harness
    lzo1x_benchmark_test.dart   package:benchmark_test suite (public API only)
    canonical.dart              benchmark_test JSONL -> benchcat canonical JSON
  c/
    bench.c                     same corpus/operations against liblzo2 2.10
    CMakeLists.txt              build the harness (Windows/MSVC, Linux, macOS)
    Makefile                    build the harness against a system liblzo2
  benchcat.toml                 chart config: two series, title/subtitle/theme
```

The workflow that drives all of it is
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Corpus (identical in Dart and C)

Twelve blocks: 3 sizes x 4 corpus kinds. Every block is regenerated from a fixed
recipe, so ids, sizes and bytes never depend on the machine (the two
implementations were verified byte-identical with `lzo_bench --dump-corpus`).

| corpus    | bytes                                                              |
|-----------|--------------------------------------------------------------------|
| `random`  | xorshift32, seed `0x9E3779B9`, byte = `state >> 24`                 |
| `text`    | `README.md` repeated cyclically                                    |
| `zeros`   | `0x00`                                                             |
| `pattern` | the 16 bytes of `lzo1x-neo-bench!` repeated cyclically             |

Sizes: `64KiB` (65,536), `1MiB` (1,048,576) and `8MiB` (8,388,608) bytes.
The xorshift stream restarts for every block, so the 64 KiB block is a prefix of
the 1 MiB block, etc.

Corpus order is size-major, then kind-minor:

```
64KiB.random  64KiB.text  64KiB.zeros  64KiB.pattern
1MiB.random   1MiB.text   1MiB.zeros   1MiB.pattern
8MiB.random   8MiB.text   8MiB.zeros   8MiB.pattern
```

## Operations and benchmark ids

| operation    | measurement                                       | unit    | direction |
|--------------|---------------------------------------------------|---------|-----------|
| `compress`   | `Lzo1x.compressInto` / `lzo1x_1_compress`         | `MB/s`  | higher    |
| `decompress` | `Lzo1x.decompressInto` / `lzo1x_decompress_safe`  | `MB/s`  | higher    |
| `ratio`      | compressed bytes / original bytes                 | `x`     | lower     |

Ids are `lzo1x.<operation>.<size label>.<corpus>`, for example
`lzo1x.compress.1MiB.random` and `lzo1x.ratio.8MiB.pattern`. The C harness emits
the exact same ids; that is what lines the two series up in the chart.

Throughput is `ops/sec x block bytes / 1e6`, computed by `canonical.dart` from
the JSONL `throughput.value` that `benchmark_test` measured. Ratio rows are
derived by recompressing the same corpus, so they always describe the encoder
that produced the throughput numbers.

### Why the Dart ratio can beat liblzo2's

`liblzo2` builds `lzo1x_1` with `LZO_DETERMINISTIC=1`, which compresses in
independent 48 KiB windows and clears the dictionary at every window. A window
of periodic text therefore starts with a fresh literal run even when the same
bytes appeared a moment earlier in the previous window.

The Dart encoder keeps one dictionary for the whole block and only rejects an
entry when its distance exceeds `0xBFFF` (the largest distance LZO1X can
encode). Both streams are valid LZO1X and decode to the same bytes; the Dart
one simply reuses history that liblzo2 discards at a window boundary. That is
why the `text` ratios differ by up to ~10x (0.41 % vs 4.09 % on 8 MiB) while
`random` ratios are identical and `zeros`/`pattern` are close.

## Dart side

Run from the repository root (the text corpus is read from `README.md`):

```sh
# measurement engine: package:benchmark_test, AOT compiled
dart run benchmark_test --compile aot --output jsonl \
    benchmark/dart/lzo1x_benchmark_test.dart > build/bench/dart-aot.jsonl

# adapter: benchmark_test JSONL -> benchcat canonical JSON
dart run benchmark/dart/canonical.dart \
    build/bench/dart-aot.jsonl build/bench/dart-aot.json
```

`benchmark_test` writes one JSON object per benchmark:

```json
{"formatVersion":1,"name":"lzo1x.compress.64KiB.zeros","compiler":"aot","throughput":{"value":9323.178350346912,"unit":"ops/sec"},"statistics":{"relativeMarginOfError":0.3558548153293804,"samples":18647},"latency":{"mean":107,"unit":"microseconds"}}
```

`canonical.dart` accepts names with or without a `group` prefix (it matches on
the known id suffix), ignores the reporter's progress lines, then writes:

```json
{
  "schema": "benchcat/report@1",
  "meta": {
    "tool": "benchmark_test",
    "tool_version": "0.1.2",
    "commit": "<GITHUB_SHA, when set>",
    "platform": { "os": "Linux", "arch": "x86_64" }
  },
  "benchmarks": [
    {
      "id": "lzo1x.compress.64KiB.random",
      "group": "Compress (LZO1X-1)",
      "label": "random 64KiB",
      "note": "64KiB block, fast1",
      "unit": "MB/s",
      "value": 80.908635,
      "direction": "higher",
      "params": { "corpus": "random", "size": "64KiB", "bytes": 65536, "level": "fast1" },
      "stats": { "rme_pct": 1.234, "samples": 7 }
    }
  ]
}
```

36 rows = 12 blocks x (compress, decompress, ratio), grouped on the card as
`Compress (LZO1X-1)`, `Decompress` and `Ratio (compressed/original)`. benchcat
prints ratio values with two decimals, so a 0.4 % ratio shows as `0.00×` in the
label while the bar still shows its relative size; the JSON keeps the exact
value.

## C side (liblzo2 2.10)

The harness always calls `lzo1x_1_compress` (LZO1X-1, 64 KiB work memory) and
`lzo1x_decompress_safe`, with a warm-up iteration and a per-operation minimum of
1 s (or 100,000 iterations, whichever comes first). It prints progress on stderr
and the canonical JSON on stdout or `--out`.

### Linux / macOS: system liblzo2

```sh
sudo apt-get install -y liblzo2-dev        # Debian/Ubuntu
make -C benchmark/c
./benchmark/c/lzo_bench --text README.md --out build/bench/liblzo2-c.json
```

To use a locally built liblzo2 prefix (`include/lzo/*.h` + `lib/liblzo2.a`):

```sh
make -C benchmark/c LZO_PREFIX=/opt/lzo-2.10
```

### Windows: liblzo2 2.10 built from the official tarball with CMake/MSVC

```sh
mkdir -p build/deps
curl -fsSL -o build/deps/lzo-2.10.tar.gz \
  https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz
tar -xzf build/deps/lzo-2.10.tar.gz -C build/deps
cmake -S build/deps/lzo-2.10 -B build/deps/lzo-build \
  -DENABLE_STATIC=ON -DENABLE_SHARED=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/deps/lzo-build --config Release --target lzo_static_lib

cmake -S benchmark/c -B build/c \
  -DLZO_INCLUDE_DIR="$(pwd -W)/build/deps/lzo-2.10/include" \
  -DLZO_LIBRARY="$(pwd -W)/build/deps/lzo-build/Release/lzo2.lib"
cmake --build build/c --config Release
./build/c/Release/lzo_bench.exe --text README.md --out build/bench/liblzo2-c.json
```

`pwd -W` is Git Bash's Windows-style working directory; a native shell can pass
`D:/...` paths directly.

`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is only needed for CMake 4.x, which dropped
compatibility with the `cmake_minimum_required(VERSION 3.0)` used by lzo-2.10;
older CMake versions ignore the unused variable with a warning.

`CMakeLists.txt` also accepts `-DLZO_ROOT=<prefix>`, a prefix with
`include/lzo/lzo1x.h` and `lib/`, for example the output of
`cmake --install`.

## Render the card (CI only)

[`benchcat.toml`](benchcat.toml) declares the two series:

```toml
[[series]]
label = "Dart AOT"
input = "build/bench/dart-aot.json"
format = "json"

[[series]]
label = "liblzo2 2.10 (C)"
input = "build/bench/liblzo2-c.json"
format = "json"
```

The workflow renders it with the single action step (the action installs its own
binary and font catalogue — do not download, vendor or commit either):

```yaml
- uses: unk-404/benchcat@master
  with:
    config: benchmark/benchcat.toml
    format: json
    out: assets/benchmarks.svg
```

and commits `assets/benchmarks.svg` on the default branch when the bytes changed
(`chore(bench): refresh chart [skip ci]`).

## Determinism

- Fixed seeds and recipes; ids and row order are literal constants on both sides.
- No timestamps in either report; `meta.commit` only echoes `GITHUB_SHA`.
- The SVG is a pure function of the two reports, so an unchanged measurement
  produces byte-identical output and the commit step is a no-op.
- Benchmark *values* are wall-clock measurements and change run to run; that is
  the data, not nondeterminism in the pipeline.

## Local verification performed

- `dart analyze` clean.
- `dart compile exe benchmark/dart/lzo1x_benchmark_test.dart` succeeds.
- The full `benchmark_test` AOT suite ran: 24 JSONL records, all ids as above.
- `canonical.dart` emits 36 rows with the ids above.
- Dart and C corpora are byte-identical (`diff -r` of `--dump-corpus` /
  the Dart dump).
- The C harness builds with `make` and runs against liblzo2 2.10 on Linux
  (WSL, gcc), emitting 36 canonical rows.
- The two canonical files were rendered locally with a dev-only benchcat
  binary (`cargo install --git ...`, never in CI): 36 rows, 2 series,
  920x2238 SVG. Repeated renders are byte-identical.
- The Windows MSVC build and the benchcat GitHub Action itself run only in CI
  (no MSVC toolchain on the development machine); the workflow mirrors the
  locally verified commands.

