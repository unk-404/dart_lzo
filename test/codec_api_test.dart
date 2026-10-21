import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

Uint8List _data(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

void main() {
  test('every default codec respects its bound and round-trips', () {
    final source = _data(4096, 17);
    for (final algorithm in LzoAlgorithm.values) {
      final codec = lzoCodec(algorithm);
      final bound = codec.compressedSizeBound(source.length);
      expect(
        bound,
        greaterThanOrEqualTo(source.length),
        reason: algorithm.name,
      );

      final compressed = Uint8List(bound);
      final written = codec.compressInto(source, compressed);
      expect(written, lessThanOrEqualTo(bound), reason: algorithm.name);

      final decoded = Uint8List(source.length);
      final restored = codec.decompressInto(
        Uint8List.sublistView(compressed, 0, written),
        decoded,
      );
      expect(restored, source.length, reason: algorithm.name);
      expect(decoded, orderedEquals(source), reason: algorithm.name);
    }
  });

  test('Bytes API uses the same bound', () {
    final source = Bytes.fromUint8List(_data(2048, 3));
    for (final algorithm in LzoAlgorithm.values) {
      final codec = lzoCodec(algorithm);
      final compressed = codec.compress(source);
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source.asUint8List()));
    }
  });

  test('Lzo1x static bound matches the interface', () {
    final codec = Lzo1x();
    for (final size in [0, 1, 1024, 65536]) {
      expect(codec.compressedSizeBound(size), Lzo1x.compressBound(size));
    }
  });

  test('every speed mode round-trips', () {
    final source = Uint8List.fromList(
      List<int>.generate(
        8192,
        (i) => 'the quick brown fox '.codeUnitAt(i % 20),
      ),
    );
    for (final speed in Lzo1xSpeed.values) {
      final codec = Lzo1x(speed: speed);
      final compressed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(compressed, source.length);
      expect(restored.asUint8List(), orderedEquals(source), reason: speed.name);
    }
  });

  test('unknown levels are rejected', () {
    final matcher = throwsA(
      isA<LzoException>().having(
        (error) => error.code,
        'code',
        LzoErrorCode.invalidArgument,
      ),
    );
    for (final algorithm in LzoAlgorithm.values) {
      final acceptsSeven =
          algorithm == LzoAlgorithm.lzo1b || algorithm == LzoAlgorithm.lzo1c;
      if (acceptsSeven) {
        expect(() => lzoCodec(algorithm, level: 7), returnsNormally);
      } else {
        expect(() => lzoCodec(algorithm, level: 7), matcher);
      }
      expect(() => lzoCodec(algorithm, level: 12345), matcher);
    }
  });
}
