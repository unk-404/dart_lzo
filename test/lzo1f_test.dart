/// Tests for the LZO1F codec.
///
/// Besides pure Dart round-trip, grammar and robustness checks, the
/// `liblzo2 interop` group compresses and decompresses every level against the
/// reference C implementation. It uses an oracle binary built from
/// `tool/oracle`; when the oracle cannot be built (no WSL/compiler/reference
/// sources) that group is skipped instead of failing.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart' show LzoErrorCode, LzoException;
import 'package:lzo_neo/src/lzo1f.dart';
import 'package:test/test.dart';

const _textBase =
    'The quick brown fox jumps over the lazy dog. '
    'The Quick Brown Fox jumps over the Lazy Dog! '
    'LZO1F is a raw block codec with literal runs and back-references. ';

const _kinds = <String>['text', 'random', 'zeros', 'pattern'];

const _sizes = <int>[0, 1, 2, 3, 17, 18, 238, 239, 1024, 65536, 262144];

const _extraSizes = <int>[
  4,
  5,
  9,
  10,
  11,
  12,
  30,
  31,
  32,
  33,
  34,
  255,
  256,
  286,
  287,
  4096,
];

Uint8List _text(int length) {
  final output = Uint8List(length);
  for (var i = 0; i < length; i++) {
    output[i] = _textBase.codeUnitAt(i % _textBase.length);
  }
  return output;
}

Uint8List _random(int length) {
  final random = Random(length * 31 + 7);
  final output = Uint8List(length);
  for (var i = 0; i < length; i++) {
    output[i] = random.nextInt(256);
  }
  return output;
}

Uint8List _pattern(int length) {
  final output = Uint8List(length);
  for (var i = 0; i < length; i++) {
    output[i] = ((i * 7) ^ (i >> 3)) % 13;
  }
  return output;
}

Uint8List _corpus(int length, String kind) => switch (kind) {
  'text' => _text(length),
  'random' => _random(length),
  'zeros' => Uint8List(length),
  'pattern' => _pattern(length),
  _ => throw ArgumentError.value(kind, 'kind'),
};

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

/// Whether [action] fails with an [LzoException] and nothing else.
bool _throwsLzo(void Function() action) {
  try {
    action();
  } on LzoException {
    return true;
  }
  return false;
}

Uint8List _decode(Lzo1f codec, List<int> encoded, int rawLength) {
  final output = Uint8List(rawLength);
  final written = codec.decompressInto(Uint8List.fromList(encoded), output);
  expect(written, rawLength);
  return output;
}

// ---------------------------------------------------------------------------
// liblzo2 oracle plumbing
// ---------------------------------------------------------------------------

final Directory _scratch = Directory.systemTemp.createTempSync('lzo_neo_1f_');
Directory _temporary = Directory('.');
var _oracleReady = false;
var _oracleIsNative = false;
var _oracleCommand = '';
var _scriptCounter = 0;

/// Converts a Windows path to the `/mnt/<drive>/...` form used inside WSL.
String _wslPath(String path) {
  final absolute = File(path).absolute.path;
  final match = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(absolute);
  if (match == null) return absolute.replaceAll('\\', '/');
  return '/mnt/${match.group(1)!.toLowerCase()}/'
      '${match.group(2)!.replaceAll('\\', '/')}';
}

Future<void> _runBash(String script) async {
  if (!_scratch.existsSync()) _scratch.createSync(recursive: true);
  final file = File('${_scratch.path}/task_${_scriptCounter++}.sh');
  file.writeAsStringSync(script);
  final result = await Process.run('wsl', <String>[
    'bash',
    _wslPath(file.path),
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'WSL command failed with ${result.exitCode}:\n${result.stderr}',
    );
  }
}

/// Builds (or locates) the liblzo2 oracle used by the interop group.
Future<bool> _prepareOracle() async {
  final configured = Platform.environment['LZO_ORACLE'];
  if (configured != null && configured.isNotEmpty) {
    if (!File(configured).existsSync()) return false;
    final version = Process.runSync(configured, <String>['version']);
    if (version.exitCode != 0) return false;
    _oracleIsNative = true;
    _oracleCommand = configured;
    return true;
  }

  final referenceRoot = Platform.environment['LZO_SOURCE'] ?? '';
  if (referenceRoot.isEmpty) return false;
  final library = File('$referenceRoot/src/.libs/liblzo2.a');
  final oracleSource = File('tool/oracle/lzo_oracle.c');
  if (!library.existsSync() || !oracleSource.existsSync()) return false;

  if (!Platform.isWindows) {
    final binary = '${_scratch.path}/oracle_native';
    final build = Process.runSync('gcc', <String>[
      '-O2',
      '-I$referenceRoot/include',
      '-o',
      binary,
      oracleSource.path,
      library.path,
    ]);
    if (build.exitCode != 0) return false;
    _oracleIsNative = true;
    _oracleCommand = binary;
    return true;
  }

  try {
    final binary = File('${_scratch.path}/oracle_wsl');
    final script = StringBuffer()
      ..writeln('set -e')
      ..writeln('cd "${_wslPath(Directory.current.path)}"')
      ..writeln(
        'gcc -O2 -I"$referenceRoot/include" -o "${_wslPath(binary.path)}" '
        '"${oracleSource.path}" "${library.path}"',
      )
      ..writeln('"${_wslPath(binary.path)}" version > /dev/null');
    await _runBash(script.toString());
    _oracleIsNative = false;
    _oracleCommand = _wslPath(binary.path);
    return true;
  } on Object {
    return false;
  }
}

final class _CompressJob {
  const _CompressJob(this.inputPath, this.outputPath, this.level);

  final String inputPath;
  final String outputPath;
  final int level;
}

final class _DecompressJob {
  const _DecompressJob(this.inputPath, this.outputPath, this.outputLength);

  final String inputPath;
  final String outputPath;
  final int outputLength;
}

Future<void> _referenceCompress(
  String algorithm,
  List<_CompressJob> jobs,
) async {
  if (_oracleIsNative) {
    for (final job in jobs) {
      final result = Process.runSync(_oracleCommand, <String>[
        'compress',
        algorithm,
        '${job.level}',
        job.inputPath,
        job.outputPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError('oracle compress failed: ${result.stderr}');
      }
    }
    return;
  }
  final script = StringBuffer('set -e\n');
  for (final job in jobs) {
    script.writeln(
      '"$_oracleCommand" compress $algorithm ${job.level} '
      '"${_wslPath(job.inputPath)}" "${_wslPath(job.outputPath)}"',
    );
  }
  await _runBash(script.toString());
}

Future<void> _referenceDecompress(
  String algorithm,
  List<_DecompressJob> jobs,
) async {
  if (_oracleIsNative) {
    for (final job in jobs) {
      final result = Process.runSync(_oracleCommand, <String>[
        'decompress',
        algorithm,
        job.inputPath,
        job.outputPath,
        '${job.outputLength}',
      ]);
      if (result.exitCode != 0) {
        throw StateError('oracle decompress failed: ${result.stderr}');
      }
    }
    return;
  }
  final script = StringBuffer('set -e\n');
  for (final job in jobs) {
    script.writeln(
      '"$_oracleCommand" decompress $algorithm '
      '"${_wslPath(job.inputPath)}" "${_wslPath(job.outputPath)}" '
      '${job.outputLength}',
    );
  }
  await _runBash(script.toString());
}

// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    _temporary = Directory.systemTemp.createTempSync('lzo1f_test_');
    for (final kind in _kinds) {
      for (final size in _sizes) {
        File('${_temporary.path}/raw_${kind}_$size.bin')
            .writeAsBytesSync(_corpus(size, kind));
      }
    }
    _oracleReady = await _prepareOracle();
  });

  tearDownAll(() {
    if (_temporary.existsSync()) _temporary.deleteSync(recursive: true);
  });
  group('levels', () {
    test('numbers match liblzo2', () {
      expect(Lzo1fLevel.fast1.number, 1);
      expect(Lzo1fLevel.max.number, 999);
    });
  });

  group('round trip', () {
    for (final level in Lzo1fLevel.values) {
      test('${level.name} over the acceptance grid', () {
        final codec = Lzo1f(level: level);
        for (final size in _sizes) {
          for (final kind in _kinds) {
            final source = _corpus(size, kind);
            final bound = codec.compressBound(size);
            final compressed = Uint8List(bound);
            final written = codec.compressInto(source, compressed);
            expect(
              written,
              lessThanOrEqualTo(bound),
              reason: '$kind $size: beyond compressBound',
            );

            final decoded = Uint8List(size);
            final restored = codec.decompressInto(
              Uint8List.sublistView(compressed, 0, written),
              decoded,
            );
            expect(restored, size, reason: '$kind $size');
            expect(decoded, orderedEquals(source), reason: '$kind $size');
          }
        }
      });

      test('${level.name} over token boundary sizes', () {
        final codec = Lzo1f(level: level);
        for (final size in _extraSizes) {
          for (final kind in _kinds) {
            final source = _corpus(size, kind);
            final compressed = Uint8List(codec.compressBound(size));
            final written = codec.compressInto(source, compressed);
            final decoded = Uint8List(size);
            expect(
              codec.decompressInto(
                Uint8List.sublistView(compressed, 0, written),
                decoded,
              ),
              size,
              reason: '$kind $size',
            );
            expect(decoded, orderedEquals(source), reason: '$kind $size');
          }
        }
      });
    }

    test('Bytes API round-trips', () {
      for (final level in Lzo1fLevel.values) {
        final codec = Lzo1f(level: level);
        final source = Bytes.fromUint8List(_corpus(4096, 'text'));
        final compressed = codec.compress(source);
        final decoded = codec.decompress(compressed, source.length);
        expect(decoded.length, source.length);
        expect(decoded.asUint8List(), orderedEquals(source.asUint8List()));
      }
    });

    test('a reusable const codec keeps working', () {
      const codec = Lzo1f();
      final first = _corpus(1024, 'pattern');
      final second = _corpus(238, 'text');
      for (final source in [first, second, first]) {
        final compressed = Uint8List(codec.compressBound(source.length));
        final written = codec.compressInto(source, compressed);
        final decoded = Uint8List(source.length);
        expect(
          codec.decompressInto(
            Uint8List.sublistView(compressed, 0, written),
            decoded,
          ),
          source.length,
        );
        expect(decoded, orderedEquals(source));
      }
    });
  });

  group('reference vectors produced by liblzo2 2.10', () {
    final vectors = <String, (Uint8List, List<int>, List<int>)>{
      'empty': (Uint8List(0), _empty, _emptyMax),
      'text 17': (_text(17), _text17, _text17Max),
      'text 238': (_text(238), _text238, _text238Max),
      'zeros 100': (Uint8List(100), _zeros100, _zeros100Max),
      'pattern 239': (_pattern(239), _pattern239, _pattern239Max),
      'text 1024': (_text(1024), _text1024, _text1024Max),
    };

    vectors.forEach((name, vector) {
      test(name, () {
        final (raw, fast1, max) = vector;
        expect(
          _decode(const Lzo1f(), fast1, raw.length),
          orderedEquals(raw),
          reason: 'level 1',
        );
        expect(
          _decode(const Lzo1f(level: Lzo1fLevel.max), max, raw.length),
          orderedEquals(raw),
          reason: 'level 999',
        );
      });
    });
  });

  group('decoder grammar', () {
    test('compact three-byte match after a long literal run', () {
      // 0x801 literals, then a two-byte match token: t=0 selects distance
      // 0x801 + 0 + (0 << 3), so the match repeats the first three bytes.
      const literalCount = 0x801;
      final literals = _pattern(literalCount);
      final extra = literalCount - 31;
      final zeros = (extra - 1) ~/ 255;
      final terminator = extra - zeros * 255;
      final encoded = <int>[
        0,
        for (var i = 0; i < zeros; i++) 0,
        terminator,
        ...literals,
        0x00,
        0x00,
        0xe1,
        0x00,
        0x00,
      ];
      final codec = const Lzo1f();
      final decoded = _decode(codec, encoded, literalCount + 3);
      expect(decoded.sublist(0, literalCount), orderedEquals(literals));
      expect(
        decoded.sublist(literalCount),
        orderedEquals(literals.sublist(0, 3)),
      );
    });

    test('M2 match with folded trailing literals', () {
      // "abcd", then an M2 match of three bytes at distance one (token 0x23
      // folds a three-byte literal run into the low two bits), then "xyz".
      final encoded = <int>[
        4,
        ...'abcd'.codeUnits,
        0x23,
        0x00,
        ...'xyz'.codeUnits,
        0xe1,
        0x00,
        0x00,
      ];
      expect(
        _decode(const Lzo1f(), encoded, 10),
        orderedEquals('abcddddxyz'.codeUnits),
      );
    });

    test('M3 match with a length extension', () {
      // Two literals, then a 40-byte match at distance two.
      final encoded = <int>[
        2,
        ...'ab'.codeUnits,
        0xe0,
        0x07,
        0x08,
        0x00,
        0xe1,
        0x00,
        0x00,
      ];
      final expected = <int>[
        ...'ab'.codeUnits,
        for (var i = 0; i < 20; i++) ...'ab'.codeUnits,
      ];
      expect(_decode(const Lzo1f(), encoded, 42), orderedEquals(expected));
    });

    test('any zero-distance M3 token terminates the stream', () {
      final encoded = <int>[1, ...'Q'.codeUnits, 0xe2, 0x00, 0x00];
      expect(_decode(const Lzo1f(), encoded, 1), orderedEquals([0x51]));
    });

    test('end-of-stream marker decodes to empty output', () {
      expect(
        const Lzo1f().decompressInto(
          Uint8List.fromList([0xe1, 0x00, 0x00]),
          Uint8List(0),
        ),
        0,
      );
    });
  });

  group('compressor output shape', () {
    test('empty input is the bare end-of-stream marker', () {
      for (final level in Lzo1fLevel.values) {
        final codec = Lzo1f(level: level);
        final compressed = Uint8List(codec.compressBound(0));
        final written = codec.compressInto(Uint8List(0), compressed);
        expect(written, 3);
        expect(
          Uint8List.sublistView(compressed, 0, written),
          orderedEquals([0xe1, 0x00, 0x00]),
        );
      }
    });

    test('inputs up to ten bytes are a single literal run', () {
      for (final level in Lzo1fLevel.values) {
        final codec = Lzo1f(level: level);
        for (var length = 1; length <= 10; length++) {
          final source = _pattern(length);
          final compressed = Uint8List(codec.compressBound(length));
          final written = codec.compressInto(source, compressed);
          expect(written, 1 + length + 3, reason: 'length $length');
          expect(compressed[0], length);
          expect(compressed.sublist(1, 1 + length), orderedEquals(source));
          expect(
            compressed.sublist(1 + length, written),
            orderedEquals([0xe1, 0, 0]),
          );
        }
      }
    });

    test('compressBound covers every acceptance case', () {
      for (final level in Lzo1fLevel.values) {
        final codec = Lzo1f(level: level);
        for (final size in _sizes) {
          for (final kind in _kinds) {
            final source = _corpus(size, kind);
            final written = codec.compressInto(
              source,
              Uint8List(codec.compressBound(size)),
            );
            expect(
              written,
              lessThanOrEqualTo(codec.compressBound(size)),
              reason: '$kind $size',
            );
          }
        }
      }
    });

    test('compression ratio is sane on structured data', () {
      // liblzo2's level 999 caps a single match at 2 048 bytes, so it is not
      // always better than the greedy level 1 on highly periodic data. Both
      // still have to compress such data dramatically.
      const fast = Lzo1f();
      const max = Lzo1f(level: Lzo1fLevel.max);
      for (final kind in ['text', 'zeros']) {
        final source = _corpus(65536, kind);
        for (final codec in [fast, max]) {
          final size = codec.compressInto(
            source,
            Uint8List(codec.compressBound(source.length)),
          );
          expect(size, lessThan(65536 ~/ 20), reason: '${codec.level} $kind');
        }
      }

      // The lazy match finder pays off on the interleaved pattern.
      final pattern = _corpus(65536, 'pattern');
      final fastSize = fast.compressInto(
        pattern,
        Uint8List(fast.compressBound(pattern.length)),
      );
      final maxSize = max.compressInto(
        pattern,
        Uint8List(max.compressBound(pattern.length)),
      );
      expect(maxSize, lessThan(fastSize));
    });

    test('overlapping source and destination is handled', () {
      const codec = Lzo1f();
      final source = _corpus(512, 'text');
      final bound = codec.compressBound(source.length);
      final buffer = Uint8List(1024 + bound);
      buffer.setRange(1024, 1024 + source.length, source);
      final written = codec.compressInto(
        Uint8List.sublistView(buffer, 1024, 1024 + source.length),
        Uint8List.sublistView(buffer, 0, bound),
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

    test('a destination buffer that is too small is rejected', () {
      const codec = Lzo1f();
      final source = _corpus(1024, 'random');
      for (final capacity in [0, 1, 16]) {
        expect(
          () => codec.compressInto(source, Uint8List(capacity)),
          _throwsCode(LzoErrorCode.outputOverrun),
          reason: 'capacity $capacity',
        );
      }
    });
  });

  group('malformed input', () {
    test('empty compressed input is rejected', () {
      expect(
        () => const Lzo1f().decompressInto(Uint8List(0), Uint8List(16)),
        _throwsCode(LzoErrorCode.eofNotFound),
      );
    });

    test('output buffer too small is rejected', () {
      final encoded = _text17;
      expect(
        () => const Lzo1f().decompressInto(
          Uint8List.fromList(encoded),
          Uint8List(16),
        ),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('a back-reference before the output start is rejected', () {
      // One literal, then an M2 match whose distance is three.
      final encoded = <int>[1, ...'a'.codeUnits, 0x28, 0x00, 0xe1, 0, 0];
      expect(
        () => const Lzo1f().decompressInto(
          Uint8List.fromList(encoded),
          Uint8List(16),
        ),
        _throwsCode(LzoErrorCode.lookbehindOverrun),
      );
    });

    test('trailing bytes after the end of stream are rejected', () {
      final padded = <int>[..._text17, 0x00];
      expect(
        () => const Lzo1f().decompressInto(
          Uint8List.fromList(padded),
          Uint8List(17),
        ),
        _throwsCode(LzoErrorCode.inputNotConsumed),
      );
    });

    test('every truncation of a reference vector fails with LzoException', () {
      final codec = const Lzo1f(level: Lzo1fLevel.max);
      for (var length = 0; length < _text238Max.length; length++) {
        expect(
          _throwsLzo(
            () => codec.decompressInto(
              Uint8List.fromList(_text238Max.sublist(0, length)),
              Uint8List(238),
            ),
          ),
          isTrue,
          reason: 'truncated to $length bytes',
        );
      }
    });

    test('bit flips never escape as non-Lzo errors', () {
      final codec = const Lzo1f(level: Lzo1fLevel.max);
      final output = Uint8List(238);
      for (var index = 0; index < _text238Max.length; index++) {
        for (final mask in [0x01, 0x80, 0xff]) {
          final mutated = Uint8List.fromList(_text238Max);
          mutated[index] ^= mask;
          try {
            codec.decompressInto(mutated, output);
          } on LzoException {
            // Expected for most mutations.
          }
        }
      }
    });

    test('random blobs never escape as non-Lzo errors', () {
      final codec = const Lzo1f();
      final random = Random(2024);
      for (var trial = 0; trial < 500; trial++) {
        final length = random.nextInt(48);
        final encoded = Uint8List(length);
        for (var i = 0; i < length; i++) {
          encoded[i] = random.nextInt(256);
        }
        try {
          codec.decompressInto(encoded, Uint8List(1024));
        } on LzoException {
          // Expected for almost every random blob.
        }
      }
    });

    test('negative maxOutputLength is rejected', () {
      expect(
        () => const Lzo1f().decompress(Bytes.fromList(const [0xe1, 0, 0]), -1),
        _throwsCode(LzoErrorCode.invalidArgument),
      );
    });
  });

  group('liblzo2 interop', () {
    for (final level in Lzo1fLevel.values) {
      test(
        'level ${level.number} matches liblzo2 in both directions',
        () async {
          if (!_oracleReady) {
            markTestSkipped(
              'liblzo2 oracle unavailable; build tool/oracle or set LZO_ORACLE',
            );
            return;
          }

          final codec = Lzo1f(level: level);
          final directory = _temporary.path;
          final compressJobs = <_CompressJob>[];
          for (final kind in _kinds) {
            for (final size in _sizes) {
              compressJobs.add(
                _CompressJob(
                  '$directory/raw_${kind}_$size.bin',
                  '$directory/ref_${level.number}_${kind}_$size.bin',
                  level.number,
                ),
              );
            }
          }
          await _referenceCompress('lzo1f', compressJobs);

          var checks = 0;
          final decompressJobs = <_DecompressJob>[];
          for (final kind in _kinds) {
            for (final size in _sizes) {
              final reason = 'l${level.number}/$kind/$size';
              final source = _corpus(size, kind);
              final reference = File(
                '$directory/ref_${level.number}_${kind}_$size.bin',
              ).readAsBytesSync();
              expect(
                reference,
                isNotEmpty,
                reason: 'empty reference block for $reason',
              );

              // a) liblzo2 compressor -> our decoder.
              final referenceDecoded = Uint8List(size);
              expect(
                codec.decompressInto(reference, referenceDecoded),
                size,
                reason: 'reference decode length for $reason',
              );
              expect(referenceDecoded, orderedEquals(source), reason: reason);
              checks++;

              // b) our compressor -> liblzo2 decoder, and c) our own decoder.
              final output = Uint8List(codec.compressBound(size));
              final written = codec.compressInto(source, output);
              expect(
                written,
                lessThanOrEqualTo(codec.compressBound(size)),
                reason: 'bound for $reason',
              );
              final compressed = Uint8List.sublistView(output, 0, written);
              File('$directory/mine_${level.number}_${kind}_$size.bin')
                  .writeAsBytesSync(compressed);
              decompressJobs.add(
                _DecompressJob(
                  '$directory/mine_${level.number}_${kind}_$size.bin',
                  '$directory/rt_${level.number}_${kind}_$size.bin',
                  size,
                ),
              );

              final roundTrip = Uint8List(size);
              expect(
                codec.decompressInto(compressed, roundTrip),
                size,
                reason: 'round-trip length for $reason',
              );
              expect(roundTrip, orderedEquals(source), reason: reason);
              checks++;
            }
          }

          await _referenceDecompress('lzo1f', decompressJobs);
          for (final kind in _kinds) {
            for (final size in _sizes) {
              final reason = 'l${level.number}/$kind/$size';
              final restored = File(
                '$directory/rt_${level.number}_${kind}_$size.bin',
              ).readAsBytesSync();
              expect(
                restored.length,
                size,
                reason: 'oracle output for $reason',
              );
              expect(
                restored,
                orderedEquals(_corpus(size, kind)),
                reason: reason,
              );
              checks++;
            }
          }
          expect(checks, _kinds.length * _sizes.length * 3);
          // ignore: avoid_print
          print('Lzo1f level ${level.number}: $checks interop checks passed');
        },
      );
    }
  });
}

// Golden compressed blocks produced by liblzo2 2.10's
// `lzo1f_1_compress` and `lzo1f_999_compress` for the deterministic
// inputs above.

/// Decodes a hex string into bytes for the golden reference vectors.
Uint8List _hexBytes(String hex) {
  final output = Uint8List(hex.length >> 1);
  for (var i = 0; i < output.length; i++) {
    output[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return output;
}

// empty level 1: 0 raw bytes -> 3 compressed bytes
final Uint8List _empty = _hexBytes('e10000');

// empty level 999: 0 raw bytes -> 3 compressed bytes
final Uint8List _emptyMax = _hexBytes('e10000');

// text17 level 1: 17 raw bytes -> 21 compressed bytes
final Uint8List _text17 = _hexBytes(
  '1154686520717569636b2062726f776e2066e10000',
);

// text17 level 999: 17 raw bytes -> 21 compressed bytes
final Uint8List _text17Max = _hexBytes(
  '1154686520717569636b2062726f776e2066e10000',
);

// text238 level 1: 238 raw bytes -> 143 compressed bytes
final Uint8List _text238 = _hexBytes(
  '000f54686520717569636b2062726f776e20666f78206a756d7073206f766572'
  '20746865206c617a7920646f672e2054310551710542710546f0b5004c500500'
  '26446f6721204c5a4f314620697320612072617720626c6f636b20636f646563'
  '2077697468206c69746572616c2072756e7320616e64206261636b2d72656665'
  '72656e636573980de02d7002e10000',
);

// text238 level 999: 238 raw bytes -> 141 compressed bytes
final Uint8List _text238Max = _hexBytes(
  '000154686520717569636b2062726f776e20666f78206a756d7073206f766572'
  '207438030a6c617a7920646f672e20510551710542710546f0b5004c50051744'
  '6f6721204c5a4f314620697320612072617720626c6f3c0616636f6465632077'
  '697468206c69746572616c2072756e2c04126e64206261636b2d726566657265'
  '6e636573980de02d7002e10000',
);

// zeros100 level 1: 100 raw bytes -> 10 compressed bytes
final Uint8List _zeros100 = _hexBytes('020000e0410400e10000');

// zeros100 level 999: 100 raw bytes -> 9 compressed bytes
final Uint8List _zeros100Max = _hexBytes('0100e0420400e10000');

// pattern239 level 1: 239 raw bytes -> 245 compressed bytes
final Uint8List _pattern239 = _hexBytes(
  '001d000701080209030a050a060b070c08000a0007050c02090702030c080405'
  '010a0706000701030a040c09050a06060207040c06040b09030109020b074804'
  '000901080c09000a010b03080709080a090b0b0105060a030708000100060503'
  '020808070b080c04080520090065080704030505000405090a010207000c0504'
  '0a0902020903040b0b05060106080003080a0206090307010b05090405080406'
  '070a06090802030a050c000805070c020204090008020600050c030b04070305'
  '010400030a0105090c03070c04090b04060b00070a01080c0c030a0203090207'
  '050b040a09000408060a010603080a030005e10000',
);

// pattern239 level 999: 239 raw bytes -> 245 compressed bytes
final Uint8List _pattern239Max = _hexBytes(
  '0003000701080209030a050a060b070c08000a0007050c02090702030c080405'
  '010a0706240405030a040c0924040f060207040c06040b09030109020b074804'
  '000901080c09000a010b03080709080a090b0b0105060a030708000100060503'
  '020808070b080c040805200915080704030505000405090a010207000c05040a'
  '09022c0f0001040b0b05060106080003080a0206090307010b05090405080406'
  '070a060908023013000d0c000805070c020204090008020600050c030b040703'
  '05010400030a0105090c03070c04090b04060b00070a24120a0c030a02030902'
  '07050b280c07000408060a0106330b030005e10000',
);

// text1024 level 1: 1024 raw bytes -> 146 compressed bytes
final Uint8List _text1024 = _hexBytes(
  '000f54686520717569636b2062726f776e20666f78206a756d7073206f766572'
  '20746865206c617a7920646f672e2054310551710542710546f0b5004c500500'
  '26446f6721204c5a4f314620697320612072617720626c6f636b20636f646563'
  '2077697468206c69746572616c2072756e7320616e64206261636b2d72656665'
  '72656e636573980de0000000427002e10000',
);

// text1024 level 999: 1024 raw bytes -> 144 compressed bytes
final Uint8List _text1024Max = _hexBytes(
  '000154686520717569636b2062726f776e20666f78206a756d7073206f766572'
  '207438030a6c617a7920646f672e20510551710542710546f0b5004c50051744'
  '6f6721204c5a4f314620697320612072617720626c6f3c0616636f6465632077'
  '697468206c69746572616c2072756e2c04126e64206261636b2d726566657265'
  '6e636573980de0000000427002e10000',
);
