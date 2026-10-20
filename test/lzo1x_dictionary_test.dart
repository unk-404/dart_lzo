import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

Uint8List _text(int length, [int offset = 0]) {
  const sample = 'the quick brown fox jumps over the lazy dog. ';
  return Uint8List.fromList(
    List<int>.generate(
      length,
      (i) => sample.codeUnitAt((i + offset) % sample.length),
    ),
  );
}

void main() {
  group('preset dictionary', () {
    test('LZO1X-999 round-trips through the public API', () {
      final dictionary = _text(8192);
      final source = Uint8List.fromList(<int>[
        ...Uint8List.sublistView(dictionary, 4096),
        ..._text(2048, 7),
      ]);
      final codec = Lzo1x(level: Lzo1xLevel.max, dictionary: dictionary);
      final compressed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source));
    });

    test('an oversized dictionary uses its final 49 151 bytes', () {
      final dictionary = _text(60000);
      final source = Uint8List.fromList(<int>[
        ...Uint8List.sublistView(dictionary, dictionary.length - 8192),
        ..._text(1024, 3),
      ]);
      final codec = Lzo1x(level: Lzo1xLevel.max, dictionary: dictionary);
      final compressed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source));
    });

    test('LZO1Y-999 supports a dictionary', () {
      final dictionary = _text(4096);
      final source = Uint8List.fromList(<int>[
        ...Uint8List.sublistView(dictionary, 2048),
        ..._text(1024, 5),
      ]);
      final codec = lzoCodec(
        LzoAlgorithm.lzo1y,
        level: 999,
        dictionary: dictionary,
      );
      final compressed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source));
    });

    test('LZO1Z-999 supports a dictionary', () {
      final dictionary = _text(4096);
      final source = Uint8List.fromList(<int>[
        ...Uint8List.sublistView(dictionary, 2048),
        ..._text(1024, 11),
      ]);
      final codec = lzoCodec(
        LzoAlgorithm.lzo1z,
        level: 999,
        dictionary: dictionary,
      );
      final compressed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source));
    });

    test('fast levels reject a preset dictionary', () {
      final codec = Lzo1x(dictionary: _text(1024));
      expect(
        () => codec.compressInto(_text(1024), Uint8List(4096)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.invalidArgument,
          ),
        ),
      );
    });
  });
}
