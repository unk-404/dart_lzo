/// Tests for the LZO1C codec.
///
/// Besides pure Dart round-trip and robustness checks, the `liblzo2 interop`
/// group compresses and decompresses every level against the reference C
/// implementation. It uses an oracle binary built from `tool/oracle`; when the
/// oracle cannot be built (no WSL/compiler/reference sources) that group is
/// skipped instead of failing.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

// LZO1C is not exported by the public barrel yet, so import the implementation
// library through its package URI (this keeps the `LzoException` type identical
// to the one exported by `package:lzo_neo/lzo_neo.dart`).

const List<int> _sizes = <int>[
  0,
  1,
  2,
  3,
  17,
  18,
  238,
  239,
  1024,
  65536,
  262144,
];
const List<String> _kinds = <String>['text', 'random', 'zeros', 'pattern'];

const String _text =
    'The quick brown fox jumps over the lazy dog. LZO is a lossless block '
    'compression algorithm optimised for decompression speed. It uses short '
    'back-references and literal runs, and it is used by lzop, the Linux '
    'kernel, btrfs and SquashFS. ';
const String _patternUnit = 'LZO1C-pattern-0123456789-abcdefgh-';

/// Deterministic sample data for every `(kind, size)` pair in the matrix.
Uint8List _data(String kind, int size) {
  switch (kind) {
    case 'text':
      return Uint8List.fromList(
        List<int>.generate(size, (i) => _text.codeUnitAt(i % _text.length)),
      );
    case 'random':
      final random = Random(size * 31 + 7);
      return Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(256)),
      );
    case 'zeros':
      return Uint8List(size);
    case 'pattern':
      return Uint8List.fromList(
        List<int>.generate(
          size,
          (i) => _patternUnit.codeUnitAt((i + (i >> 4)) % _patternUnit.length),
        ),
      );
    default:
      throw ArgumentError.value(kind, 'kind');
  }
}

String _caseName(String kind, int size, Object level) => 'l$level/$kind/$size';

// ---------------------------------------------------------------------------
// liblzo2 oracle plumbing
// ---------------------------------------------------------------------------

final Directory _scratch = Directory.systemTemp.createTempSync('lzo_neo_1c_');
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
  return '/mnt/${match.group(1)!.toLowerCase()}/${match.group(2)!.replaceAll('\\', '/')}';
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

String get _referenceRoot => Platform.environment['LZO_SOURCE'] ?? '';
String? _wslOracleSource;
String? _wslOracleLibrary;

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

  final library = File('$_referenceRoot/src/.libs/liblzo2.a');
  final oracleSource = File('tool/oracle/lzo_oracle.c');
  if (!library.existsSync() || !oracleSource.existsSync()) return false;
  _wslOracleSource = oracleSource.path;
  _wslOracleLibrary = library.path;

  if (!Platform.isWindows) {
    _scratch.createSync(recursive: true);
    final binary = '${_scratch.path}/oracle_native';
    final build = Process.runSync('gcc', <String>[
      '-O2',
      '-I$_referenceRoot/include',
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

  return _buildWslOracle();
}

/// Builds the oracle inside the WSL native filesystem.
///
/// Executing a binary that lives on the Windows drive occasionally fails with
/// "Text file busy" while the drive is being scanned, so the oracle is built
/// under `/tmp`. If the WSL instance restarts and loses it, callers rebuild it
/// once and retry.
Future<bool> _buildWslOracle() async {
  final source = _wslOracleSource;
  final library = _wslOracleLibrary;
  if (source == null || library == null) return false;
  final binary =
      '/tmp/lzo_oracle_${DateTime.now().microsecondsSinceEpoch}_'
      '${Random().nextInt(1 << 20)}';
  final script = StringBuffer()
    ..writeln('set -e')
    ..writeln('cd "${_wslPath(Directory.current.path)}"')
    ..writeln(
      'gcc -O2 -I"$_referenceRoot/include" -o "$binary" '
      '"${_wslPath(source)}" "${_wslPath(library)}"',
    )
    ..writeln('"$binary" version > /dev/null');
  try {
    await _runBash(script.toString());
  } on Object {
    return false;
  }
  _oracleIsNative = false;
  _oracleCommand = binary;
  return true;
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
  Future<void> run() async {
    final script = StringBuffer('set -e\n');
    for (final job in jobs) {
      script.writeln(
        '"$_oracleCommand" compress $algorithm ${job.level} '
        '"${_wslPath(job.inputPath)}" "${_wslPath(job.outputPath)}"',
      );
    }
    await _runBash(script.toString());
  }

  try {
    await run();
  } on StateError {
    if (_oracleIsNative) rethrow;
    if (!await _buildWslOracle()) rethrow;
    await run();
  }
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
  Future<void> run() async {
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

  try {
    await run();
  } on StateError {
    if (_oracleIsNative) rethrow;
    if (!await _buildWslOracle()) rethrow;
    await run();
  }
}

// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    _temporary = Directory.systemTemp.createTempSync('lzo1c_test_');
    for (final kind in _kinds) {
      for (final size in _sizes) {
        File('${_temporary.path}/raw_${kind}_$size.bin')
            .writeAsBytesSync(_data(kind, size));
      }
    }
    _oracleReady = await _prepareOracle();
  });

  tearDownAll(() {
    if (_temporary.existsSync()) _temporary.deleteSync(recursive: true);
  });

  group('levels', () {
    test('cover the liblzo2 level numbers', () {
      expect(
        Lzo1cLevel.values.map((level) => level.number),
        orderedEquals(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 99, 999]),
      );
      for (final level in Lzo1cLevel.values) {
        expect(level.dictionaryBits, anyOf(14, 16));
        expect(level.dictionarySize, 1 << level.dictionaryBits);
        expect(level.memCompress, level.dictionarySize * 4);
        expect(level.searchDepth, greaterThan(0));
      }
    });

    test('the default level is l9', () {
      const codec = Lzo1c();
      expect(codec.level, Lzo1cLevel.l9);
      expect(Lzo1c(level: Lzo1cLevel.l1).level, Lzo1cLevel.l1);
    });
  });

  group('round-trip', () {
    for (final level in Lzo1cLevel.values) {
      test('level ${level.number}', () {
        final codec = Lzo1c(level: level);
        for (final kind in _kinds) {
          for (final size in _sizes) {
            final source = _data(kind, size);
            final bound = codec.compressBound(size);
            final output = Uint8List(bound);
            final written = codec.compressInto(source, output);
            expect(
              written,
              inInclusiveRange(3, bound),
              reason: _caseName(kind, size, level.number),
            );

            final decoded = Uint8List(size);
            final restored = codec.decompressInto(
              Uint8List.sublistView(output, 0, written),
              decoded,
            );
            expect(restored, size, reason: _caseName(kind, size, level.number));
            expect(
              decoded,
              orderedEquals(source),
              reason: _caseName(kind, size, level.number),
            );
          }
        }
      });
    }
  });

  group('Bytes API', () {
    test('compresses and decompresses through Bytes', () {
      final codec = Lzo1c();
      final source = _data('text', 1024);
      final packed = codec.compress(Bytes.fromUint8List(source));
      expect(packed.length, lessThan(source.length));

      final unpacked = codec.decompress(packed, source.length);
      expect(unpacked.length, source.length);
      expect(unpacked.asUint8List(), orderedEquals(source));
    });

    test('empty input yields only the end-of-stream marker', () {
      final codec = Lzo1c();
      final output = Uint8List(codec.compressBound(0));
      final written = codec.compressInto(Uint8List(0), output);
      expect(written, 3);
      expect(output.sublist(0, written), orderedEquals(<int>[0x21, 0, 0]));

      final empty = codec.decompress(
        Bytes.fromUint8List(Uint8List.sublistView(output, 0, written)),
        0,
      );
      expect(empty.length, 0);
    });
  });

  group('buffer handling', () {
    test('oversized destination is fine and compressed size is bounded', () {
      final codec = Lzo1c();
      final source = _data('pattern', 65536);
      final output = Uint8List(codec.compressBound(source.length) + 64);
      final written = codec.compressInto(source, output);
      expect(written, lessThanOrEqualTo(codec.compressBound(source.length)));
    });

    test('a too small compression destination throws outputOverrun', () {
      final codec = Lzo1c();
      final source = _data('text', 1024);
      for (final capacity in <int>[0, 1, 2, 4]) {
        expect(
          () => codec.compressInto(source, Uint8List(capacity)),
          throwsA(
            isA<LzoException>().having(
              (error) => error.code,
              'code',
              LzoErrorCode.outputOverrun,
            ),
          ),
          reason: 'capacity $capacity',
        );
      }
    });

    test('a too small decompression destination throws outputOverrun', () {
      final codec = Lzo1c();
      final source = _data('zeros', 1024);
      final output = Uint8List(codec.compressBound(source.length));
      final written = codec.compressInto(source, output);
      final compressed = Uint8List.sublistView(output, 0, written);

      expect(
        () => codec.decompressInto(compressed, Uint8List(source.length - 1)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.outputOverrun,
          ),
        ),
      );

      final exact = Uint8List(source.length);
      expect(codec.decompressInto(compressed, exact), source.length);
      expect(exact, orderedEquals(source));
    });

    test('overlapping source and destination is handled', () {
      final codec = Lzo1c();
      final buffer = Uint8List(8192);
      final source = _data('text', 512);
      buffer.setRange(1024, 1024 + source.length, source);

      final written = codec.compressInto(
        Uint8List.sublistView(buffer, 1024, 1024 + source.length),
        Uint8List.sublistView(buffer, 0, 8192),
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

  group('format details', () {
    test('decodes a hand-crafted stream with R1, M3 and a literal run', () {
      // literal run "abcdef", an R1 opcode (length-3 match at distance 1 plus
      // the literal 'X'), an M3 match at distance 8, then end of stream.
      final compressed = Uint8List.fromList(<int>[
        6, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, // "abcdef"
        0, 0, 0x58, // R1: distance 1, literal 'X'
        0x21, 8, 0, // M3: length 4, distance 8
        0x21, 0, 0, // end of stream
      ]);
      final decoded = Uint8List(64);
      final written = Lzo1c().decompressInto(compressed, decoded);
      expect(written, 14);
      expect(
        String.fromCharCodes(decoded.sublist(0, written)),
        'abcdeffffXcdef',
      );
    });

    test('decodes literals folded into an M3 offset byte', () {
      // LZO1C packs up to three post-match literals into the two spare bits of
      // the low offset byte. Here the M3 match is followed by "XY".
      final compressed = Uint8List.fromList(<int>[
        8, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, // "abcdefgh"
        0x21, 8 | (2 << 6), 0, // M3: length 4, distance 8, 2 literals
        0x58, 0x59, // "XY"
        0x21, 0, 0, // end of stream
      ]);
      final decoded = Uint8List(64);
      final written = Lzo1c().decompressInto(compressed, decoded);
      expect(written, 14);
      expect(
        String.fromCharCodes(decoded.sublist(0, written)),
        'abcdefghabcdXY',
      );
    });

    test('decodes folded literals followed by another match', () {
      // literal run "abcdefgh", M3 match (distance 8) with one folded literal
      // 'X', then an M2 match (length 3, distance 9), then end of stream.
      final compressed = Uint8List.fromList(<int>[
        8, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, // "abcdefgh"
        0x21, 8 | (1 << 6), 0, // M3: length 4, distance 8, 1 literal
        0x58, // 'X'
        72, 0, // M2: length 3, distance 9
        0x21, 0, 0, // end of stream
      ]);
      final decoded = Uint8List(64);
      final written = Lzo1c().decompressInto(compressed, decoded);
      expect(written, 16);
      expect(
        String.fromCharCodes(decoded.sublist(0, written)),
        'abcdefghabcdXefg',
      );
    });

    test('decodes a long R0 literal run', () {
      final source = _data('random', 4096);
      final compressed = BytesBuilder()
        ..add(<int>[0, 252]) // R0 run of 4096 bytes
        ..add(source)
        ..add(<int>[0x21, 0, 0]);
      final bytes = compressed.toBytes();
      final decoded = Uint8List(4096);
      final written = Lzo1c().decompressInto(bytes, decoded);
      expect(written, 4096);
      expect(decoded, orderedEquals(source));
    });
  });

  group('malformed input', () {
    test('truncated blocks throw only LzoException', () {
      final codec = Lzo1c();
      for (final kind in <String>['zeros', 'text']) {
        final source = _data(kind, 1024);
        final output = Uint8List(codec.compressBound(source.length));
        final written = codec.compressInto(source, output);
        final compressed = Uint8List.sublistView(output, 0, written);
        for (var cut = 0; cut < written; cut++) {
          expect(
            () => codec.decompressInto(
              Uint8List.sublistView(compressed, 0, cut),
              Uint8List(1024),
            ),
            throwsA(isA<LzoException>()),
            reason: '$kind truncated at $cut of $written',
          );
        }
      }
    });

    test('random garbage throws only LzoException', () {
      final random = Random(2024);
      for (final length in <int>[0, 1, 2, 3, 4, 7, 16, 64, 257]) {
        final garbage = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        try {
          Lzo1c().decompressInto(garbage, Uint8List(300));
        } on LzoException {
          // Expected for most malformed inputs.
        }
      }
    });

    test('trailing bytes after the end marker are rejected', () {
      final codec = Lzo1c();
      final source = _data('text', 32);
      final output = Uint8List(codec.compressBound(source.length));
      final written = codec.compressInto(source, output);
      final compressed = Uint8List(written + 1)
        ..setRange(0, written, output)
        ..[written] = 0x42;
      expect(
        () => codec.decompressInto(compressed, Uint8List(source.length)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.inputNotConsumed,
          ),
        ),
      );
    });
  });

  group('liblzo2 interop', () {
    for (final level in Lzo1cLevel.values) {
      test(
        'level ${level.number} matches liblzo2 in both directions',
        () async {
          if (!_oracleReady) {
            markTestSkipped(
              'liblzo2 oracle unavailable; build tool/oracle or set LZO_ORACLE',
            );
            return;
          }

          final codec = Lzo1c(level: level);
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
          await _referenceCompress('lzo1c', compressJobs);

          var checks = 0;
          final decompressJobs = <_DecompressJob>[];
          for (final kind in _kinds) {
            for (final size in _sizes) {
              final reason = _caseName(kind, size, level.number);
              final source = _data(kind, size);
              final reference = File(
                '$directory/ref_${level.number}_${kind}_$size.bin',
              ).readAsBytesSync();
              expect(
                reference,
                isNotEmpty,
                reason: 'empty reference block for $reason',
              );

              // a) liblzo2 compress -> our decoder.
              final referenceDecoded = Uint8List(size);
              expect(
                codec.decompressInto(reference, referenceDecoded),
                size,
                reason: 'reference decode length for $reason',
              );
              expect(referenceDecoded, orderedEquals(source), reason: reason);
              checks++;

              // b) our compressor -> liblzo2 decoder (and c) our own decoder).
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

          await _referenceDecompress('lzo1c', decompressJobs);
          for (final kind in _kinds) {
            for (final size in _sizes) {
              final reason = _caseName(kind, size, level.number);
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
                orderedEquals(_data(kind, size)),
                reason: reason,
              );
              checks++;
            }
          }
          expect(checks, _kinds.length * _sizes.length * 3);
          // ignore: avoid_print
          print('Lzo1c level ${level.number}: $checks interop checks passed');
        },
      );
    }
  });
}
