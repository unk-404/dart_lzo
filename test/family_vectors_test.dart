/// Data-driven tests over the committed all-family vectors in
/// `test/data/families/manifest.json`.
///
/// The fixtures are real liblzo2 2.10 output (see
/// `tool/vectors/generate_families.dart`). Each case is decoded through the
/// public codec for its algorithm; the bidirectional interop checks live in
/// `tool/differential_all.dart` and run in the CI differential job.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

import '../tool/vectors/sha256.dart';

const int _maxCommittedBytes = 12 * 1024 * 1024;

void main() {
  final manifestFile = File('test/data/families/manifest.json');
  final manifest = _readManifest(manifestFile);
  final directory = manifestFile.parent;

  test('manifest covers the full algorithm matrix', () {
    expect(manifest.schema, 1);
    expect(manifest.lzoVersion, '2.10');
    expect(manifest.cases, isNotEmpty);
    final algorithms = manifest.cases.map((vector) => vector.algorithm).toSet();
    expect(algorithms, LzoAlgorithm.values.map((value) => value.name).toSet());
  });

  test('every committed file is described by the manifest', () {
    final declared = <String>{
      for (final vector in manifest.cases) ...<String>{
        vector.rawFile,
        vector.lzoFile,
      },
      'manifest.json',
    };
    final present = directory
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    expect(present, declared);
  });

  test('the corpus stays below the committed-size budget', () {
    var bytes = 0;
    for (final vector in manifest.cases) {
      bytes += File('${directory.path}/${vector.rawFile}').lengthSync();
      bytes += File('${directory.path}/${vector.lzoFile}').lengthSync();
    }
    expect(bytes, lessThan(_maxCommittedBytes));
  });

  group('committed all-family vectors', () {
    for (final vector in manifest.cases) {
      test('${vector.algorithm} ${vector.level} ${vector.source}', () {
        final rawFile = File('${directory.path}/${vector.rawFile}');
        final lzoFile = File('${directory.path}/${vector.lzoFile}');
        expect(rawFile.existsSync(), isTrue);
        expect(lzoFile.existsSync(), isTrue);

        final raw = rawFile.readAsBytesSync();
        final compressed = lzoFile.readAsBytesSync();
        expect(raw.length, vector.size);
        expect(sha256Hex(raw), vector.sha256);
        expect(compressed.length, vector.compressedSize);
        expect(sha256Hex(compressed), vector.compressedSha256);

        final codec = lzoCodec(
          LzoAlgorithm.values.byName(vector.algorithm),
          level: vector.level,
        );
        final output = Uint8List(raw.length);
        final written = codec.decompressInto(compressed, output);
        expect(written, raw.length);
        expect(output, orderedEquals(raw));
      });
    }
  });
}

_Manifest _readManifest(File file) {
  if (!file.existsSync()) {
    throw StateError(
      '${file.path} is missing; run tool/vectors/generate_families.sh',
    );
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('${file.path} must contain a JSON object');
  }
  final schema = decoded['schema'];
  final lzoVersion = decoded['lzoVersion'];
  final entries = decoded['cases'];
  if (schema is! int || lzoVersion is! String || entries is! List) {
    throw StateError('${file.path} has an unexpected schema');
  }
  final cases = <_Vector>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      throw StateError('${file.path} contains a non-object case');
    }
    String stringField(String key) {
      final value = entry[key];
      if (value is! String) {
        throw StateError('${file.path}: missing string "$key"');
      }
      return value;
    }

    int intField(String key) {
      final value = entry[key];
      if (value is! int) {
        throw StateError('${file.path}: missing integer "$key"');
      }
      return value;
    }

    cases.add(
      _Vector(
        caseName: stringField('case'),
        algorithm: stringField('algorithm'),
        level: intField('level'),
        source: stringField('source'),
        size: intField('size'),
        sha256: stringField('sha256'),
        rawFile: stringField('rawFile'),
        lzoFile: stringField('lzoFile'),
        compressedSize: intField('compressedSize'),
        compressedSha256: stringField('compressedSha256'),
      ),
    );
  }
  return _Manifest(schema: schema, lzoVersion: lzoVersion, cases: cases);
}

final class _Manifest {
  _Manifest({
    required this.schema,
    required this.lzoVersion,
    required this.cases,
  });

  final int schema;
  final String lzoVersion;
  final List<_Vector> cases;
}

final class _Vector {
  _Vector({
    required this.caseName,
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

  final String caseName;
  final String algorithm;
  final int level;
  final String source;
  final int size;
  final String sha256;
  final String rawFile;
  final String lzoFile;
  final int compressedSize;
  final String compressedSha256;
}
