# Changelog

## 0.1.1

- Complete liblzo2 2.10 algorithm matrix in both directions: LZO1, LZO1A,
  LZO1B, LZO1C, LZO1F, LZO1X, LZO1Y, LZO1Z and LZO2A, including all compression
  levels and LZO1X-999 quality 1..9.
- LZO1X-999 encoder with a reusable 448 KiB workspace, plus preset-dictionary
  compression/decompression for LZO1X, LZO1Y and LZO1Z.
- `lzo1x_optimize` and true in-place decompression (`Lzo1x.optimizeInto`,
  `Lzo1x.decompressInPlace`).
- LZO-RLE bitstream version 1 (Linux kernel / zram), encoder and decoder.
- `lzop` container reader/writer with Adler-32/CRC-32 checksums and stored
  blocks (`package:lzo_neo/lzop.dart`).
- Unified `LzoAlgorithm` / `lzoCodec` factory.
- Full-matrix vectors and differential verification against liblzo2 2.10.

## 0.1.0

- Initial release.
- LZO1X decompressor: safe, fully validating, no allocation, liblzo2-compatible
  error codes.
- LZO1X compressor: `lzo1x_1`, `lzo1x_1_11`, `lzo1x_1_12`, `lzo1x_1_15`.
- Zero-copy `Bytes` API (`package:blit`) and raw `Uint8List` entry points.
- Overlapping source/destination support for compression.
