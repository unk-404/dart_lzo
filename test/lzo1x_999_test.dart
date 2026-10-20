import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:lzo_neo/src/lzo1x/encoder_9x.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Corpus
// ---------------------------------------------------------------------------

const List<String> _kinds = ['text', 'random', 'zeros', 'pattern'];
const List<int> _sizes = [0, 1, 2, 3, 17, 18, 238, 239, 1024, 65536, 262144];

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

// ---------------------------------------------------------------------------
// Stream shape
// ---------------------------------------------------------------------------

/// Checks the two invariants shared by every LZO1X-derived block: the first
/// token is a literal run (or the empty-stream marker) and the block ends with
/// the canonical `0x11 0x00 0x00` end-of-stream marker.
void _expectStreamShape(Uint8List compressed, int written, String reason) {
  expect(written, greaterThanOrEqualTo(3), reason: reason);
  expect(
    compressed.sublist(written - 3, written),
    orderedEquals(const [0x11, 0x00, 0x00]),
    reason: reason,
  );
  final first = compressed[0];
  if (written == 3) {
    expect(first, 0x11, reason: '$reason: empty stream must be the marker');
  } else {
    // A leading literal run is either `17 + count` (count 1..238) or the
    // zero-extended form for longer runs; never a match opcode.
    expect(
      first == 0 || first > 17,
      isTrue,
      reason: '$reason: unexpected first byte 0x${first.toRadixString(16)}',
    );
  }
}

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  final workspace = Lzo999Workspace();

  group('LZO1X-999 round-trip matrix', () {
    for (var quality = 1; quality <= 9; quality++) {
      test('quality $quality over sizes and data kinds', () {
        for (final kind in _kinds) {
          for (final size in _sizes) {
            final reason = '$kind $size q$quality';
            final source = _corpus(kind, size);
            final output = Uint8List(_bound(size));
            final written = lzo1xCompress999(
              source,
              output,
              quality: quality,
              workspace: workspace,
            );
            final compressed = Uint8List.sublistView(output, 0, written);
            _expectStreamShape(compressed, written, reason);

            final decoded = Uint8List(size);
            final restored = lzoFamilyDecompress(
              compressed,
              decoded,
              family: LzoFamily.lzo1x,
            );
            expect(restored, size, reason: reason);
            expect(decoded, orderedEquals(source), reason: reason);

            // The v0.1.0 decoder must accept the 999 streams as well.
            if (quality == 9) {
              final legacy = Uint8List(size);
              expect(
                Lzo1x().decompressInto(compressed, legacy),
                size,
                reason: '$reason (legacy decoder)',
              );
              expect(legacy, orderedEquals(source), reason: reason);
            }
          }
        }
      });
    }

    test('ratio sanity', () {
      final zeros = Uint8List(65536);
      final zerosOut = Uint8List(_bound(zeros.length));
      final zerosWritten = lzo1xCompress999(
        zeros,
        zerosOut,
        workspace: workspace,
      );
      expect(zerosWritten, lessThan(500));

      final text = _text(65536);
      final textOut = Uint8List(_bound(text.length));
      final textWritten = lzo1xCompress999(text, textOut, workspace: workspace);
      expect(textWritten, lessThan(2000));

      final random = _random(65536, 5);
      final randomOut = Uint8List(_bound(random.length));
      final randomWritten = lzo1xCompress999(
        random,
        randomOut,
        workspace: workspace,
      );
      expect(randomWritten, lessThanOrEqualTo(_bound(random.length)));
      expect(randomWritten, greaterThan(random.length));
    });

    test('empty input is just the end-of-stream marker', () {
      final output = Uint8List(_bound(0));
      final written = lzo1xCompress999(
        Uint8List(0),
        output,
        workspace: workspace,
      );
      expect(written, 3);
      expect(output.sublist(0, written), orderedEquals(const [0x11, 0, 0]));
      final empty = Uint8List(0);
      expect(
        lzoFamilyDecompress(
          Uint8List.sublistView(output, 0, written),
          empty,
          family: LzoFamily.lzo1x,
        ),
        0,
      );
    });
  });

  group('preset dictionary', () {
    test('matches the dictionary and needs it to decode', () {
      // The dictionary starts with the same bytes as the source, so the
      // compressor can reference it at a distance above the output length.
      final dictionary = _random(8192, 1);
      final source = Uint8List.fromList(dictionary.sublist(0, 4096));
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(
        source,
        output,
        quality: 9,
        dictionary: dictionary,
        workspace: workspace,
      );
      final compressed = Uint8List.sublistView(output, 0, written);
      _expectStreamShape(compressed, written, 'dictionary');

      final decoded = Uint8List(source.length);
      expect(
        lzo1xDecompressWithDictionary(
          compressed,
          decoded,
          dictionary: dictionary,
        ),
        source.length,
      );
      expect(decoded, orderedEquals(source));

      // The block references the dictionary, so decoding without it fails.
      expect(
        () => lzoFamilyDecompress(
          compressed,
          Uint8List(source.length),
          family: LzoFamily.lzo1x,
        ),
        throwsA(isA<LzoException>()),
      );
      // Referencing the dictionary makes the block very small.
      expect(compressed.length, lessThan(200));
    });

    test('oversized dictionary is cropped to its final bytes', () {
      final source = _random(4096, 9);
      final dictionary = Uint8List(60000)
        ..setAll(0, _random(55904, 5))
        ..setRange(55904, 60000, source);
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(
        source,
        output,
        quality: 9,
        dictionary: dictionary,
        workspace: workspace,
      );
      final compressed = Uint8List.sublistView(output, 0, written);

      final decoded = Uint8List(source.length);
      expect(
        lzoFamilyDecompress(
          compressed,
          decoded,
          family: LzoFamily.lzo1x,
          dictionary: dictionary,
        ),
        source.length,
      );
      expect(decoded, orderedEquals(source));

      // Only the last 49 151 bytes are visible to either side.
      final cropped = Uint8List.sublistView(dictionary, 60000 - 0xbfff);
      final croppedDecoded = Uint8List(source.length);
      expect(
        lzoFamilyDecompress(
          compressed,
          croppedDecoded,
          family: LzoFamily.lzo1x,
          dictionary: cropped,
        ),
        source.length,
      );
      expect(croppedDecoded, orderedEquals(source));
    });
  });

  group('argument and buffer errors', () {
    test('invalid quality throws LzoException', () {
      for (final quality in [-1, 0, 10, 999]) {
        expect(
          () => lzo1xCompress999(
            Uint8List(4),
            Uint8List(64),
            quality: quality,
            workspace: workspace,
          ),
          _throwsCode(LzoErrorCode.invalidArgument),
          reason: 'quality $quality',
        );
      }
    });

    test('output-too-small throws outputOverrun', () {
      final source = _text(1024);
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(source, output, workspace: workspace);
      expect(
        () => lzo1xCompress999(
          source,
          Uint8List(written - 1),
          workspace: workspace,
        ),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
      expect(
        () =>
            lzo1xCompress999(Uint8List(0), Uint8List(2), workspace: workspace),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('decoding into a short destination throws outputOverrun', () {
      final source = _text(1024);
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(source, output, workspace: workspace);
      expect(
        () => lzoFamilyDecompress(
          Uint8List.sublistView(output, 0, written),
          Uint8List(source.length - 1),
          family: LzoFamily.lzo1x,
        ),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });
  });

  group('malformed input', () {
    test('short and truncated blocks throw LzoException', () {
      for (final bytes in [
        <int>[],
        [0x11],
        [0x11, 0x00],
        [0x00],
        [0x20, 0x00],
      ]) {
        expect(
          () => lzoFamilyDecompress(
            Uint8List.fromList(bytes),
            Uint8List(16),
            family: LzoFamily.lzo1x,
          ),
          throwsA(isA<LzoException>()),
          reason: '$bytes',
        );
      }

      final source = _text(1024);
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(source, output, workspace: workspace);
      final valid = Uint8List.sublistView(output, 0, written);
      for (var length = 0; length < written; length++) {
        expect(
          () => lzoFamilyDecompress(
            Uint8List.sublistView(valid, 0, length),
            Uint8List(source.length),
            family: LzoFamily.lzo1x,
          ),
          throwsA(isA<LzoException>()),
          reason: 'prefix $length',
        );
      }
    });

    test('trailing bytes after the end marker are rejected', () {
      final output = Uint8List(_bound(0));
      final written = lzo1xCompress999(
        Uint8List(0),
        output,
        workspace: workspace,
      );
      final withTrailing = Uint8List.fromList([
        ...Uint8List.sublistView(output, 0, written),
        0x00,
      ]);
      expect(
        () => lzoFamilyDecompress(
          withTrailing,
          Uint8List(4),
          family: LzoFamily.lzo1x,
        ),
        _throwsCode(LzoErrorCode.inputNotConsumed),
      );
    });

    test('corrupted blocks only ever throw LzoException', () {
      final source = _pattern(2048);
      final output = Uint8List(_bound(source.length));
      final written = lzo1xCompress999(source, output, workspace: workspace);
      final valid = Uint8List.sublistView(output, 0, written);
      final random = Random(2024);
      for (var iteration = 0; iteration < 400; iteration++) {
        final corrupted = Uint8List.fromList(valid);
        final flips = 1 + random.nextInt(3);
        for (var i = 0; i < flips; i++) {
          corrupted[random.nextInt(corrupted.length)] = random.nextInt(256);
        }
        try {
          lzoFamilyDecompress(
            corrupted,
            Uint8List(source.length),
            family: LzoFamily.lzo1x,
          );
        } on LzoException {
          // Expected for most corruptions; a still-valid stream may decode.
        } catch (error) {
          fail('non-LzoException for corrupted block: $error');
        }
      }
    });
  });

  group('buffer handling', () {
    test('overlapping source and destination is supported', () {
      final source = _text(1024);
      final bound = _bound(source.length);
      final buffer = Uint8List(source.length + bound + 512);
      buffer.setRange(0, source.length, source);
      final destination = Uint8List.sublistView(buffer, 512, 512 + bound);
      final written = lzo1xCompress999(
        Uint8List.sublistView(buffer, 0, source.length),
        destination,
        workspace: workspace,
      );
      final compressed = Uint8List.sublistView(destination, 0, written);
      final decoded = Uint8List(source.length);
      expect(
        lzoFamilyDecompress(compressed, decoded, family: LzoFamily.lzo1x),
        source.length,
      );
      expect(decoded, orderedEquals(source));
    });

    test('workspace is reusable across qualities and inputs', () {
      final text = _text(4096);
      final pattern = _pattern(4096);
      for (final quality in [1, 9, 4]) {
        for (final source in [text, pattern]) {
          final output = Uint8List(_bound(source.length));
          final written = lzo1xCompress999(
            source,
            output,
            quality: quality,
            workspace: workspace,
          );
          final decoded = Uint8List(source.length);
          expect(
            lzoFamilyDecompress(
              Uint8List.sublistView(output, 0, written),
              decoded,
              family: LzoFamily.lzo1x,
            ),
            source.length,
          );
          expect(decoded, orderedEquals(source));
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
            final compressed = oracle.compress('lzo1x', '999', source, work);
            final decoded = Uint8List(size);
            expect(
              lzoFamilyDecompress(compressed, decoded, family: LzoFamily.lzo1x),
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
              final written = lzo1xCompress999(
                source,
                output,
                quality: quality,
                workspace: workspace,
              );
              final restored = oracle.decompress(
                'lzo1x',
                Uint8List.sublistView(output, 0, written),
                size,
                work,
              );
              expect(
                restored,
                orderedEquals(source),
                reason: '$kind $size q$quality',
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

        final reference = oracle.compress(
          'lzo1x',
          '999',
          source,
          work,
          dictionary: dictionary,
        );
        final decoded = Uint8List(source.length);
        expect(
          lzoFamilyDecompress(
            reference,
            decoded,
            family: LzoFamily.lzo1x,
            dictionary: dictionary,
          ),
          source.length,
        );
        expect(decoded, orderedEquals(source));

        final output = Uint8List(_bound(source.length));
        final written = lzo1xCompress999(
          source,
          output,
          quality: 8,
          dictionary: dictionary,
          workspace: workspace,
        );
        expect(
          oracle.decompress(
            'lzo1x',
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
  });
}

// ---------------------------------------------------------------------------
// Optional liblzo2 oracle
// ---------------------------------------------------------------------------

/// A thin wrapper around the `lzo_oracle` command line tool.
///
/// Set `LZO_ORACLE` to the binary path to enable the interop tests. A path
/// starting with `/` is executed through WSL; other paths run directly.
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
      _WorkDirectory(Directory.systemTemp.createTempSync('lzo_neo_lzo1x_999_'));

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
