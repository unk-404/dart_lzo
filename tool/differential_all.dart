/// Full-matrix differential test against liblzo2 2.10.
///
/// For every committed all-family vector this checks four things:
///   1. the oracle reproduces the committed `.lzo` byte-for-byte;
///   2. the Dart codec decodes the committed block back to the original;
///   3. a Dart-compressed block is accepted by the reference decompressor;
///   4. the Dart round-trip is byte-exact.
///
/// It also exercises the preset-dictionary commands for LZO1X/LZO1Y/LZO1Z.
///
/// Run from the repository root (see `tool/oracle/Makefile`):
///
/// ```sh
/// dart run tool/differential_all.dart --oracle tool/oracle/lzo_oracle
/// dart run tool/differential_all.dart --oracle /tmp/lzo_oracle --via-wsl
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  final manifest = _readManifest(File('${options.data}/manifest.json'));
  final temporary = Directory.systemTemp.createTempSync('lzo_diff_all_');
  var checks = 0;
  final failures = <String>[];

  try {
    final byFamily = <String, List<int>>{};
    for (final vector in manifest.cases) {
      final family = vector.algorithm;
      final counts = byFamily.putIfAbsent(family, () => <int>[0, 0]);
      try {
        _checkVector(vector, options, temporary);
        counts[0]++;
        checks += 4;
      } on Object catch (error) {
        counts[1]++;
        failures.add(
          '${vector.algorithm} ${vector.level} ${vector.source}: $error',
        );
      }
    }

    for (final (algorithm, dictionary, source) in _dictionaryCorpora()) {
      try {
        _checkDictionary(algorithm, dictionary, source, options, temporary);
        checks += 4;
      } on Object catch (error) {
        failures.add('dictionary $algorithm: $error');
      }
    }

    for (final entry in byFamily.entries) {
      final counts = entry.value;
      print('${entry.key.padRight(7)} ${counts[0]} ok, ${counts[1]} failed');
    }
  } finally {
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('${failures.length} failure(s):');
    for (final failure in failures.take(50)) {
      stderr.writeln('  $failure');
    }
    exitCode = 1;
  } else {
    print('differential_all: $checks checks passed');
  }
}

void _checkVector(_Vector vector, _Options options, Directory temporary) {
  final rawPath = '${options.data}/${vector.rawFile}';
  final committedPath = '${options.data}/${vector.lzoFile}';
  final raw = File(rawPath).readAsBytesSync();
  final committed = File(committedPath).readAsBytesSync();

  // 1. The committed block must be exactly what liblzo2 produces.
  final regenerated = '${temporary.path}/regenerated.lzo';
  _runOracle(options, <String>[
    'compress',
    vector.algorithm,
    '${vector.level}',
    rawPath,
    regenerated,
  ]);
  final reference = File(regenerated).readAsBytesSync();
  _expectEqual(reference, committed, 'oracle reproduction');

  // 2. Dart decodes the reference block.
  final codec = lzoCodec(
    LzoAlgorithm.values.byName(vector.algorithm),
    level: vector.level,
  );
  final decoded = Uint8List(raw.length);
  final decodedLength = codec.decompressInto(committed, decoded);
  if (decodedLength != raw.length) {
    throw StateError('decoded $decodedLength, expected ${raw.length}');
  }
  _expectEqual(decoded, raw, 'Dart decode');

  // 3. liblzo2 decodes a Dart-compressed block.
  final compressed = Uint8List(2 * raw.length + 4096);
  final compressedLength = codec.compressInto(raw, compressed);
  final dartBlock = '${temporary.path}/dart.lzo';
  File(dartBlock)
      .writeAsBytesSync(Uint8List.sublistView(compressed, 0, compressedLength));
  final restored = '${temporary.path}/restored.raw';
  _runOracle(options, <String>[
    'decompress',
    vector.algorithm,
    dartBlock,
    restored,
    '${raw.length}',
  ]);
  _expectEqual(File(restored).readAsBytesSync(), raw, 'liblzo2 decode');

  // 4. Dart round-trip.
  final roundTrip = Uint8List(raw.length);
  final again = codec.decompressInto(
    Uint8List.sublistView(compressed, 0, compressedLength),
    roundTrip,
  );
  if (again != raw.length) {
    throw StateError('round-trip decoded $again, expected ${raw.length}');
  }
  _expectEqual(roundTrip, raw, 'Dart round-trip');
}

void _checkDictionary(
  String algorithm,
  Uint8List dictionary,
  Uint8List source,
  _Options options,
  Directory temporary,
) {
  final dictionaryPath = '${temporary.path}/dictionary.bin';
  final sourcePath = '${temporary.path}/source.bin';
  File(dictionaryPath).writeAsBytesSync(dictionary);
  File(sourcePath).writeAsBytesSync(source);

  final codec = lzoCodec(
    LzoAlgorithm.values.byName(algorithm),
    level: 999,
    dictionary: dictionary,
  );

  // liblzo2 compresses with the dictionary, Dart decodes.
  final referenceBlock = '${temporary.path}/dict.lzo';
  _runOracle(options, <String>[
    'compress-dict',
    algorithm,
    dictionaryPath,
    sourcePath,
    referenceBlock,
  ]);
  final reference = File(referenceBlock).readAsBytesSync();
  final decoded = Uint8List(source.length);
  final decodedLength = codec.decompressInto(reference, decoded);
  if (decodedLength != source.length) {
    throw StateError('dictionary decode wrote $decodedLength');
  }
  _expectEqual(decoded, source, 'dictionary Dart decode');

  // Dart compresses with the dictionary, liblzo2 decodes.
  final compressed = Uint8List(2 * source.length + 4096);
  final compressedLength = codec.compressInto(source, compressed);
  final dartBlock = '${temporary.path}/dart_dict.lzo';
  File(dartBlock)
      .writeAsBytesSync(Uint8List.sublistView(compressed, 0, compressedLength));
  final restored = '${temporary.path}/dict_restored.raw';
  _runOracle(options, <String>[
    'decompress-dict',
    algorithm,
    dictionaryPath,
    dartBlock,
    restored,
    '${source.length}',
  ]);
  _expectEqual(File(restored).readAsBytesSync(), source, 'dictionary oracle');
}

List<(String, Uint8List, Uint8List)> _dictionaryCorpora() {
  final text = File('README.md').readAsBytesSync();
  final dictionary = Uint8List(8192);
  for (var i = 0; i < dictionary.length; i++) {
    dictionary[i] = text[i % text.length];
  }
  final source = Uint8List(4096);
  for (var i = 0; i < source.length; i++) {
    source[i] = text[(i + 1000) % text.length];
  }
  return <(String, Uint8List, Uint8List)>[
    ('lzo1x', dictionary, source),
    ('lzo1y', dictionary, source),
    ('lzo1z', dictionary, source),
  ];
}

void _runOracle(_Options options, List<String> arguments) {
  final command = options.viaWsl
      ? Process.runSync('wsl', <String>[
          options.oracle,
          ...arguments.map(_wslPath),
        ])
      : Process.runSync(options.oracle, arguments);
  if (command.exitCode != 0) {
    throw StateError('oracle ${arguments.first} failed: ${command.stderr}');
  }
}

String _wslPath(String argument) {
  final match = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(argument);
  if (match == null) return argument;
  final rest = match.group(2)!.replaceAll('\\', '/');
  return '/mnt/${match.group(1)!.toLowerCase()}/$rest';
}

void _expectEqual(List<int> actual, List<int> expected, String what) {
  if (actual.length != expected.length) {
    throw StateError(
      '$what length ${actual.length}, expected ${expected.length}',
    );
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) {
      throw StateError('$what differs at byte $i');
    }
  }
}

_Manifest _readManifest(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('${file.path} is not a JSON object');
  }
  final entries = decoded['cases'];
  if (entries is! List) throw StateError('${file.path} has no cases');
  final cases = <_Vector>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    cases.add(
      _Vector(
        algorithm: entry['algorithm'] as String,
        level: entry['level'] as int,
        source: entry['source'] as String,
        rawFile: entry['rawFile'] as String,
        lzoFile: entry['lzoFile'] as String,
      ),
    );
  }
  return _Manifest(cases);
}

final class _Manifest {
  _Manifest(this.cases);

  final List<_Vector> cases;
}

final class _Vector {
  _Vector({
    required this.algorithm,
    required this.level,
    required this.source,
    required this.rawFile,
    required this.lzoFile,
  });

  final String algorithm;
  final int level;
  final String source;
  final String rawFile;
  final String lzoFile;
}

final class _Options {
  _Options(this.oracle, this.data, this.viaWsl);

  final String oracle;
  final String data;
  final bool viaWsl;

  static _Options parse(List<String> arguments) {
    var oracle = Platform.environment['LZO_ORACLE'] ?? '';
    var data = 'test/data/families';
    var viaWsl = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--oracle':
          oracle = arguments[++i];
        case '--data':
          data = arguments[++i];
        case '--via-wsl':
          viaWsl = true;
        default:
          throw ArgumentError('unknown argument: ${arguments[i]}');
      }
    }
    if (oracle.isEmpty) throw ArgumentError('pass --oracle or set LZO_ORACLE');
    return _Options(oracle, data, viaWsl);
  }
}
