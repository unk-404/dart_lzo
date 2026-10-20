import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo.dart';
import 'package:lzo_neo/src/lzo1x/encoder.dart';
import 'package:test/test.dart';

Uint8List _random(int length, int seed) {
  final random = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List _periodic(int length, int period, [int seed = 1]) {
  final base = _random(period, seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = base[i % period];
  }
  return out;
}

Uint8List _textLike(int length) {
  const sample = 'the quick brown fox jumps over the lazy dog. ';
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = sample.codeUnitAt(i % sample.length);
  }
  return out;
}

Uint8List _runs(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i ~/ 37) & 0xff;
  }
  return out;
}

/// Encodes [source] with [level], checks the documented bounds and verifies
/// that the package decoder restores it byte for byte.
void _expectRoundTrip(Lzo1xLevel level, Uint8List source, String reason) {
  final codec = Lzo1x(level: level);
  final bound = Lzo1x.compressBound(source.length);
  final compressed = Uint8List(bound);
  final written = codec.compressInto(source, compressed);

  expect(written, inInclusiveRange(3, bound), reason: reason);
  // Every block ends with the canonical end-of-stream marker.
  expect(
    compressed.sublist(written - 3, written),
    orderedEquals(const [0x11, 0x00, 0x00]),
    reason: reason,
  );

  final decoded = Uint8List(source.length);
  final restored = codec.decompressInto(
    Uint8List.sublistView(compressed, 0, written),
    decoded,
  );
  expect(restored, source.length, reason: reason);
  expect(decoded, orderedEquals(source), reason: reason);
}

void main() {
  final cases = <String, Uint8List>{
    'empty': Uint8List(0),
    for (final size in [
      1,
      2,
      3,
      4,
      5,
      17,
      18,
      19,
      238,
      239,
      240,
      255,
      256,
      274,
    ]) ...{
      'zeros_$size': Uint8List(size),
      'random_$size': _random(size, size),
      'period3_$size': _periodic(size, 3, size),
    },
    'text_4096': _textLike(4096),
    'text_65536': _textLike(65536),
    'runs_65536': _runs(65536),
    'zeros_262144': Uint8List(262144),
    // Exact-distance matches at the M2/M3/M4 boundaries.
    for (final distance in [2048, 2049, 16384, 16385, 40000])
      'distance_$distance': _periodic(distance * 3, distance, distance),
  };

  group('round-trip', () {
    for (final level in Lzo1xLevel.values) {
      test('${level.name} restores every corpus shape', () {
        for (final entry in cases.entries) {
          _expectRoundTrip(level, entry.value, '${level.name} ${entry.key}');
        }
      });
    }
  });

  group('tokens', () {
    test('empty input encodes as the bare end-of-stream marker', () {
      final codec = Lzo1x();
      final output = Uint8List(Lzo1x.compressBound(0));
      final written = codec.compressInto(Uint8List(0), output);
      expect(written, 3);
      expect(output.sublist(0, 3), orderedEquals(const [0x11, 0x00, 0x00]));
    });

    test('short incompressible block matches the liblzo2 vector', () {
      // liblzo2 encodes an incompressible block of at most 238 bytes as the
      // leading-literal-run opcode followed by the raw bytes.
      final source = File('test/data/hello.raw').readAsBytesSync();
      final reference = File('test/data/hello.lzo').readAsBytesSync();
      final codec = Lzo1x();
      final output = Uint8List(Lzo1x.compressBound(source.length));
      final written = codec.compressInto(source, output);

      expect(written, reference.length);
      expect(
        Uint8List.sublistView(output, 0, written),
        orderedEquals(reference),
      );
    });

    test('compressible input is much smaller than its literal encoding', () {
      final codec = Lzo1x();
      final source = Uint8List(262144);
      final output = Uint8List(Lzo1x.compressBound(source.length));
      final written = codec.compressInto(source, output);
      // One literal prefix plus a handful of length-extension bytes: the whole
      // block must be far below 1% of the input.
      expect(written, lessThan(2048));
    });

    test('long incompressible input stays within the expansion bound', () {
      final codec = Lzo1x();
      for (final size in [1024, 4096, 65536, 1048576]) {
        final source = _random(size, size);
        final output = Uint8List(Lzo1x.compressBound(size));
        final written = codec.compressInto(source, output);
        expect(written, lessThanOrEqualTo(size + (size >> 6)));
        final decoded = Uint8List(size);
        expect(
          codec.decompressInto(
            Uint8List.sublistView(output, 0, written),
            decoded,
          ),
          size,
        );
        expect(decoded, orderedEquals(source));
      }
    });
  });

  group('buffer handling', () {
    test('output buffer one byte too small reports an overrun', () {
      final codec = Lzo1x();
      final source = _textLike(8192);
      final output = Uint8List(Lzo1x.compressBound(source.length));
      final written = codec.compressInto(source, output);
      expect(
        () => codec.compressInto(source, Uint8List(written - 1)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.outputOverrun,
          ),
        ),
      );
    });

    test('a dictionary smaller than the level needs is rejected', () {
      final source = _textLike(4096);
      final destination = Uint8List(Lzo1x.compressBound(source.length));
      const level = Lzo1xLevel.fast15;
      expect(
        () => lzo1xCompress(
          source,
          destination,
          level,
          Uint32List(level.dictionarySize - 1),
        ),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('a buffer too small for the end-of-stream marker overruns', () {
      final codec = Lzo1x();
      for (final length in [0, 1, 2]) {
        expect(
          () => codec.compressInto(Uint8List(0), Uint8List(length)),
          throwsA(
            isA<LzoException>().having(
              (error) => error.code,
              'code',
              LzoErrorCode.outputOverrun,
            ),
          ),
          reason: 'destination length $length',
        );
      }
    });

    test('compresses into an offset view of a larger buffer', () {
      final codec = Lzo1x();
      final sourceBuffer = Uint8List(64 + 4096);
      sourceBuffer.setRange(64, 64 + 4096, _textLike(4096));
      final destination = Uint8List(128 + Lzo1x.compressBound(4096));
      final written = codec.compressInto(
        Uint8List.sublistView(sourceBuffer, 64, 64 + 4096),
        Uint8List.sublistView(destination, 128),
      );

      expect(destination.sublist(0, 128), everyElement(0));
      final decoded = Uint8List(4096);
      expect(
        codec.decompressInto(
          Uint8List.sublistView(destination, 128, 128 + written),
          decoded,
        ),
        4096,
      );
      expect(
        decoded,
        orderedEquals(Uint8List.sublistView(sourceBuffer, 64, 64 + 4096)),
      );
    });

    test('reusing a codec instance is deterministic', () {
      final codec = Lzo1x();
      final source = _periodic(65536, 251, 7);
      final first = Uint8List(Lzo1x.compressBound(source.length));
      final second = Uint8List(Lzo1x.compressBound(source.length));
      final firstWritten = codec.compressInto(source, first);
      final secondWritten = codec.compressInto(source, second);

      expect(secondWritten, firstWritten);
      expect(
        Uint8List.sublistView(second, 0, secondWritten),
        orderedEquals(Uint8List.sublistView(first, 0, firstWritten)),
      );
    });

    test('every level round-trips through the zero-copy Bytes API', () {
      for (final level in Lzo1xLevel.values) {
        final codec = Lzo1x(level: level);
        final source = _textLike(10000);
        final compressed = codec.compress(Bytes.fromUint8List(source));
        final decoded = codec.decompress(compressed, source.length);
        expect(
          decoded.asUint8List(),
          orderedEquals(source),
          reason: level.name,
        );
      }
    });
  });
}
