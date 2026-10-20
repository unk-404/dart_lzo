# Tooling: liblzo2 oracle, vector generation and differential tests

Everything here is developer tooling. Nothing in `lib/` depends on it, and CI
never refers to a local reference checkout: every path is passed with a flag or
an environment variable.

## Oracle (`tool/oracle/`)

`lzo_oracle.c` is a small CLI over liblzo2 2.10:

```sh
lzo_oracle compress   <algo> <level> <in> <out>
lzo_oracle decompress <algo> <in> <out> <outlen>
lzo_oracle version
```

`<algo>` is `lzo1x`; `<level>` is 1, 11, 12, 15 or 999. The process exits
non-zero with the liblzo2 error code and message on failure.

Build it against an installed liblzo2 or a source-tree build:

```sh
make -C tool/oracle LZO_PREFIX=/opt/lzo-2.10
# or, for an in-tree build (src/.libs/liblzo2.a):
make -C tool/oracle \
  LZO_INCLUDE=/path/to/lzo-2.10/include \
  LZO_LIBDIR=/path/to/lzo-2.10/src/.libs
```

## Vectors (`tool/vectors/`)

`generate.dart` writes the corpus as raw bytes plus `test/data/manifest.json`
(`case`, `algorithm`, `level`, `source`, `size`, `sha256`, and the compressed
file's size and digest). The `.lzo` files are always produced by liblzo2, never
by this package's encoder.

```sh
tool/vectors/generate.sh                       # builds the oracle if needed
LZO_PREFIX=/opt/lzo-2.10 tool/vectors/generate.sh
LZO_ORACLE=/path/to/lzo_oracle dart run tool/vectors/generate.dart
```

The committed fixtures are reproducible byte-for-byte with liblzo2 2.10; the
CI `differential` job regenerates them and fails on any `git diff`. The eight
imported fixtures keep their original `.raw` bytes; `readme` and `libsrc` were
created with `lzo1x_999`, the others with `lzo1x_1`.

`test/data/**` is binary in `.gitattributes` and must stay that way: an EOL
conversion silently corrupts every fixture. `test/vectors_test.dart` asserts
the attribute is present and verifies every size and digest.

## Differential (`tool/differential.dart`)

For every manifest entry:

* (a) liblzo2 compress -> Dart decompress, compared with the raw bytes; the
      oracle output must also equal the committed `.lzo` block;
* (b) Dart compress -> liblzo2 decompress, compared with the raw bytes;
* (c) Dart compress -> Dart decompress, compared with the raw bytes.

```sh
dart run tool/differential.dart --oracle tool/oracle/lzo_oracle
dart run tool/differential.dart --case text_1m --oracle /path/to/lzo_oracle
```

Failures print the byte offset of the first difference and a hex context.
`lzo1x_999` fixtures are compressed on the Dart side with level 15 (the package
has no 999 encoder); decompression is level-independent, and check (a) still
verifies the 999 stream.
