# Changelog

## 0.1.0

- Initial release.
- LZO1X decompressor: safe, fully validating, no allocation, liblzo2-compatible
  error codes.
- LZO1X compressor: `lzo1x_1`, `lzo1x_1_11`, `lzo1x_1_12`, `lzo1x_1_15`.
- Zero-copy `Bytes` API (`package:blit`) and raw `Uint8List` entry points.
- Overlapping source/destination support for compression.
