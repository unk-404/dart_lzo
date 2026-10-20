/// Pure Dart implementation of the LZO compression algorithms.
///
/// LZO is a lossless block compressor optimised for decompression speed. This
/// package implements the LZO1X family (the format used by lzop, the Linux
/// kernel, btrfs and SquashFS).
///
/// ```dart
/// import 'package:blit/blit.dart';
/// import 'package:lzo_neo/lzo.dart';
///
/// final codec = Lzo1x();
/// final packed = codec.compress(Bytes.fromString('hello, lzo world!'));
/// final raw = codec.decompress(packed, 17);
/// ```
library;

export 'src/core/errors.dart' show LzoErrorCode, LzoException;
export 'src/core/limits.dart'
    show
        lzo1x11MemCompress,
        lzo1x12MemCompress,
        lzo1x15MemCompress,
        lzo1x1MemCompress,
        lzo1xCompressBound,
        lzo1xMaxDistance;
export 'src/lzo1x.dart' show Lzo1x, Lzo1xLevel;
