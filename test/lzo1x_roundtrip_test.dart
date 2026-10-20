import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

Uint8List _random(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

void main() {
  group('literal block round-trip', () {
    const sizes = <int>[0, 1, 2, 3, 4, 17, 18, 19, 238, 239, 240, 255, 256];

    for (final level in Lzo1xLevel.values) {
      test('${level.name} over boundary sizes', () {
        final codec = Lzo1x(level: level);
        final random = Random(level.number);
        for (final size in sizes) {
          final source = Uint8List.fromList(
            List<int>.generate(size, (_) => random.nextInt(256)),
          );
          final bound = Lzo1x.compressBound(size);
          final output = Uint8List(bound);

          final written = codec.compressInto(source, output);
          expect(written, lessThanOrEqualTo(bound));

          final decoded = Uint8List(size);
          final restored = codec.decompressInto(
            Uint8List.sublistView(output, 0, written),
            decoded,
          );
          expect(restored, size);
          expect(decoded, orderedEquals(source), reason: 'size $size');
        }
      });
    }
  });

  group('expansion bound', () {
    test('incompressible data stays within 1/64', () {
      final codec = Lzo1x();
      for (final size in [1024, 4096, 65536]) {
        final source = _random(size, size);
        final output = Uint8List(Lzo1x.compressBound(size));
        final written = codec.compressInto(source, output);

        expect(
          written,
          lessThanOrEqualTo(size + (size >> 6)),
          reason: 'size $size',
        );

        final decoded = Uint8List(size);
        expect(codec.decompressInto(output.sublist(0, written), decoded), size);
        expect(decoded, orderedEquals(source));
      }
    });
  });

  group('zero-copy Bytes API', () {
    test('round-trips through Bytes views', () {
      final codec = Lzo1x();
      final source = Bytes.fromUint8List(_random(10000, 7));
      final compressed = codec.compress(source);
      final decoded = codec.decompress(compressed, source.length);

      expect(decoded.length, source.length);
      expect(decoded.asUint8List(), orderedEquals(source.asUint8List()));
    });

    test('compressed output is a view over its own buffer', () {
      final codec = Lzo1x();
      final compressed = codec.compress(Bytes.fromString('abc'));
      expect(compressed.asUint8List(), isA<Uint8List>());
      expect(compressed.length, 7);
    });
  });

  group('buffer sizing', () {
    test('destination smaller than the encoded block is rejected', () {
      final codec = Lzo1x();
      final source = _random(1024, 1);
      expect(
        () => codec.compressInto(source, Uint8List(16)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.outputOverrun,
          ),
        ),
      );
    });

    test('overlapping source and destination is handled', () {
      final codec = Lzo1x();
      final buffer = Uint8List(4096);
      final source = _random(512, 3);
      buffer.setRange(1024, 1024 + source.length, source);

      final written = codec.compressInto(
        Uint8List.sublistView(buffer, 1024, 1024 + source.length),
        Uint8List.sublistView(buffer, 0, 4096),
      );

      final decoded = Uint8List(source.length);
      expect(
        codec.decompressInto(
          Uint8List.sublistView(buffer, 0, written),
          decoded,
        ),
        source.length,
      );
      expect(decoded, orderedEquals(source));
    });
  });
}
