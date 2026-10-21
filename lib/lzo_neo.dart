/// Pure Dart implementation of the LZO compression algorithms.
///
/// LZO is a lossless block compressor optimised for decompression speed. This
/// package covers the complete liblzo2 2.10 algorithm matrix: LZO1, LZO1A,
/// LZO1B, LZO1C, LZO1F, LZO1X, LZO1Y, LZO1Z and LZO2A, in both directions,
/// plus the kernel LZO-RLE bitstream, `lzo1x_optimize`/in-place decoding and
/// the lzop container (\package:lzo_neo/lzop.dart\).
///
/// ```dart
/// import 'package:blit/blit.dart';
/// import 'package:lzo_neo/lzo_neo.dart';
///
/// final codec = Lzo1x();
/// final packed = codec.compress(Bytes.fromString('hello, lzo world!'));
/// final raw = codec.decompress(packed, 17);
/// ```
library;

export 'src/codec.dart' show LzoAlgorithm, lzoCodec;
export 'src/core/codec.dart' show LzoCodec, LzoCodecBase;
export 'src/core/errors.dart' show LzoErrorCode, LzoException;
export 'src/core/limits.dart'
    show
        lzo1x11MemCompress,
        lzo1x12MemCompress,
        lzo1x15MemCompress,
        lzo1x1MemCompress,
        lzo1xCompressBound,
        lzoCompressBound,
        lzo1xMaxDistance;
export 'src/lzo1.dart' show Lzo1, Lzo1Level;
export 'src/lzo1a.dart' show Lzo1a, Lzo1aLevel;
export 'src/lzo1b.dart' show Lzo1b, Lzo1bLevel;
export 'src/lzo1c.dart' show Lzo1c, Lzo1cLevel;
export 'src/lzo1f.dart' show Lzo1f, Lzo1fLevel;
export 'src/lzo1x.dart' show Lzo1x, Lzo1xLevel, Lzo1xSpeed;
export 'src/lzo1x/encoder_9x.dart' show Lzo999Workspace;
export 'src/lzo1x/rle.dart' show Lzo1xRle;
export 'src/lzo1y.dart' show Lzo1y, Lzo1yLevel;
export 'src/lzo1z.dart' show Lzo1z, Lzo1zLevel;
export 'src/lzo2a.dart' show Lzo2a, Lzo2aLevel;
