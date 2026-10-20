import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Corpus and hand-built streams
// ---------------------------------------------------------------------------

const List<String> _kinds = ['text', 'random', 'zeros', 'pattern'];
const List<int> _sizes = [0, 1, 2, 3, 4, 17, 18, 238, 239, 1024, 65536, 262144];

Uint8List _random(int length, int seed) {
  final random = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Uint8List _text(int length) {
  const sample =
      'the quick brown fox jumps over the lazy dog. LZO compresses blocks. ';
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = sample.codeUnitAt(i % sample.length);
  }
  return out;
}

Uint8List _pattern(int length) {
  final base = _random(37, 7);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = base[i % base.length];
  }
  return out;
}

Uint8List _corpus(String kind, int size) => switch (kind) {
  'text' => _text(size),
  'random' => _random(size, size),
  'zeros' => Uint8List(size),
  _ => _pattern(size),
};

int _bound(int length) => length + (length >> 4) + 64 + 3;

/// Source whose first match is eight bytes `abcdabcd` at distance 4.
Uint8List _shortMatchSource() => Uint8List.fromList(const [
  0x61, 0x62, 0x63, 0x64, //
  0x61, 0x62, 0x63, 0x64,
  0x61, 0x62, 0x63, 0x64,
  0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f,
]);

/// A tiny LZO1Z block exercising the "reuse previous distance" rule.
///
/// `abcd`, then an M2 match at distance 4 and length 4, then an M2 token whose
/// offset field is `0x1c`, which repeats the previous distance.
Uint8List _reuseStream() => Uint8List.fromList(const [
  17 + 4, 0x61, 0x62, 0x63, 0x64, // literals
  0x60, 0x0c, // M2: distance 4, length 4
  0x7c, // M2 reuse: distance 4, length 4
  0x11, 0x00, 0x00,
]);

/// A tiny LZO1Z block with an M3 match, whose distance bytes are stored in the
/// LZO1Z order (high six bits first).
Uint8List _m3Stream() {
  final literals = Uint8List(256);
  for (var i = 0; i < literals.length; i++) {
    literals[i] = i & 0xff;
  }
  return Uint8List.fromList([
    0x00, // extended literal run
    238, // 18 + 238 = 256 literals
    ...literals,
    0x20 | 3, // M3, length 5
    255 >> 6, // distance high bits
    (255 << 2) & 0xff, // distance low bits
    0x11, 0x00, 0x00,
  ]);
}

// ---------------------------------------------------------------------------
// Stream helpers
// ---------------------------------------------------------------------------

void _expectStreamShape(Uint8List compressed, int written, String reason) {
  expect(written, greaterThanOrEqualTo(3), reason: reason);
  expect(
    compressed.sublist(written - 3, written),
    orderedEquals(const [0x11, 0x00, 0x00]),
    reason: reason,
  );
  if (written > 3) {
    final first = compressed[0];
    expect(
      first == 0 || first > 17,
      isTrue,
      reason: '$reason: unexpected first byte 0x${first.toRadixString(16)}',
    );
  }
}

int _firstTokenOffset(Uint8List compressed) {
  final first = compressed[0];
  if (first == 0) {
    var offset = 1;
    var extra = 0;
    while (true) {
      final next = compressed[offset++];
      if (next != 0) {
        extra += next;
        break;
      }
      extra += 255;
    }
    return offset + (18 + extra);
  }
  return 1 + (first - 17);
}

/// Decodes the first token after the leading literal run as an LZO1Z M2 match.
(int length, int distance) _firstM2(Uint8List compressed) {
  final offset = _firstTokenOffset(compressed);
  final token = compressed[offset];
  expect(
    token,
    greaterThanOrEqualTo(64),
    reason: 'the first match of the test corpus must be M2',
  );
  final offsetBits = token & 0x1f;
  expect(
    offsetBits,
    lessThan(0x1c),
    reason: 'the first match must not reuse a previous distance',
  );
  final operand = compressed[offset + 1];
  final length = (token >> 5) + 1;
  final distance = 1 + (offsetBits << 6) + (operand >> 2);
  return (length, distance);
}

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('LZO1Z-999 round-trip matrix', () {
    for (var quality = 1; quality <= 9; quality++) {
      test('quality $quality over sizes and data kinds', () {
        final codec = Lzo1z(quality: quality);
        for (final kind in _kinds) {
          for (final size in _sizes) {
            final reason = '$kind $size q$quality';
            final source = _corpus(kind, size);
            final output = Uint8List(_bound(size));
            final written = codec.compressInto(source, output);
            final compressed = Uint8List.sublistView(output, 0, written);
            _expectStreamShape(compressed, written, reason);

            final decoded = Uint8List(size);
            expect(
              codec.decompressInto(compressed, decoded),
              size,
              reason: reason,
            );
            expect(decoded, orderedEquals(source), reason: reason);
          }
        }
      });
    }

    test('first match uses the LZO1Z M2 encoding', () {
      final source = _shortMatchSource();
      final output = Uint8List(_bound(source.length));
      final written = Lzo1z().compressInto(source, output);
      final compressed = Uint8List.sublistView(output, 0, written);
      expect(compressed[0], 17 + 4);
      final (length, distance) = _firstM2(compressed);
      expect(distance, 4);
      expect(length, 8);
    });

    test('ratio sanity', () {
      final zeros = Uint8List(65536);
      final output = Uint8List(_bound(zeros.length));
      final written = Lzo1z().compressInto(zeros, output);
      expect(written, lessThan(500));
    });
  });

  group('hand-built decoder streams', () {
    test('M2 reuse-last-distance token', () {
      final expected = Uint8List.fromList(
        List<int>.generate(12, (index) => 0x61 + (index % 4)),
      );
      final decoded = Uint8List(expected.length);
      expect(Lzo1z().decompressInto(_reuseStream(), decoded), expected.length);
      expect(decoded, orderedEquals(expected));
    });

    test('M3 distance byte order', () {
      final stream = _m3Stream();
      final expected = Uint8List(261);
      for (var i = 0; i < 256; i++) {
        expected[i] = i & 0xff;
      }
      for (var i = 0; i < 5; i++) {
        expected[256 + i] = expected[i];
      }
      final decoded = Uint8List(expected.length);
      expect(Lzo1z().decompressInto(stream, decoded), expected.length);
      expect(decoded, orderedEquals(expected));
    });

    test('empty stream marker', () {
      expect(
        Lzo1z().decompressInto(
          Uint8List.fromList(const [0x11, 0, 0]),
          Uint8List(0),
        ),
        0,
      );
    });
  });

  group('preset dictionary', () {
    test('round-trips with a dictionary', () {
      final dictionary = _random(8192, 1);
      final source = Uint8List.fromList(dictionary.sublist(0, 4096));
      final codec = Lzo1z(dictionary: dictionary);
      final output = Uint8List(_bound(source.length));
      final written = codec.compressInto(source, output);
      final compressed = Uint8List.sublistView(output, 0, written);
      _expectStreamShape(compressed, written, 'dictionary');

      final decoded = Uint8List(source.length);
      expect(codec.decompressInto(compressed, decoded), source.length);
      expect(decoded, orderedEquals(source));
      expect(compressed.length, lessThan(200));

      expect(
        () =>
            const Lzo1z().decompressInto(compressed, Uint8List(source.length)),
        throwsA(isA<LzoException>()),
      );
    });

    test('oversized dictionary is cropped to its final bytes', () {
      final source = _random(4096, 9);
      final dictionary = Uint8List(60000)
        ..setAll(0, _random(55904, 5))
        ..setRange(55904, 60000, source);
      final codec = Lzo1z(dictionary: dictionary);
      final output = Uint8List(_bound(source.length));
      final written = codec.compressInto(source, output);
      final decoded = Uint8List(source.length);
      expect(
        codec.decompressInto(
          Uint8List.sublistView(output, 0, written),
          decoded,
        ),
        source.length,
      );
      expect(decoded, orderedEquals(source));

      final cropped = Uint8List.sublistView(dictionary, 60000 - 0xbfff);
      final croppedDecoded = Uint8List(source.length);
      expect(
        Lzo1z(dictionary: cropped).decompressInto(
          Uint8List.sublistView(output, 0, written),
          croppedDecoded,
        ),
        source.length,
      );
      expect(croppedDecoded, orderedEquals(source));
    });
  });

  group('public API', () {
    test('const constructor and level', () {
      const codec = Lzo1z();
      expect(codec.level, Lzo1zLevel.max);
      expect(codec.quality, 9);
      expect(Lzo1zLevel.max.number, 999);
      expect(Lzo1zLevel.max.memCompress, Lzo999Workspace.memCompress);
    });

    test('Bytes convenience methods', () {
      final source = _text(1024);
      final codec = const Lzo1z();
      final packed = codec.compress(Bytes.fromUint8List(source));
      final restored = codec.decompress(packed, source.length);
      expect(restored.asUint8List(), orderedEquals(source));
    });
  });

  group('errors and malformed data', () {
    test('invalid quality throws LzoException', () {
      for (final quality in [-1, 0, 10]) {
        expect(
          () =>
              Lzo1z(quality: quality).compressInto(Uint8List(4), Uint8List(64)),
          _throwsCode(LzoErrorCode.invalidArgument),
          reason: 'quality $quality',
        );
      }
    });

    test('output-too-small throws outputOverrun', () {
      final source = _text(1024);
      final codec = const Lzo1z();
      final output = Uint8List(_bound(source.length));
      final written = codec.compressInto(source, output);
      expect(
        () => codec.compressInto(source, Uint8List(written - 1)),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('decoding into a short destination throws outputOverrun', () {
      final source = _text(1024);
      final output = Uint8List(_bound(source.length));
      final written = const Lzo1z().compressInto(source, output);
      expect(
        () => const Lzo1z().decompressInto(
          Uint8List.sublistView(output, 0, written),
          Uint8List(source.length - 1),
        ),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('short, truncated and trailing-byte blocks throw LzoException', () {
      for (final bytes in [
        <int>[],
        [0x11],
        [0x11, 0x00],
        [0x00],
        [0x7c], // reuse token without a previous distance
      ]) {
        expect(
          () => const Lzo1z().decompressInto(
            Uint8List.fromList(bytes),
            Uint8List(8),
          ),
          throwsA(isA<LzoException>()),
          reason: '$bytes',
        );
      }

      final source = _pattern(1024);
      final output = Uint8List(_bound(source.length));
      final written = const Lzo1z().compressInto(source, output);
      final valid = Uint8List.sublistView(output, 0, written);
      for (var length = 0; length < written; length++) {
        expect(
          () => const Lzo1z().decompressInto(
            Uint8List.sublistView(valid, 0, length),
            Uint8List(source.length),
          ),
          throwsA(isA<LzoException>()),
          reason: 'prefix $length',
        );
      }

      final trailing = Uint8List.fromList([...valid, 0x00]);
      expect(
        () => const Lzo1z().decompressInto(trailing, Uint8List(source.length)),
        _throwsCode(LzoErrorCode.inputNotConsumed),
      );
    });

    test('corrupted blocks only ever throw LzoException', () {
      final source = _pattern(2048);
      final output = Uint8List(_bound(source.length));
      final written = const Lzo1z().compressInto(source, output);
      final valid = Uint8List.sublistView(output, 0, written);
      final random = Random(999);
      for (var iteration = 0; iteration < 400; iteration++) {
        final corrupted = Uint8List.fromList(valid);
        final flips = 1 + random.nextInt(3);
        for (var i = 0; i < flips; i++) {
          corrupted[random.nextInt(corrupted.length)] = random.nextInt(256);
        }
        try {
          const Lzo1z().decompressInto(corrupted, Uint8List(source.length));
        } on LzoException {
          // Expected for most corruptions.
        } catch (error) {
          fail('non-LzoException for corrupted block: $error');
        }
      }
    });
  });

  group('oracle interop', () {
    final oracle = _Oracle.discover();

    test(
      'liblzo2 compress -> our decoder',
      () {
        final work = oracle.createWorkDirectory();
        addTearDown(work.dispose);
        for (final kind in _kinds) {
          for (final size in [0, 17, 238, 1024, 65536]) {
            final source = _corpus(kind, size);
            final compressed = oracle.compress('lzo1z', '999', source, work);
            final decoded = Uint8List(size);
            expect(
              const Lzo1z().decompressInto(compressed, decoded),
              size,
              reason: '$kind $size',
            );
            expect(decoded, orderedEquals(source), reason: '$kind $size');
          }
        }
      },
      skip: oracle.available
          ? null
          : 'set LZO_ORACLE to the lzo_oracle binary to run interop',
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'our encoder -> liblzo2 decompress',
      () {
        final work = oracle.createWorkDirectory();
        addTearDown(work.dispose);
        for (final quality in [1, 5, 9]) {
          for (final kind in _kinds) {
            for (final size in [17, 1024, 65536]) {
              final source = _corpus(kind, size);
              final output = Uint8List(_bound(size));
              final written = Lzo1z(quality: quality)
                  .compressInto(source, output);
              expect(
                oracle.decompress(
                  'lzo1z',
                  Uint8List.sublistView(output, 0, written),
                  size,
                  work,
                ),
                orderedEquals(source),
                reason: 'q$quality $kind $size',
              );
            }
          }
        }
      },
      skip: oracle.available
          ? null
          : 'set LZO_ORACLE to the lzo_oracle binary to run interop',
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'dictionary interop in both directions',
      () {
        final work = oracle.createWorkDirectory();
        addTearDown(work.dispose);
        final dictionary = _random(8192, 1);
        final source = Uint8List.fromList(dictionary.sublist(0, 4096));
        final codec = Lzo1z(dictionary: dictionary);

        final reference = oracle.compress(
          'lzo1z',
          '999',
          source,
          work,
          dictionary: dictionary,
        );
        final decoded = Uint8List(source.length);
        expect(codec.decompressInto(reference, decoded), source.length);
        expect(decoded, orderedEquals(source));

        final output = Uint8List(_bound(source.length));
        final written = codec.compressInto(source, output);
        expect(
          oracle.decompress(
            'lzo1z',
            Uint8List.sublistView(output, 0, written),
            source.length,
            work,
            dictionary: dictionary,
          ),
          orderedEquals(source),
        );
      },
      skip: oracle.available
          ? null
          : 'set LZO_ORACLE to the lzo_oracle binary to run interop',
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'hand-built streams decode identically',
      () {
        final work = oracle.createWorkDirectory();
        addTearDown(work.dispose);

        final reuse = oracle.decompress('lzo1z', _reuseStream(), 12, work);
        expect(
          reuse,
          orderedEquals(
            Uint8List.fromList(
              List<int>.generate(12, (index) => 0x61 + (index % 4)),
            ),
          ),
        );

        final m3 = oracle.decompress('lzo1z', _m3Stream(), 261, work);
        final expected = Uint8List(261);
        for (var i = 0; i < 256; i++) {
          expected[i] = i & 0xff;
        }
        for (var i = 0; i < 5; i++) {
          expected[256 + i] = expected[i];
        }
        expect(m3, orderedEquals(expected));
      },
      skip: oracle.available
          ? null
          : 'set LZO_ORACLE to the lzo_oracle binary to run interop',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

// ---------------------------------------------------------------------------
// Optional liblzo2 oracle
// ---------------------------------------------------------------------------

final class _Oracle {
  _Oracle._(this._executable, this._throughWsl);

  final String _executable;
  final bool _throughWsl;

  bool get available => _executable.isNotEmpty;

  static _Oracle discover() {
    final value = Platform.environment['LZO_ORACLE'] ?? '';
    return _Oracle._(value, value.startsWith('/'));
  }

  _WorkDirectory createWorkDirectory() =>
      _WorkDirectory(Directory.systemTemp.createTempSync('lzo_neo_lzo1z_'));

  ProcessResult _run(List<String> args) => _throughWsl
      ? Process.runSync('wsl', ['-e', _executable, ...args])
      : Process.runSync(_executable, args);

  String _argumentPath(String path) => _throughWsl ? _toWslPath(path) : path;

  Uint8List compress(
    String algorithm,
    String level,
    Uint8List source,
    _WorkDirectory work, {
    Uint8List? dictionary,
  }) {
    final input = work.write('input.bin', source);
    final output = work.path('output.lzo');
    if (File(output).existsSync()) File(output).deleteSync();
    final args = dictionary == null
        ? [
            'compress',
            algorithm,
            level,
            _argumentPath(input),
            _argumentPath(output),
          ]
        : [
            'compress-dict',
            algorithm,
            _argumentPath(work.write('dictionary.bin', dictionary)),
            _argumentPath(input),
            _argumentPath(output),
          ];
    final result = _run(args);
    if (result.exitCode != 0) {
      fail(
        'oracle compress $algorithm $level failed '
        '(${result.exitCode}): ${result.stderr}',
      );
    }
    return File(output).readAsBytesSync();
  }

  Uint8List decompress(
    String algorithm,
    Uint8List compressed,
    int outputLength,
    _WorkDirectory work, {
    Uint8List? dictionary,
  }) {
    final input = work.write('compressed.lzo', compressed);
    final output = work.path('decoded.bin');
    if (File(output).existsSync()) File(output).deleteSync();
    final args = dictionary == null
        ? [
            'decompress',
            algorithm,
            _argumentPath(input),
            _argumentPath(output),
            '$outputLength',
          ]
        : [
            'decompress-dict',
            algorithm,
            _argumentPath(work.write('dictionary.bin', dictionary)),
            _argumentPath(input),
            _argumentPath(output),
            '$outputLength',
          ];
    final result = _run(args);
    if (result.exitCode != 0) {
      fail(
        'oracle decompress $algorithm failed '
        '(${result.exitCode}): ${result.stderr}',
      );
    }
    return File(output).readAsBytesSync();
  }
}

final class _WorkDirectory {
  _WorkDirectory(this._directory);

  final Directory _directory;

  String path(String name) =>
      '${_directory.path}${Platform.pathSeparator}$name';

  String write(String name, List<int> bytes) {
    final path = this.path(name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  void dispose() {
    if (_directory.existsSync()) _directory.deleteSync(recursive: true);
  }
}

String _toWslPath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final match = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (match == null) return normalized;
  return '/mnt/${match.group(1)!.toLowerCase()}/${match.group(2)}';
}
