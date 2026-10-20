/// Differential test of this package against the reference liblzo2 codec.
///
/// For every entry in `test/data/manifest.json` it runs three checks:
///
///   a) liblzo2 compress  -> Dart decompress   equals the raw bytes
///   b) Dart compress     -> liblzo2 decompress equals the raw bytes
///   c) Dart compress     -> Dart decompress    equals the raw bytes
///
/// Check (a) also requires the oracle's compressed bytes to be identical to
/// the committed `.lzo` file, which keeps the fixtures reproducible.
///
/// Usage:
///
/// ```sh
/// dart run tool/differential.dart --oracle tool/oracle/lzo_oracle
/// ```
///
/// The oracle path can also come from `LZO_ORACLE`; the manifest defaults to
/// `test/data/manifest.json` and can be overridden with `--manifest`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lzo_neo/lzo.dart';

import 'vectors/sha256.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options.help) {
    _Options.printUsage();
    return;
  }

  final oracle = _resolveOracle(options.oracle);
  final version = _oracleVersion(oracle);
  stdout.writeln('oracle: ${oracle.path} (liblzo2 $version)');
  if (version != '2.10') {
    stdout.writeln(
      'warning: the committed vectors were generated with liblzo2 2.10; '
      'byte-for-byte comparisons may fail with $version.',
    );
  }

  final manifestFile = File(options.manifest);
  if (!manifestFile.existsSync()) {
    _fail(
      'manifest ${manifestFile.path} does not exist; run '
      'tool/vectors/generate.sh or pass --manifest.',
    );
  }
  final manifest = _loadManifest(manifestFile);
  final dataDirectory = manifestFile.parent;
  final cases = _selectCases(manifest.cases, options.cases);
  if (cases.isEmpty) {
    _fail('no manifest cases matched the --case filter.');
  }
  stdout.writeln(
    'manifest: ${manifestFile.path} '
    '(${cases.length} of ${manifest.cases.length} cases)\n',
  );

  final temporary = Directory.systemTemp.createTempSync('lzo_differential_');
  var passedChecks = 0;
  var failedChecks = 0;
  final failedCases = <String>[];
  final printedNotes = <String>{};

  void check(String label, String? problem) {
    if (problem == null) {
      passedChecks++;
    } else {
      failedChecks++;
      failedCases.add('$label: $problem');
    }
  }

  try {
    for (final vector in cases) {
      final name = vector.name;
      final rawPath = '${dataDirectory.path}/${vector.rawFile}';
      final compressedPath = '${dataDirectory.path}/${vector.lzoFile}';

      String? integrityError() {
        final rawFile = File(rawPath);
        final compressedFile = File(compressedPath);
        if (!rawFile.existsSync()) return 'missing $rawPath';
        if (!compressedFile.existsSync()) return 'missing $compressedPath';
        final raw = rawFile.readAsBytesSync();
        final compressed = compressedFile.readAsBytesSync();
        if (raw.length != vector.size) {
          return 'raw file is ${raw.length} bytes, manifest says ${vector.size}';
        }
        final rawDigest = sha256Hex(raw);
        if (rawDigest != vector.sha256) {
          return 'raw sha256 is $rawDigest, manifest says ${vector.sha256}';
        }
        final expectedCompressedSize = vector.compressedSize;
        if (expectedCompressedSize != null &&
            compressed.length != expectedCompressedSize) {
          return 'compressed file is ${compressed.length} bytes, manifest says '
              '$expectedCompressedSize';
        }
        final expectedCompressedDigest = vector.compressedSha256;
        if (expectedCompressedDigest != null) {
          final digest = sha256Hex(compressed);
          if (digest != expectedCompressedDigest) {
            return 'compressed sha256 is $digest, manifest says '
                '$expectedCompressedDigest';
          }
        }
        return null;
      }

      final integrity = integrityError();
      check('manifest integrity', integrity);

      // Skip the byte-level checks if the fixture itself is unreadable: the
      // integrity failure already explains the case.
      if (integrity != null) {
        _reportCase(name, vector.level, vector.size, null, [integrity]);
        continue;
      }

      final raw = File(rawPath).readAsBytesSync();
      final committed = File(compressedPath).readAsBytesSync();
      final dartLevel = _dartLevelFor(vector.level);
      final note = dartLevel.note;
      if (note != null && printedNotes.add(note)) {
        stdout.writeln('note: $note');
      }
      final dartCodec = Lzo1x(level: dartLevel.enumLevel);

      // (a) reference compress -> Dart decompress, and the committed block
      // must be exactly what the oracle produces.
      String? checkReferenceToDart() {
        final oracleBlock = File('${temporary.path}/$name.oracle.lzo');
        try {
          _runOracle(oracle, [
            'compress',
            vector.algorithm,
            '${vector.level}',
            rawPath,
            oracleBlock.path,
          ]);
          final compressed = oracleBlock.readAsBytesSync();
          final compressedDiff = _compareBytes(committed, compressed);
          if (compressedDiff != null) {
            return 'oracle output differs from committed .lzo: $compressedDiff';
          }
          final decoded = Uint8List(raw.length);
          final written = dartCodec.decompressInto(compressed, decoded);
          if (written != raw.length) {
            return 'Dart decompressed $written bytes, expected ${raw.length}';
          }
          final diff = _compareBytes(raw, decoded);
          return diff == null ? null : 'Dart output differs from raw: $diff';
        } on _OracleFailure catch (error) {
          return error.message;
        } on LzoException catch (error) {
          return 'Dart decoder failed: $error';
        }
      }

      // (b) Dart compress -> reference decompress.
      String? checkDartToReference() {
        final dartBlock = File('${temporary.path}/$name.dart.lzo');
        final oracleOutput = File('${temporary.path}/$name.oracle.raw');
        try {
          final compressed = _dartCompress(raw, dartCodec);
          dartBlock.writeAsBytesSync(compressed, flush: true);
          _runOracle(oracle, [
            'decompress',
            vector.algorithm,
            dartBlock.path,
            oracleOutput.path,
            '${raw.length}',
          ]);
          final decoded = oracleOutput.readAsBytesSync();
          final diff = _compareBytes(raw, decoded);
          return diff == null ? null : 'liblzo2 output differs from raw: $diff';
        } on _OracleFailure catch (error) {
          return error.message;
        } on LzoException catch (error) {
          return 'Dart encoder failed: $error';
        }
      }

      // (c) Dart compress -> Dart decompress.
      String? checkDartRoundTrip() {
        try {
          final compressed = _dartCompress(raw, dartCodec);
          final decoded = Uint8List(raw.length);
          final written = dartCodec.decompressInto(compressed, decoded);
          if (written != raw.length) {
            return 'Dart decompressed $written bytes, expected ${raw.length}';
          }
          final diff = _compareBytes(raw, decoded);
          return diff == null ? null : 'Dart output differs from raw: $diff';
        } on LzoException catch (error) {
          return 'Dart codec failed: $error';
        }
      }

      final referenceToDart = checkReferenceToDart();
      check('a) liblzo2 -> Dart', referenceToDart);
      final dartToReference = checkDartToReference();
      check('b) Dart -> liblzo2', dartToReference);
      final dartToDart = checkDartRoundTrip();
      check('c) Dart -> Dart', dartToDart);

      final caseProblems = [
        if (referenceToDart != null) 'a) liblzo2 -> Dart: $referenceToDart',
        if (dartToReference != null) 'b) Dart -> liblzo2: $dartToReference',
        if (dartToDart != null) 'c) Dart -> Dart: $dartToDart',
      ];
      _reportCase(
        name,
        vector.level,
        raw.length,
        committed.length,
        caseProblems,
      );
    }
  } finally {
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temporary directory must not hide the test result.
    }
  }

  stdout
    ..writeln()
    ..writeln(
      '${cases.length} cases, $passedChecks checks passed, '
      '$failedChecks failed.',
    );

  if (failedChecks != 0) {
    stdout.writeln('\nFailures:');
    for (final failure in failedCases) {
      stdout.writeln('  - $failure');
    }
    exit(1);
  }
}

/// Runs the oracle and throws [_OracleFailure] with its diagnostics on failure.
void _runOracle(File oracle, List<String> arguments) {
  final result = Process.runSync(oracle.path, arguments);
  if (result.exitCode != 0) {
    final stderrText = result.stderr.toString().trim();
    throw _OracleFailure(
      'lzo_oracle ${arguments.first} exited ${result.exitCode}'
      '${stderrText.isEmpty ? '' : ': $stderrText'}',
    );
  }
}

/// A failed oracle invocation, reported as a check failure rather than a crash.
final class _OracleFailure implements Exception {
  _OracleFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

Uint8List _dartCompress(Uint8List raw, Lzo1x codec) {
  final bound = Lzo1x.compressBound(raw.length);
  final buffer = Uint8List(bound);
  final written = codec.compressInto(raw, buffer);
  return Uint8List.sublistView(buffer, 0, written);
}

/// Reports one case and returns whether it passed.
void _reportCase(
  String name,
  int level,
  int rawSize,
  int? compressedSize,
  List<String> problems,
) {
  final sizes = compressedSize == null
      ? '${rawSize.toString().padLeft(8)} B'
      : '${rawSize.toString().padLeft(8)} B -> '
            '${compressedSize.toString().padLeft(7)} B';
  if (problems.isEmpty) {
    stdout.writeln(
      'PASS ${name.padRight(16)} level ${level.toString().padLeft(3)}  $sizes',
    );
    return;
  }
  stdout.writeln(
    'FAIL ${name.padRight(16)} level ${level.toString().padLeft(3)}  $sizes',
  );
  for (final problem in problems) {
    stdout.writeln('     $problem');
  }
}

String? _compareBytes(List<int> expected, List<int> actual) {
  if (expected.length == actual.length) {
    var same = true;
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != actual[i]) {
        same = false;
        break;
      }
    }
    if (same) return null;
  }
  return _describeBytes(expected, actual);
}

String _describeBytes(List<int> expected, List<int> actual) {
  final sharedLength = expected.length < actual.length
      ? expected.length
      : actual.length;
  var offset = 0;
  while (offset < sharedLength && expected[offset] == actual[offset]) {
    offset++;
  }

  final start = offset > 8 ? offset - 8 : 0;
  final expectedEnd = offset + 8 < expected.length
      ? offset + 8
      : expected.length;
  final actualEnd = offset + 8 < actual.length ? offset + 8 : actual.length;
  return 'first difference at byte $offset (0x${offset.toRadixString(16)}), '
      'lengths ${expected.length} vs ${actual.length}; '
      'expected [${_hex(expected, start, expectedEnd)}], '
      'actual [${_hex(actual, start, actualEnd)}]';
}

String _hex(List<int> bytes, int start, int end) {
  final builder = StringBuffer();
  for (var i = start; i < end; i++) {
    if (i != start) builder.write(' ');
    builder.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return builder.toString();
}

/// The manifest as read from `test/data/manifest.json`.
final class _Manifest {
  _Manifest(this.cases);

  final List<_Vector> cases;
}

final class _Vector {
  _Vector({
    required this.name,
    required this.algorithm,
    required this.level,
    required this.source,
    required this.size,
    required this.sha256,
    required this.rawFile,
    required this.lzoFile,
    required this.compressedSize,
    required this.compressedSha256,
  });

  final String name;
  final String algorithm;
  final int level;
  final String source;
  final int size;
  final String sha256;
  final String rawFile;
  final String lzoFile;
  final int? compressedSize;
  final String? compressedSha256;
}

_Manifest _loadManifest(File file) {
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    _fail('${file.path} is not valid JSON: ${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    _fail('${file.path} must contain a JSON object.');
  }
  final schema = decoded['schema'];
  if (schema is! int || schema != 1) {
    _fail('${file.path} has unsupported schema $schema (expected 1).');
  }
  final entries = decoded['cases'];
  if (entries is! List) {
    _fail('${file.path} has no "cases" array.');
  }

  final cases = <_Vector>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      _fail('${file.path} contains a non-object case entry.');
    }
    String stringField(String key) {
      final value = entry[key];
      if (value is! String || value.isEmpty) {
        _fail('${file.path}: case ${entry['case']} has no string "$key".');
      }
      return value;
    }

    int intField(String key) {
      final value = entry[key];
      if (value is! int) {
        _fail('${file.path}: case ${entry['case']} has no integer "$key".');
      }
      return value;
    }

    final algorithm = stringField('algorithm');
    if (algorithm != 'lzo1x') {
      _fail('${file.path}: unsupported algorithm "$algorithm".');
    }
    final level = intField('level');
    if (!_dartLevels.containsKey(level) && level != 999) {
      _fail(
        '${file.path}: case ${entry['case']} uses unsupported level $level '
        '(supported: ${_dartLevels.keys.join(', ')}, 999).',
      );
    }

    final name = stringField('case');
    final rawFile = entry['rawFile'] is String
        ? entry['rawFile'] as String
        : '$name.raw';
    final lzoFile = entry['lzoFile'] is String
        ? entry['lzoFile'] as String
        : '$name.lzo';

    cases.add(
      _Vector(
        name: name,
        algorithm: algorithm,
        level: level,
        source: stringField('source'),
        size: intField('size'),
        sha256: stringField('sha256'),
        rawFile: rawFile,
        lzoFile: lzoFile,
        compressedSize: entry['compressedSize'] is int
            ? entry['compressedSize'] as int
            : null,
        compressedSha256: entry['compressedSha256'] is String
            ? entry['compressedSha256'] as String
            : null,
      ),
    );
  }
  return _Manifest(cases);
}

/// Level numbers this package's Dart encoder implements.
final Map<int, Lzo1xLevel> _dartLevels = {
  for (final level in Lzo1xLevel.values) level.number: level,
};

_DartLevel _dartLevelFor(int level) {
  final supported = _dartLevels[level];
  if (supported != null) {
    return _DartLevel(supported, null);
  }
  // `lzo1x_999` is not part of this package's encoder matrix. Its fixtures
  // are still decoded on both sides; the Dart-side compression checks use the
  // closest fast level because the decompressor is level-independent.
  assert(level == 999);
  return _DartLevel(
    Lzo1xLevel.fast15,
    'level 999 fixture: Dart compress side uses level 15 '
    '(the package has no lzo1x_999 encoder)',
  );
}

final class _DartLevel {
  _DartLevel(this.enumLevel, this.note);

  final Lzo1xLevel enumLevel;
  final String? note;
}

File _resolveOracle(String? explicit) {
  final candidates = <String>[
    ?explicit,
    ?Platform.environment['LZO_ORACLE'],
    'tool/oracle/lzo_oracle',
    'tool/oracle/lzo_oracle.exe',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file;
    }
  }
  _fail(
    'no liblzo2 oracle found. Build tool/oracle/lzo_oracle (see '
    'tool/oracle/Makefile) and pass --oracle <path> or set LZO_ORACLE.',
  );
}

String _oracleVersion(File oracle) {
  final ProcessResult result;
  try {
    result = Process.runSync(oracle.path, ['version']);
  } on ProcessException catch (error) {
    _fail('cannot run oracle ${oracle.path}: ${error.message}');
  }
  if (result.exitCode != 0) {
    _fail(
      'oracle ${oracle.path} does not answer "version" '
      '(exit ${result.exitCode}).\n${result.stderr.toString().trim()}',
    );
  }
  final match = RegExp(r'liblzo2\s+([0-9][0-9.]*)')
      .firstMatch(result.stdout.toString());
  if (match == null) {
    _fail(
      'cannot parse the liblzo2 version from the oracle output: '
      '${result.stdout.toString().trim()}',
    );
  }
  return match.group(1)!;
}

Never _fail(String message) {
  stderr.writeln('differential: $message');
  exit(2);
}

final class _Options {
  _Options({
    required this.oracle,
    required this.manifest,
    required this.cases,
    required this.help,
  });

  final String? oracle;
  final String manifest;
  final List<String> cases;
  final bool help;

  static _Options parse(List<String> arguments) {
    String? oracle;
    var manifest = 'test/data/manifest.json';
    final cases = <String>[];
    var help = false;

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      String valueOf(String name) {
        if (argument == '--$name') {
          if (i + 1 >= arguments.length) {
            _fail('--$name requires a value.');
          }
          i++;
          return arguments[i];
        }
        return argument.substring('--$name='.length);
      }

      if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument == '--oracle' || argument.startsWith('--oracle=')) {
        oracle = valueOf('oracle');
      } else if (argument == '--manifest' ||
          argument.startsWith('--manifest=')) {
        manifest = valueOf('manifest');
      } else if (argument == '--case' || argument.startsWith('--case=')) {
        for (final name in valueOf('case').split(',')) {
          if (name.isNotEmpty) {
            cases.add(name);
          }
        }
      } else {
        _fail('unknown argument "$argument". Use --help for usage.');
      }
    }
    return _Options(
      oracle: oracle,
      manifest: manifest,
      cases: cases,
      help: help,
    );
  }

  static void printUsage() {
    stdout.writeln('''
Differential test of the Dart LZO1X implementation against liblzo2.

Options:
  --oracle <path>      lzo_oracle binary (env: LZO_ORACLE)
  --manifest <path>    vector manifest (default: test/data/manifest.json)
  --case <name>        run only the named case(s); comma-separated and
                       repeatable
  -h, --help           show this help

Exit status: 0 all checks passed, 1 checks failed, 2 setup error.

For lzo1x_999 fixtures the Dart -> liblzo2 and Dart -> Dart checks compress
with level 15, because this package has no lzo1x_999 encoder; decompression is
level-independent and check (a) still exercises the 999 stream.''');
  }
}

List<_Vector> _selectCases(List<_Vector> cases, List<String> filters) {
  if (filters.isEmpty) return cases;
  final wanted = filters.toSet();
  final known = cases.map((vector) => vector.name).toSet();
  final unknown = wanted.difference(known);
  if (unknown.isNotEmpty) {
    _fail('unknown case(s): ${unknown.join(', ')}.');
  }
  return [
    for (final vector in cases)
      if (wanted.contains(vector.name)) vector,
  ];
}
