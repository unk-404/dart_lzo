import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzop.dart';
import 'package:lzo_neo/lzo_neo.dart';
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

Uint8List _pattern(int length) {
  const pattern = <int>[0x6c, 0x7a, 0x6f, 0x31, 0x78, 0x2d, 0x6e, 0x65];
  return Uint8List.fromList(
    List<int>.generate(length, (i) => pattern[i % pattern.length]),
  );
}

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

void main() {
  const lzop = Lzop();
  const sizes = <int>[0, 1, 2, 17, 238, 239, 1024, 65536, 262145];
  final corpora = <String, Uint8List Function(int)>{
    'text': _text,
    'zeros': (length) => Uint8List(length),
    'random': (length) => _random(length, length),
    'pattern': _pattern,
  };

  group('round-trip', () {
    for (final entry in corpora.entries) {
      test(entry.key, () {
        for (final size in sizes) {
          final source = entry.value(size);
          final file = lzop.compress(source);
          final restored = lzop.decompress(file);
          expect(restored, orderedEquals(source), reason: 'size $size');
          final view = Bytes.fromUint8List(source);
          expect(
            lzop.decompressBytes(lzop.compressBytes(view)).asUint8List(),
            orderedEquals(source),
          );
        }
      });
    }
  });

  group('options', () {
    test('crc32 checksums', () {
      final source = _text(10000);
      final file = lzop.compress(
        source,
        options: const LzopOptions(crc32: true),
      );
      expect(lzop.decompress(file), orderedEquals(source));
    });

    test('compressed-payload checksums', () {
      final source = _text(100000);
      final file = lzop.compress(
        source,
        options: const LzopOptions(
          crc32: true,
          compressedChecksums: true,
          blockSize: 4096,
        ),
      );
      expect(lzop.decompress(file), orderedEquals(source));
    });

    test('multiple small blocks', () {
      final source = _random(20000, 3);
      final file = lzop.compress(
        source,
        options: const LzopOptions(blockSize: 1024),
      );
      expect(lzop.decompress(file), orderedEquals(source));
    });

    test('Bytes API round-trips', () {
      final source = _random(100000, 5);
      final file = lzop.compressBytes(Bytes.fromUint8List(source));
      final restored = lzop.decompressBytes(file);
      expect(restored.asUint8List(), orderedEquals(source));
    });

    test('LZO1X-999 payloads round-trip', () {
      final source = _text(200000);
      final file = lzop.compress(
        source,
        options: const LzopOptions(level: Lzo1xLevel.max),
      );
      expect(lzop.decompress(file), orderedEquals(source));
    });

    test('file name and mtime', () {
      final source = _text(4096);
      final file = lzop.compress(
        source,
        options: const LzopOptions(
          fileName: 'hello.txt',
          mtime: 1700000000,
          mode: 0x81a4,
        ),
      );
      expect(lzop.decompress(file), orderedEquals(source));
    });
  });

  group('real lzop 1.04 files', () {
    test('decodes lzo1x_999 output', () {
      final file = File('test/data/lzop/text_999.lzo').readAsBytesSync();
      final raw = File('test/data/lzop/text_999.raw').readAsBytesSync();
      expect(lzop.decompress(file), orderedEquals(raw));
    });

    test('decodes a stored (uncompressed) block', () {
      final file = File('test/data/lzop/random_stored.lzo').readAsBytesSync();
      final raw = File('test/data/lzop/random_stored.raw').readAsBytesSync();
      expect(lzop.decompress(file), orderedEquals(raw));
    });
  });

  group('stored blocks', () {
    test('incompressible data is stored and restored', () {
      final source = _random(65536, 11);
      final file = lzop.compress(source);
      // A stored block has compressed size == uncompressed size.
      expect(file.length, greaterThan(source.length));
      expect(lzop.decompress(file), orderedEquals(source));
    });
  });

  group('validation', () {
    test('bad magic', () {
      final file = lzop.compress(_text(100));
      file[0] = 0;
      expect(() => lzop.decompress(file), _throwsCode(LzoErrorCode.error));
    });

    test('header checksum mismatch', () {
      final file = lzop.compress(_text(100));
      // Flip a byte in the version/header fields covered by the checksum.
      file[9] ^= 0x01;
      expect(() => lzop.decompress(file), _throwsCode(LzoErrorCode.error));
    });

    test('block checksum mismatch', () {
      final file = lzop.compress(_text(1000));
      // Flip the last payload byte (the header is not affected).
      file[file.length - 5] ^= 0x01;
      expect(() => lzop.decompress(file), throwsA(isA<LzoException>()));
    });

    test('truncated file', () {
      final file = lzop.compress(_text(1000));
      expect(
        () => lzop.decompress(Uint8List.sublistView(file, 0, file.length - 2)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });

    test('trailing bytes', () {
      final file = lzop.compress(_text(100));
      final padded = Uint8List(file.length + 1)..setRange(0, file.length, file);
      expect(
        () => lzop.decompress(padded),
        _throwsCode(LzoErrorCode.inputNotConsumed),
      );
    });

    test('invalid block size option', () {
      expect(
        () =>
            lzop.compress(_text(10), options: const LzopOptions(blockSize: 0)),
        _throwsCode(LzoErrorCode.invalidArgument),
      );
    });
  });
}
