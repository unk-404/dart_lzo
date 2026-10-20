import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:lzo_neo/src/lzo1x/rle.dart';
import 'package:test/test.dart';

Uint8List _random(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List _text(int length) {
  const sample = 'the quick brown fox jumps over the lazy dog. ';
  return Uint8List.fromList(
    List<int>.generate(length, (i) => sample.codeUnitAt(i % sample.length)),
  );
}

Uint8List _mixedZeros(int length) {
  final out = Uint8List(length);
  for (var i = 1000; i < length - 1000; i += 4000) {
    final end = min(i + 1500, length);
    out.fillRange(i, end, 0);
  }
  for (var i = 0; i < length; i++) {
    if (i % 997 == 0) out[i] = 7;
  }
  return out;
}

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

void main() {
  final rle = Lzo1xRle();
  final plain = Lzo1x();

  group('version 1 round-trip', () {
    const sizes = <int>[0, 1, 2, 3, 4, 5, 17, 238, 239, 1024, 65536];
    final corpora = <String, Uint8List Function(int)>{
      'text': _text,
      'zeros': (length) => Uint8List(length),
      'random': (length) => _random(length, length),
      'mixed_zeros': _mixedZeros,
      'long_zeros': (length) => Uint8List(length * 2),
    };

    for (final entry in corpora.entries) {
      test(entry.key, () {
        for (final size in sizes) {
          final source = entry.value(size);
          final bound = Lzo1xRle().compressBound(source.length);
          final compressed = Uint8List(bound);
          final written = rle.compressInto(source, compressed);
          final decoded = Uint8List(source.length);
          final restored = rle.decompressInto(
            Uint8List.sublistView(compressed, 0, written),
            decoded,
          );
          expect(restored, source.length, reason: '${entry.key} $size');
          expect(decoded, orderedEquals(source), reason: '${entry.key} $size');
        }
      });
    }
  });

  group('stream shape', () {
    test('empty input starts with the version marker', () {
      final compressed = Uint8List(16);
      final written = rle.compressInto(Uint8List(0), compressed);
      expect(written, 5);
      expect(compressed.sublist(0, 5), equals([0x11, 0x01, 0x11, 0x00, 0x00]));
    });

    test('long zero runs use the RLE instruction', () {
      final source = Uint8List(1 << 20);
      final compressed = Uint8List(rle.compressBound(source.length));
      final written = rle.compressInto(source, compressed);
      // One RLE instruction per 2051 zero bytes plus the 4-byte literal prefix.
      expect(written, lessThan(8192));
      expect(compressed[0], 0x11);
      expect(compressed[1], 0x01);
    });

    test('version 1 decodes version 0 streams', () {
      final source = _text(50000);
      final v0 = Uint8List(Lzo1x.compressBound(source.length));
      final v0Length = plain.compressInto(source, v0);
      final decoded = Uint8List(source.length);
      expect(
        rle.decompressInto(Uint8List.sublistView(v0, 0, v0Length), decoded),
        source.length,
      );
      expect(decoded, orderedEquals(source));
    });

    test('version 0 decoder rejects version 1 streams', () {
      final compressed = rle.compress(_bytes(Uint8List(4096)));
      expect(
        () => plain.decompressInto(compressed.asUint8List(), Uint8List(4096)),
        throwsA(isA<LzoException>()),
      );
    });
  });

  group('validation', () {
    test('truncated stream', () {
      final compressed = rle.compress(_bytes(_text(4096)));
      expect(
        () => rle.decompressInto(
          compressed.asUint8List().sublist(0, compressed.length - 2),
          Uint8List(4096),
        ),
        throwsA(isA<LzoException>()),
      );
    });

    test('output too small', () {
      final compressed = rle.compress(_bytes(_text(4096)));
      expect(
        () => rle.decompressInto(compressed.asUint8List(), Uint8List(10)),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('unsupported bitstream version', () {
      final block = Uint8List.fromList([0x11, 0x09, 0x11, 0x00, 0x00]);
      expect(
        () => rle.decompressInto(block, Uint8List(16)),
        _throwsCode(LzoErrorCode.error),
      );
    });

    test('random buffers only throw LzoException', () {
      final random = Random(7);
      for (var i = 0; i < 2000; i++) {
        final input = Uint8List.fromList(
          List<int>.generate(random.nextInt(64), (_) => random.nextInt(256)),
        );
        final output = Uint8List(random.nextInt(128));
        try {
          rle.decompressInto(input, output);
        } on LzoException {
          // Expected.
        }
      }
    });
  });
}

Bytes _bytes(Uint8List data) => Bytes.fromUint8List(data);
