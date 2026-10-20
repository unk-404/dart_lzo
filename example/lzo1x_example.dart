import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo.dart';

void main() {
  final codec = Lzo1x();
  final original = Bytes.fromString(
    'hello, lzo world! hello, lzo world! hello, lzo world!',
  );

  final packed = codec.compress(original);
  final restored = codec.decompress(packed, original.length);

  print('original:   ${original.length} bytes');
  print('compressed: ${packed.length} bytes');
  print('restored:   ${restored.length} bytes');
  print(restored.asUint8List().every((byte) => true));

  // Raw buffers, zero allocation:
  final input = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff));
  final output = Uint8List(Lzo1x.compressBound(input.length));
  final compressedLength = codec.compressInto(input, output);

  final decoded = Uint8List(input.length);
  final decodedLength = codec.decompressInto(
    Uint8List.sublistView(output, 0, compressedLength),
    decoded,
  );
  print(
    'round-trip: $decodedLength bytes, ok=${decodedLength == input.length}',
  );
}
