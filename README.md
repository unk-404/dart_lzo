# lzo_neo

[![pub package](https://img.shields.io/pub/v/lzo_neo.svg)](https://pub.dev/packages/lzo_neo)
[![CI](https://github.com/unk-404/dart_lzo/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/unk-404/dart_lzo/actions/workflows/ci.yml)

![LZO1X benchmarks: Dart vs liblzo2 2.10](https://raw.githubusercontent.com/unk-404/dart_lzo/master/assets/benchmarks.svg)

Pure Dart implementation of the [LZO](https://www.oberhumer.com/opensource/lzo/)
compression algorithms. No native code, no FFI: the same code runs on the Dart
VM, in AOT builds, and on the web.

LZO is a lossless block compressor optimised for decompression speed. LZO1X is
the variant used by `lzop`, the Linux kernel, btrfs and SquashFS.

## Status

The complete liblzo2 2.10 algorithm matrix is implemented in both directions:

| Algorithm | Levels |
|---|---|
| LZO1 | 1, 99 |
| LZO1A | 1, 99 |
| LZO1B | 1..9, 99, 999 |
| LZO1C | 1..9, 99, 999 |
| LZO1F | 1, 999 |
| LZO1X | 1, 11, 12, 15, 999 (quality 1..9) |
| LZO1Y | 1, 999 (quality 1..9) |
| LZO1Z | 999 (quality 1..9) |
| LZO2A | 999 |

Also supported:

- preset-dictionary compression and decompression for LZO1X/LZO1Y/LZO1Z
- `lzo1x_optimize` and true in-place decompression
- the Linux kernel LZO-RLE bitstream (version 1)
- the `lzop` file container (`package:lzo_neo/lzop.dart`)

Compressed LZO blocks carry no header and no original size, so decompression
needs the caller to supply the output capacity, exactly like liblzo2.

## Install

```yaml
dependencies:
  lzo_neo: ^0.2.1
```

## Usage

`package:blit` `Bytes` are zero-copy views, so slicing does not copy:

```dart
import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';

final codec = Lzo1x();
final original = Bytes.fromString('hello, lzo world!');
final packed = codec.compress(original);
final restored = codec.decompress(packed, original.length);
```

Zero-allocation operation on raw `Uint8List` buffers:

```dart
final output = Uint8List(Lzo1x.compressBound(input.length));
final compressedLength = codec.compressInto(input, output);

final decoded = Uint8List(originalLength);
final decodedLength = codec.decompressInto(output, decoded);
```

Reuse a codec instance to reuse its compression work memory (64 KiB for
`Lzo1xLevel.fast1`, 8/16/128 KiB for `fast11`/`fast12`/`fast15`; LZO1X-999 uses
a 448 KiB sliding-window workspace; ast1 uses a 256 KiB hash table).

Any algorithm, selected by name:

```dart
final lzo1b = lzoCodec(LzoAlgorithm.lzo1b, level: 9);
final lzo2a = lzoCodec(LzoAlgorithm.lzo2a); // level 999
```

LZO-RLE (kernel bitstream v1) and the lzop container are separate entry points:

```dart
import 'package:lzo_neo/lzop.dart';

final kernelBlock = Lzo1xRle().compress(source);
final lzopFile = const Lzop().compress(source.asUint8List());
final restored = const Lzop().decompress(lzopFile);
```

In-place decoding is available for LZO1X blocks:

```dart
// Canonical lzop layout: the compressed block sits at the end of the buffer.
final buffer = Uint8List(outputLength + outputLength ~/ 16 + 64 + 3);
buffer.setRange(buffer.length - compressed.length, buffer.length, compressed);
codec.decompressInPlace(
  buffer,
  compressedOffset: buffer.length - compressed.length,
  compressedLength: compressed.length,
  outputLength: outputLength,
);
```

## Safety

The decoders validate every instruction and every write. Malformed, truncated
or oversized input throws `LzoException` with a liblzo2-compatible
`LzoErrorCode`; they never read out of bounds, write out of bounds, or loop
forever. Decompression allocates no memory.

## Correctness

Every algorithm and level is tested against fixtures produced by the reference
C implementation (liblzo2 2.10). CI also runs a full-matrix differential in both
directions over all 36 compressor levels, plus preset-dictionary cases:

- liblzo2 compress → Dart decompress
- Dart compress → liblzo2 decompress
- Dart compress → Dart decompress

The LZO1X grammar follows liblzo2's `src/lzo1x_d.ch` and the format description
in the Linux kernel (`Documentation/staging/lzo.rst`). LZO-RLE is verified in
both directions against the Linux kernel compressor/decompressor.

## Performance

AOT x64, 17.5 MiB mixed corpus, compared with liblzo2 2.10 built with -O2 on
the same machine:

| Operation | lzo_neo 0.2 | liblzo2 C | Native ratio |
|---|---:|---:|---:|
| LZO1X decompress | ~875-915 MB/s | ~1100 MB/s | **80-83%** |
| LZO1X-1 compress (astest, mixed) | ~570-585 MB/s | ~880 MB/s | 65-67% |
| LZO1X-1 compress (astest, 8 MiB text) | ~6.0-6.8 GB/s | ~6.15 GB/s | **~100%** |

Decompression meets the production target. Compression is still limited by
Dart's per-byte overhead in the match finder; the v0.2 internals use 64-bit
unaligned loads, an 8-byte match extension and a 16-bit hash table.

### Speed/ratio tuning

Lzo1xSpeed selects how aggressively the fast levels skip literal runs:

`dart
final fastest = Lzo1x(speed: Lzo1xSpeed.fastest);   // default, ~26% ratio
final balanced = Lzo1x(speed: Lzo1xSpeed.balanced); // ~22% ratio
final best = Lzo1x(speed: Lzo1xSpeed.bestRatio);    // ~21.5% ratio
`

All three produce standard LZO1X streams. Lzo1xLevel.fast1 uses a 256 KiB
hash table; reuse one codec instance to reuse it.

The CI benchmark card compares LZO1X-1 with liblzo2 2.10 on a deterministic
corpus. Legacy-family performance is not benchmarked yet; correctness and the
API are.

## License

MIT. LZO itself is Copyright (C) Markus F. X. J. Oberhumer and is distributed
under the GNU GPL; this package is an independent implementation of the
published format.
