# lzo_neo

Pure Dart implementation of the [LZO](https://www.oberhumer.com/opensource/lzo/)
compression algorithms. No native code, no FFI: the same code runs on the Dart
VM, in AOT builds, and on the web.

LZO is a lossless block compressor optimised for decompression speed. LZO1X is
the variant used by `lzop`, the Linux kernel, btrfs and SquashFS.

## Status

| Feature | Status |
|---|---|
| LZO1X decompress (safe, fully validating) | ✅ |
| LZO1X compress: `lzo1x_1`, `1_11`, `1_12`, `1_15` | ✅ |
| LZO1X-999, LZO1Y, LZO1Z, LZO1B, LZO1C, LZO1F, LZO1, LZO1A, LZO2A encoders | planned for 0.1.1 |
| `lzo1x_optimize` / in-place decompression | planned for 0.1.1 |
| LZO-RLE, `lzop` container | planned for 0.1.1 |

Compressed LZO blocks carry no header and no original size, so decompression
needs the caller to supply the output capacity, exactly like liblzo2.

## Install

```yaml
dependencies:
  lzo_neo: ^0.1.0
```

## Usage

`package:blit` `Bytes` are zero-copy views, so slicing does not copy:

```dart
import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo.dart';

final codec = Lzo1x();
final original = Bytes.fromString('hello, lzo world!');
final packed = codec.compress(original);
final restored = codec.decompress(packed, original.length);
```

Zero-allocation operation on raw `Uint8List` buffers:

```dart
final output = Uint8List(codec.compressBound(input.length));
final compressedLength = codec.compressInto(input, output);

final decoded = Uint8List(originalLength);
final decodedLength = codec.decompressInto(output, decoded);
```

Reuse a codec instance to reuse its compression work memory (64 KiB for
`Lzo1xLevel.fast1`, 8/16/128 KiB for `fast11`/`fast12`/`fast15`).

## Safety

The decoder validates every instruction and every write. Malformed, truncated
or oversized input throws `LzoException` with a liblzo2-compatible
`LzoErrorCode`; it never reads out of bounds, writes out of bounds, or loops
forever. No memory is allocated while decompressing.

## Correctness

Streams are tested against vectors produced by the reference C implementation
(liblzo2 2.10) and, in CI, differentially in both directions:

- liblzo2 compress → Dart decompress
- Dart compress → liblzo2 decompress
- Dart compress → Dart decompress

The LZO1X grammar follows liblzo2's `src/lzo1x_d.ch` and the format description
in the Linux kernel (`Documentation/staging/lzo.rst`).

## License

MIT. LZO itself is Copyright (C) Markus F. X. J. Oberhumer and is distributed
under the GNU GPL; this package is an independent implementation of the
published format.
