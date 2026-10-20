/// lzop file container support.
///
/// ```dart
/// import 'package:lzo_neo/lzop.dart';
///
/// final file = const Lzop().compress(bytes);
/// final restored = const Lzop().decompress(file);
/// ```
library;

export 'src/container/lzop.dart' show Lzop, LzopOptions;
export 'src/core/checksum.dart' show lzoAdler32, lzoCrc32;
