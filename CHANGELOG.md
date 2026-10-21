# Changelog

## 0.2.1

- Upgrade to lit 0.2.0.
- lzop internals now use blit: BytesReader for header/block parsing,
  BytesMut for output assembly, and zero-copy Bytes views for payloads.
- Lzop.compressBytes/decompressBytes no longer copy the result.
- Core imports use package:blit/blit_buffer.dart, keeping the web build free
  of the file-I/O layer.

## 0.2.0

Performance-focused redesign, with no stream-format changes.

- LZO1X-1 match finder rewritten around 64-bit unaligned loads:
  - 8-byte match extension with mask-based first-difference detection
  - `ByteData.getUint64` on the VM, 32-bit fallback on the web
  - 65 536-entry hash table (256 KiB) to remove most collisions
  - inline VM fast path for the match loop
- Decoder copy paths:
  - short non-overlapping matches copied with 8-byte loads
  - trailing state literals copied with explicit stores
  - inlined literal/match helpers
- New `Lzo1xSpeed` (`fastest`, `balanced`, `bestRatio`) to tune the
  speed/ratio trade-off; all modes emit standard LZO1X.
- Measured on a 17.5 MiB mixed corpus against liblzo2 2.10 `-O2`:
  - decompression: ~875-915 MB/s, **80-83% of native**
  - LZO1X-1 compression: ~570-585 MB/s mixed (65-67%), ~6.0-6.8 GB/s on 8 MiB text (~100%)
- `Lzo1xLevel.fast1` now uses a 256 KiB work table (was 64 KiB). Existing
  streams are unaffected.
- Tests: 888 pass; full-matrix differential remains 1936/1936.

## 0.1.2

- Production hardening release.
- CI: all-family fixtures no longer depend on README.md, so documentation edits
  cannot break the reproducibility gate.
- Performance: LZO1X-1 uses unaligned 32-bit match scanning and 8-byte match
  extension (~20-30% faster than 0.1.1); family hash tables clear in bulk.
- API: `LzoCodec.compressedSizeBound` for manual output buffers.
- Added an all-family fuzz suite and codec-API tests.
- Benchmark chart switches to a linear scale; the unused Windows benchmark job
  and its CMake build were removed.

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
