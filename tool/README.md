# Tooling: liblzo2 oracle, vector generation and differential tests

Everything here is developer tooling. Nothing in `lib/` depends on it, and CI
never refers to a local reference checkout: every path is passed with a flag or
an environment variable.

## Oracle (`tool/oracle/`)

`lzo_oracle.c` is a small CLI over liblzo2 2.10 covering the complete matrix:

```sh
lzo_oracle compress        <algo> <level> <in> <out>
lzo_oracle decompress      <algo> <in> <out> <outlen>
lzo_oracle compress-dict   <algo> <dict> <in> <out>
lzo_oracle decompress-dict <algo> <dict> <in> <out> <outlen>
lzo_oracle list
lzo_oracle version
```

`<algo>` is one of `lzo1 lzo1a lzo1b lzo1c lzo1f lzo1x lzo1y lzo1z lzo2a`;
`lzo_oracle list` prints every supported level. Dictionary commands exist for
`lzo1x`, `lzo1y` and `lzo1z` (999 only). The process exits non-zero with the
liblzo2 error code and message on failure.

Build it against an installed liblzo2 or a source-tree build:

```sh
make -C tool/oracle LZO_PREFIX=/opt/lzo-2.10
# or, for an in-tree build (src/.libs/liblzo2.a):
make -C tool/oracle \
  LZO_INCLUDE=/path/to/lzo-2.10/include \
  LZO_LIBDIR=/path/to/lzo-2.10/src/.libs
```

## Vectors (`tool/vectors/`)

Two fixture sets, both produced by liblzo2 and never by this package's encoder:

* `generate.dart` writes the LZO1X corpus plus `test/data/manifest.json`
  (`case`, `algorithm`, `level`, `source`, `size`, `sha256`, compressed size and
  digest).
* `generate_families.dart` writes `test/data/families/manifest.json` and one
  `.raw`/`.lzo` pair per (algorithm, level, corpus) across all nine families and
  36 compressor levels.

```sh
tool/vectors/generate.sh                 # LZO1X fixtures
tool/vectors/generate_families.sh        # all-family fixtures
LZO_PREFIX=/opt/lzo-2.10 tool/vectors/generate_families.sh
LZO_ORACLE=/path/to/lzo_oracle dart run tool/vectors/generate_families.dart
dart run tool/vectors/generate_families.dart --oracle /tmp/lzo_oracle --via-wsl
```

The committed fixtures are reproducible byte-for-byte with liblzo2 2.10; the CI
`differential` job regenerates both sets and fails on any `git diff`.

`test/data/**` is binary in `.gitattributes` and must stay that way: an EOL
conversion silently corrupts every fixture. The vector tests verify every size
and digest and assert the attribute is present.

## Differential (`tool/differential.dart`, `tool/differential_all.dart`)

`differential.dart` covers the LZO1X vectors: for every manifest entry it runs
liblzo2 compress -> Dart decompress, Dart compress -> liblzo2 decompress and the
Dart round-trip, and also checks that the oracle output equals the committed
block.

`differential_all.dart` covers the full matrix: every algorithm and level in
`test/data/families`, plus preset-dictionary cases for LZO1X/LZO1Y/LZO1Z.

```sh
dart run tool/differential.dart --oracle tool/oracle/lzo_oracle
dart run tool/differential_all.dart --oracle tool/oracle/lzo_oracle
dart run tool/differential_all.dart --oracle /tmp/lzo_oracle --via-wsl
```

Failures print the first differing byte. `--via-wsl` runs the Linux oracle from
Windows so the same suite can be exercised locally.
