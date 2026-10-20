/// Tests for the LZO1 codec.
///
/// The suite has three layers:
///
/// * pure-Dart round trips over the boundary sizes and the usual data shapes;
/// * reference streams produced by liblzo2 2.10 (`lzo1_compress` /
///   `lzo1_99_compress`), embedded as base64, so the decoder is exercised on
///   real bitstreams without a native library;
/// * an optional differential test against the `lzo_oracle` binary. Set
///   `LZO_ORACLE` to its path (a `/...` path is run through WSL) to enable it.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart' show LzoErrorCode, LzoException;
import 'package:lzo_neo/src/lzo1.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Data and reference streams.
// ---------------------------------------------------------------------------

const List<int> _sizes = [0, 1, 2, 3, 17, 18, 238, 239, 1024, 65536, 262144];

const List<String> _kinds = ['text', 'random', 'zeros', 'pattern'];

Uint8List _data(String kind, int length) {
  final out = Uint8List(length);
  switch (kind) {
    case 'text':
      const sample = 'the quick brown fox jumps over the lazy dog. ';
      for (var i = 0; i < length; i++) {
        out[i] = sample.codeUnitAt(i % sample.length);
      }
    case 'random':
      final random = Random(0xc0ffee + length);
      for (var i = 0; i < length; i++) {
        out[i] = random.nextInt(256);
      }
    case 'zeros':
      break;
    case 'pattern':
      for (var i = 0; i < length; i++) {
        out[i] = i & 0x3f;
      }
    default:
      throw ArgumentError.value(kind, 'kind');
  }
  return out;
}

/// The corpus the embedded reference streams were produced from.
Map<String, Uint8List> _corpus() {
  const sample = 'the quick brown fox jumps over the lazy dog. ';
  final r1 = Uint8List(400);
  for (var i = 0; i < r1.length; i++) {
    r1[i] = i % 4 == 3 ? (i & 0xff) : 'abc'.codeUnitAt(i % 4);
  }
  final random = Random(0x0badf00d);
  final random1000 = Uint8List.fromList(
    List<int>.generate(1000, (_) => random.nextInt(256)),
  );
  final text = Uint8List(3000);
  for (var i = 0; i < text.length; i++) {
    text[i] = sample.codeUnitAt(i % sample.length);
  }
  return {
    'hello': Uint8List.fromList('hello, lzo world!'.codeUnits),
    'r1pattern': r1,
    'random1000': random1000,
    'text3000': text,
  };
}

/// `lzo1_compress` output for [_corpus].
const Map<String, String> _fastVectors = {
  'hello': 'EWhlbGxvLCBsem8gd29ybGQh',
  'r1pattern': 'CGFiYwNhYmMHIwABCyMAAQ8jAAETIwABFyMAARsjAAEfIwABIyMAAScjAAErIwABLyMAATMjAAE3IwABOyMAAT8jAAFDIwABRyMAAUsjAAFPIwABUyMAAVcjAAFbIwABXyMAAWMjAAFnIwABayMAAW8jAAFzIwABdyMAAXsjAAF/IwABgyMAAYcjAAGLIwABjyMAAZMjAAGXIwABmyMAAZ8jAAGjIwABpyMAAasjAAGvIwABsyMAAbcjAAG7IwABvyMAAcMjAAHHIwAByyMAAc8jAAHTIwAB1yMAAdsjAAHfIwAB4yMAAecjAAHrIwAB7yMAAfMjAAH3IwAB+yMAAf8jAP8HgQNiY48=',
  'random1000': 'APlqeYBYnJn7EFLSUag02AsgZyWk6bS8GsnCroXBhqQwL4prCLiDY+jC0uAojVjmqBCzyK3/CW6/K8t4Cl8a5htr/YJ+R4BxV49whrASVuBrCNx5d39I030akoKOEh2fKTJrrJRiwXHV99qk0h6zCJOxKfxQxyDOy4DoP6piEwiORvBSmfu4hyTf2U4S14C6nff35iAc6cf9o7gYcMHfg+708L2LJYwIvqoaVIhIzZ1BLMd2U5ouZuNF0IGGp/VrQX6opoUKLAm1y/z+BhZ96tkr3phRG0r8As+IR9u/XzQZ8+NJue78bzlJ94hBqux/71Ne40OykVT/fmj2OjYNBczIfPA8z/5pG5NYE4VGZpS2XxM/y4mB9WnzmD4gxG199FMgkSGQX8WrCvZng4uqdgSLXKF4WIKiGfaizdrKFNgS5o0eSanwggFBGqRdZKHhNRWCMt8v1cwHPIMNEwPoe6rOTpGYirT3LCvnuYIGX6gIzZPdFe6+dL4aDyoCq2uf3xvfZzKJz+TmH68tghSxDNU2teSwdRzvkhnntCiaIEkNZEoDJIR209SXr+/z+BsYrgk9l2Y8VdXy5tkptfQhSgbLXxI9SH47mzeohn2mKM5WMNndBfJBRKCFFwngB6cQKYI2yGCWzid03IiPY5AcEIWcr/tm5D8IBqC8NzDj3iULwQD4x/AWxtPEx/dxc4CAfptDNMyK8ZIUolSQ5CXot9Zz0aolqtwdatx8pWvVEEdhyoWw7HhBTNPvNnKxKx/Nyiz61zP55ACswYsfaD/RsJkafH3vcq5m+TQVbJbHYReoaKpmUxaU2G0l1WVZEjWIJurv68mUBeyDaD8KXiHw8HTLXwyEmfLWy0hh+VGLOINpuEHdaie07/pRU9aghAwilOE74V7EnMzqnOQkjNDSwHZroI0tDXmsb+6lFqUZDzeOaCfcTCnd8Lrr/WCIBqOtishG33RR5yDcZXR13XApQRl9BGZOm7HZ6tAliEsFnX1O+5hNO/Up1eOdeYhLiTm7j+DkzgF2tSHBpfa4yVL14Ti8tOT1ucy1YDGckgCw1LY4yTm6hChxpmWELOFe0awucYHiZXJQnzAdP5+gW9xU3loUmzwodIKzBKdSDB/yXjt+H9kuTJOYq57Xpy82p8ZoeKoQ1pzjFuK2gT4dETGCGcYz50QEMHi7yhUvuImpdRbaUkL7HzPSRO0OcV8yxlpu/22F3XlHiSGHN9ZT0IWOGpx+ezt+7V2xF6Gt8B59QaeaO7dujhQRQTchBBvGX6wUBPpgIBjosLoas7bpm4dgqGEQ3P2oNeZVnQDKvaIEO6vSy72ejqQa41ncR0uC3g==',
  'text3000': 'AAB0aGUgcXVpY2sgYnJvd24gZm94IGp1bXBzIG92ZXIgdD4ACWxhenkgZG9nLm0A7AH/7Qj/+xD/6Rn/9yH/5Sr/8zL/4Tv/MELiQv/iQv/iQv/iQiADdmVy',
};

/// `lzo1_99_compress` output for [_corpus].
const Map<String, String> _maxVectors = {
  'hello': 'EWhlbGxvLCBsem8gd29ybGQh',
  'r1pattern': 'BGFiYwMjAAEHJwABCysAAQ8jAAETJwABFysAARsvAAEfIwABIycAAScrAAErLwABLyMAATMnAAE3KwABOy8AAT8jAAFDJwABRysAAUsvAAFPIwABUycAAVcrAAFbLwABXyMAAWMnAAFnKwABay8AAW8jAAFzJwABdysAAXsvAAF/IwABgycAAYcrAAGLLwABjyMAAZMnAAGXKwABmy8AAZ8jAAGjJwABpysAAasvAAGvIwABsycAAbcrAAG7LwABvyMAAcMnAAHHKwAByy8AAc8jAAHTJwAB1ysAAdsvAAHfIwAB4ycAAecrAAHrLwAB7yMAAfMnAAH3KwAB+y8AAf8jAP8HhA==',
  'random1000': 'APlqeYBYnJn7EFLSUag02AsgZyWk6bS8GsnCroXBhqQwL4prCLiDY+jC0uAojVjmqBCzyK3/CW6/K8t4Cl8a5htr/YJ+R4BxV49whrASVuBrCNx5d39I030akoKOEh2fKTJrrJRiwXHV99qk0h6zCJOxKfxQxyDOy4DoP6piEwiORvBSmfu4hyTf2U4S14C6nff35iAc6cf9o7gYcMHfg+708L2LJYwIvqoaVIhIzZ1BLMd2U5ouZuNF0IGGp/VrQX6opoUKLAm1y/z+BhZ96tkr3phRG0r8As+IR9u/XzQZ8+NJue78bzlJ94hBqux/71Ne40OykVT/fmj2OjYNBczIfPA8z/5pG5NYE4VGZpS2XxM/y4mB9WnzmD4gxG199FMgkSGQX8WrCvZng4uqdgSLXKF4WIKiGfaizdrKFNgS5o0eSanwggFBGqRdZKHhNRWCMt8v1cwHPIMNEwPoe6rOTpGYirT3LCvnuYIGX6gIzZPdFe6+dL4aDyoCq2uf3xvfZzKJz+TmH68tghSxDNU2teSwdRzvkhnntCiaIEkNZEoDJIR209SXr+/z+BsYrgk9l2Y8VdXy5tkptfQhSgbLXxI9SH47mzeohn2mKM5WMNndBfJBRKCFFwngB6cQKYI2yGCWzid03IiPY5AcEIWcr/tm5D8IBqC8NzDj3iULwQD4x/AWxtPEx/dxc4CAfptDNMyK8ZIUolSQ5CXot9Zz0aolqtwdatx8pWvVEEdhyoWw7HhBTNPvNnKxKx/Nyiz61zP55ACswYsfaD/RsJkafH3vcq5m+TQVbJbHYReoaKpmUxaU2G0l1WVZEjWIJurv68mUBeyDaD8KXiHw8HTLXwyEmfLWy0hh+VGLOINpuEHdaie07/pRU9aghAwilOE74V7EnMzqnOQkjNDSwHZroI0tDXmsb+6lFqUZDzeOaCfcTCnd8Lrr/WCIBqOtishG33RR5yDcZXR13XApQRl9BGZOm7HZ6tAliEsFnX1O+5hNO/Up1eOdeYhLiTm7j+DkzgF2tSHBpfa4yVL14Ti8tOT1ucy1YDGckgCw1LY4yTm6hChxpmWELOFe0awucYHiZXJQnzAdP5+gW9xU3loUmzwodIKzBKdSDB/yXjt+H9kuTJOYq57Xpy82p8ZoeKoQ1pzjFuK2gT4dETGCGcYz50QEMHi7yhUvuImpdRbaUkL7HzPSRO0OcV8yxlpu/22F3XlHiSGHN9ZT0IWOGpx+ezt+7V2xF6Gt8B59QaeaO7dujhQRQTchBBvGX6wUBPpgIBjosLoas7bpm4dgqGEQ3P2oNeZVnQDKvaIEO6vSy72ejqQa41ncR0uC3g==',
  'text3000': 'H3RoZSBxdWljayBicm93biBmb3gganVtcHMgb3ZlciBeAAlsYXp5IGRvZy5tAOwB/+wB/+wB/+kZ/+wB/+wB/+wB/+wB/+9D/+wB/+wB/+wBJg==',
};

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

Lzo1 _codec(Lzo1Level level) => Lzo1(level: level);

Uint8List _compress(Lzo1 codec, Uint8List source) {
  final output = Uint8List(codec.compressBound(source.length));
  final written = codec.compressInto(source, output);
  return Uint8List.sublistView(output, 0, written);
}

Uint8List _decompress(Lzo1 codec, List<int> stream, int length) {
  final output = Uint8List(length);
  final written = codec.decompressInto(Uint8List.fromList(stream), output);
  expect(written, length);
  return output;
}

void main() {
  for (final level in Lzo1Level.values) {
    final vectors = level == Lzo1Level.fast ? _fastVectors : _maxVectors;

    group('${level.name} round trip', () {
      for (final kind in _kinds) {
        test(kind, () {
          final codec = _codec(level);
          for (final size in _sizes) {
            final source = _data(kind, size);
            final compressed = _compress(codec, source);
            final restored = _decompress(codec, compressed, size);
            expect(restored, orderedEquals(source), reason: '$kind size $size');
            expect(
              compressed.length,
              lessThanOrEqualTo(codec.compressBound(size)),
              reason: '$kind size $size bound',
            );
          }
        });
      }

      test('overlapping buffers are snapshotted', () {
        final codec = _codec(level);
        final sourceData = _data('text', 4096);
        final capacity = codec.compressBound(sourceData.length);
        final buffer = Uint8List(sourceData.length + capacity);
        buffer.setRange(8, 8 + sourceData.length, sourceData);
        final source = Uint8List.sublistView(buffer, 8, 8 + sourceData.length);
        final destination = Uint8List.sublistView(buffer, 0, capacity);

        final written = codec.compressInto(source, destination);
        final restored = _decompress(
          codec,
          destination.sublist(0, written),
          sourceData.length,
        );
        expect(restored, orderedEquals(sourceData));
      });

      test('Bytes API round trip', () {
        final codec = _codec(level);
        final source = _data('random', 10000);
        final compressed = codec.compress(Bytes.fromUint8List(source));
        final restored = codec.decompress(compressed, source.length);
        expect(restored.asUint8List(), orderedEquals(source));
      });

      test('destination larger than the output is allowed', () {
        final codec = _codec(level);
        final source = _data('text', 1000);
        final compressed = _compress(codec, source);
        final output = Uint8List(source.length + 32);
        final written = codec.decompressInto(
          Uint8List.fromList(compressed),
          output,
        );
        expect(written, source.length);
        expect(
          Uint8List.sublistView(output, 0, written),
          orderedEquals(source),
        );
      });
    });

    group('${level.name} reference vectors', () {
      final corpus = _corpus();
      for (final entry in corpus.entries) {
        test(entry.key, () {
          final codec = _codec(level);
          final reference = base64Decode(vectors[entry.key]!);
          final decoded = _decompress(codec, reference, entry.value.length);
          expect(decoded, orderedEquals(entry.value));

          final round = _decompress(
            codec,
            _compress(codec, entry.value),
            entry.value.length,
          );
          expect(round, orderedEquals(entry.value));
        });
      }
    });

    group('${level.name} edge cases', () {
      test('empty input compresses to an empty block', () {
        final codec = _codec(level);
        expect(_compress(codec, Uint8List(0)), isEmpty);
        expect(codec.decompressInto(Uint8List(0), Uint8List(0)), 0);
      });

      test('output too small throws LzoException', () {
        final codec = _codec(level);
        final source = _data('text', 3000);
        final compressed = _compress(codec, source);

        for (final limit in [0, 1, compressed.length - 1]) {
          expect(
            () => codec.decompressInto(
              Uint8List.fromList(compressed),
              Uint8List(limit),
            ),
            throwsA(isA<LzoException>()),
            reason: 'decompress limit $limit',
          );
          expect(
            () => codec.compressInto(source, Uint8List(limit)),
            throwsA(isA<LzoException>()),
            reason: 'compress limit $limit',
          );
        }
      });

      test('malformed and truncated input throws only LzoException', () {
        final codec = _codec(level);
        final source = _data('text', 1000);
        final compressed = _compress(codec, source);

        for (var length = 0; length < compressed.length; length++) {
          try {
            codec.decompressInto(
              Uint8List.sublistView(compressed, 0, length),
              Uint8List(source.length),
            );
          } on LzoException {
            // Expected: a truncated block is rejected.
          } catch (error) {
            fail('prefix $length threw $error');
          }
        }

        final corrupted = Uint8List.fromList(compressed);
        for (var index = 0; index < corrupted.length; index++) {
          corrupted[index] ^= 0x5a;
          try {
            codec.decompressInto(
              Uint8List.fromList(corrupted),
              Uint8List(source.length),
            );
          } on LzoException {
            // Expected for most corruptions.
          } catch (error) {
            fail('corruption at $index threw $error');
          }
          corrupted[index] ^= 0x5a;
        }

        final random = Random(11);
        for (var length = 0; length <= 64; length++) {
          final garbage = Uint8List.fromList(
            List<int>.generate(length, (_) => random.nextInt(256)),
          );
          try {
            codec.decompressInto(garbage, Uint8List(512));
          } on LzoException {
            // Allowed.
          } catch (error) {
            fail('garbage length $length threw $error');
          }
        }
      });

      test('crafted grammar corners', () {
        final codec = _codec(level);
        // A single literal byte.
        expect(
          _decompress(codec, const [0x01, 0x41], 1),
          orderedEquals(const [0x41]),
        );
        // A short R0 literal run: 0x00 0x20 is 32 + 32 = 64 literals.
        final r0Short = <int>[0x00, 0x20];
        final r0ShortBody = List<int>.generate(64, (i) => i);
        expect(
          _decompress(codec, [...r0Short, ...r0ShortBody], 64),
          orderedEquals(r0ShortBody),
        );
        // A long R0 run: 0x00 0xF8 is R0FAST = 280 literals.
        final r0FastBody = List<int>.generate(280, (i) => i & 0xff);
        expect(
          _decompress(codec, [0x00, 0xf8, ...r0FastBody], 280),
          orderedEquals(r0FastBody),
        );
        // A short match: "abc" followed by a 3-byte match at distance 3.
        expect(
          _decompress(codec, const [0x03, 0x61, 0x62, 0x63, 0x22, 0x00], 6),
          orderedEquals('abcabc'.codeUnits),
        );
        // A long match: "abc" followed by a 9-byte match at distance 3.
        expect(
          _decompress(codec, const [
            0x03,
            0x61,
            0x62,
            0x63,
            0xe2,
            0x00,
            0x00,
          ], 12),
          orderedEquals('abcabcabcabc'.codeUnits),
        );
      });

      test('decoder rejects a match before the output start', () {
        final codec = _codec(level);
        expect(
          () => codec.decompressInto(
            Uint8List.fromList(const [0x22, 0x00]),
            Uint8List(8),
          ),
          throwsA(
            isA<LzoException>().having(
              (e) => e.code,
              'code',
              LzoErrorCode.lookbehindOverrun,
            ),
          ),
        );
      });
    });
  }

  group('oracle interop', () {
    final oracle = _Oracle.discover();
    for (final level in Lzo1Level.values) {
      test(
        'level ${level.name} against liblzo2',
        () {
          final codec = _codec(level);
          final work = oracle.createWorkDirectory();
          addTearDown(work.dispose);
          var total = 0;
          var decodeOk = 0;
          var encodeOk = 0;
          for (final kind in _kinds) {
            for (final size in _sizes) {
              total++;
              final source = _data(kind, size);
              final reference = oracle.compress(
                'lzo1',
                '${level.number}',
                source,
                work,
                '${level.name}_${kind}_$size',
              );
              final decoded = Uint8List(size);
              final written = codec.decompressInto(reference, decoded);
              expect(written, size, reason: '$kind $size decoded size');
              expect(decoded, orderedEquals(source), reason: '$kind $size');
              decodeOk++;

              final compressed = _compress(codec, source);
              expect(
                oracle.decompress('lzo1', compressed, size, work),
                orderedEquals(source),
                reason: '$kind $size',
              );
              encodeOk++;
            }
          }
          printOnFailure(
            'lzo1 ${level.name}: cells=$total decode=$decodeOk encode=$encodeOk',
          );
          expect(decodeOk, total);
          expect(encodeOk, total);
        },
        timeout: const Timeout(Duration(minutes: 5)),
        skip: oracle.available
            ? null
            : 'set LZO_ORACLE to the lzo_oracle binary to run interop',
      );
    }
  });
}

/// A thin wrapper around the `lzo_oracle` command line tool.
final class _Oracle {
  _Oracle._(this.executable, this.throughWsl);

  final String executable;
  final bool throughWsl;

  bool get available => executable.isNotEmpty;

  static _Oracle discover() {
    final value = Platform.environment['LZO_ORACLE'] ?? '';
    return _Oracle._(value, value.startsWith('/'));
  }

  _WorkDirectory createWorkDirectory() =>
      _WorkDirectory(Directory.systemTemp.createTempSync('lzo_neo_lzo1_'));

  ProcessResult _run(List<String> args) {
    final executablePath = throughWsl
        ? ['wsl', '-e', executable]
        : [executable];
    return Process.runSync(executablePath.first, [
      ...executablePath.skip(1),
      ...args,
    ]);
  }

  String _argumentPath(String nativePath) =>
      throughWsl ? _toWslPath(nativePath) : nativePath;

  Uint8List compress(
    String algorithm,
    String level,
    Uint8List source,
    _WorkDirectory work,
    String name,
  ) {
    final input = work.write('$name.raw', source);
    final output = '${work.directory.path}${Platform.pathSeparator}$name.lzo';
    final result = _run([
      'compress',
      algorithm,
      level,
      _argumentPath(input),
      _argumentPath(output),
    ]);
    if (result.exitCode != 0) {
      fail(
        'oracle compress $algorithm $level $name failed '
        '(${result.exitCode}): ${result.stderr}',
      );
    }
    return File(output).readAsBytesSync();
  }

  Uint8List decompress(
    String algorithm,
    Uint8List source,
    int outputLength,
    _WorkDirectory work,
  ) {
    final input = work.write('dart.lzo', source);
    final output = '${work.directory.path}${Platform.pathSeparator}dart.raw';
    final result = _run([
      'decompress',
      algorithm,
      _argumentPath(input),
      _argumentPath(output),
      '$outputLength',
    ]);
    if (result.exitCode != 0) {
      fail(
        'oracle decompress $algorithm failed (${result.exitCode}): '
        '${result.stderr}',
      );
    }
    return File(output).readAsBytesSync();
  }
}

final class _WorkDirectory {
  _WorkDirectory(this.directory);

  final Directory directory;

  String write(String name, List<int> bytes) {
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

/// Converts a Windows path to the WSL `/mnt/<drive>/...` form.
String _toWslPath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final match = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (match == null) return normalized;
  return '/mnt/${match.group(1)!.toLowerCase()}/${match.group(2)!}';
}
