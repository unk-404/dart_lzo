/// Data-driven tests over the committed vectors listed in
/// `test/data/manifest.json`.
///
/// Every fixture is real liblzo2 output; these tests prove that the decoder
/// accepts all of it on a plain `dart test` run (including Windows), without
/// any native library. The liblzo2 interop checks live in `tool/differential.dart`
/// and run in the CI `differential` job.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

import '../tool/vectors/sha256.dart';

const int _maxCommittedBytes = 6 * 1024 * 1024;
const Set<int> _supportedLevels = {1, 11, 12, 15, 999};

void main() {
  final manifestFile = File('test/data/manifest.json');
  final manifest = _readManifest(manifestFile);
  final cases = manifest.cases;
  final dataDirectory = manifestFile.parent;

  group('vector manifest', () {
    test('has the expected schema and metadata', () {
      expect(manifest.schema, 1);
      expect(manifest.algorithm, 'lzo1x');
      expect(manifest.lzoVersion, '2.10');
      expect(cases, isNotEmpty);
    });

    test('names are unique and files follow the <case>.<ext> convention', () {
      final names = <String>{};
      for (final vector in cases) {
        expect(
          names.add(vector.name),
          isTrue,
          reason: 'duplicate case "${vector.name}"',
        );
        expect(vector.rawFile, '${vector.name}.raw');
        expect(vector.lzoFile, '${vector.name}.lzo');
        expect(vector.algorithm, 'lzo1x');
        expect(
          _supportedLevels,
          contains(vector.level),
          reason: 'unsupported level for "${vector.name}"',
        );
        expect(
          vector.sha256,
          matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: 'raw sha256 for "${vector.name}"',
        );
      }
    });

    test('every committed .raw/.lzo file is described by the manifest', () {
      final declaredRaw = cases.map((vector) => vector.rawFile).toSet();
      final declaredLzo = cases.map((vector) => vector.lzoFile).toSet();
      final present = dataDirectory
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList();

      final presentRaw = present.where((name) => name.endsWith('.raw')).toSet();
      final presentLzo = present.where((name) => name.endsWith('.lzo')).toSet();

      expect(presentRaw, declaredRaw);
      expect(presentLzo, declaredLzo);
    });

    test('the corpus stays below the 6 MiB committed-size budget', () {
      var committedBytes = 0;
      for (final vector in cases) {
        committedBytes += File('${dataDirectory.path}/${vector.rawFile}')
            .lengthSync();
        committedBytes += File('${dataDirectory.path}/${vector.lzoFile}')
            .lengthSync();
      }
      expect(
        committedBytes,
        lessThan(_maxCommittedBytes),
        reason: 'raw + compressed bytes for every committed vector',
      );
    });

    test('the boundary and size tiers are all present', () {
      final names = cases.map((vector) => vector.name).toSet();
      expect(names, containsAll(<String>['empty', 'one_byte']));
      for (final size in const [16, 17, 18, 19, 237, 238, 239, 240]) {
        expect(names, contains('boundary_$size'));
      }
      expect(names, contains('text_1k'));
      expect(names, contains('text_64k'));
      expect(names, contains('random_64k'));
      expect(names, contains('random_256k'));
      expect(names, contains('text_1m'));

      final byName = {for (final vector in cases) vector.name: vector};
      expect(byName['text_1k']!.size, 1024);
      expect(byName['text_64k']!.size, 64 * 1024);
      expect(byName['random_256k']!.size, 256 * 1024);
      expect(byName['text_1m']!.size, 1024 * 1024);
      expect(byName['empty']!.size, 0);
      expect(byName['one_byte']!.size, 1);
    });

    test('.gitattributes keeps test/data byte-exact', () {
      // Git EOL conversion corrupted imported fixtures once. The vectors are
      // binary: the attribute that protects them must stay in place.
      final attributes = File('.gitattributes').readAsStringSync();
      expect(attributes, contains('test/data/** binary'));
      expect(attributes, contains('*.raw binary'));
      expect(attributes, contains('*.lzo binary'));
    });
  });

  group('committed vectors', () {
    for (final vector in cases) {
      test(vector.name, () {
        final rawFile = File('${dataDirectory.path}/${vector.rawFile}');
        final lzoFile = File('${dataDirectory.path}/${vector.lzoFile}');
        expect(rawFile.existsSync(), isTrue, reason: vector.rawFile);
        expect(lzoFile.existsSync(), isTrue, reason: vector.lzoFile);

        final original = rawFile.readAsBytesSync();
        final compressed = lzoFile.readAsBytesSync();

        expect(
          original.length,
          vector.size,
          reason: 'manifest size for "${vector.name}"',
        );
        expect(
          sha256Hex(original),
          vector.sha256,
          reason: 'raw sha256 for "${vector.name}"',
        );
        expect(
          compressed,
          isNotEmpty,
          reason: 'compressed block for "${vector.name}"',
        );
        final compressedSize = vector.compressedSize;
        if (compressedSize != null) {
          expect(
            compressed.length,
            compressedSize,
            reason: 'manifest compressedSize for "${vector.name}"',
          );
        }
        final compressedSha256 = vector.compressedSha256;
        if (compressedSha256 != null) {
          expect(
            sha256Hex(compressed),
            compressedSha256,
            reason: 'compressed sha256 for "${vector.name}"',
          );
        }

        // The decoder does not need the level: it is encoded in the stream.
        final codec = Lzo1x();
        final output = Uint8List(original.length);
        final written = codec.decompressInto(compressed, output);

        expect(written, original.length);
        expect(output, orderedEquals(original));
      });
    }
  });
}

_Manifest _readManifest(File file) {
  if (!file.existsSync()) {
    throw StateError(
      '${file.path} is missing; run tool/vectors/generate.sh to regenerate '
      'the committed vectors.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw StateError('${file.path} is not valid JSON: ${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw StateError('${file.path} must contain a JSON object.');
  }
  final schema = decoded['schema'];
  final algorithm = decoded['algorithm'];
  final lzoVersion = decoded['lzoVersion'];
  final entries = decoded['cases'];
  if (schema is! int) {
    throw StateError('${file.path} has no integer "schema".');
  }
  if (algorithm is! String) {
    throw StateError('${file.path} has no string "algorithm".');
  }
  if (lzoVersion is! String) {
    throw StateError('${file.path} has no string "lzoVersion".');
  }
  if (entries is! List) {
    throw StateError('${file.path} has no "cases" array.');
  }

  final cases = <_Vector>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      throw StateError('${file.path} contains a non-object case entry.');
    }
    String stringField(String key) {
      final value = entry[key];
      if (value is! String || value.isEmpty) {
        throw StateError(
          '${file.path}: case ${entry['case']} has no string "$key".',
        );
      }
      return value;
    }

    int intField(String key) {
      final value = entry[key];
      if (value is! int) {
        throw StateError(
          '${file.path}: case ${entry['case']} has no integer "$key".',
        );
      }
      return value;
    }

    final name = stringField('case');
    cases.add(
      _Vector(
        name: name,
        algorithm: stringField('algorithm'),
        level: intField('level'),
        source: stringField('source'),
        size: intField('size'),
        sha256: stringField('sha256'),
        rawFile: entry['rawFile'] is String
            ? entry['rawFile'] as String
            : '$name.raw',
        lzoFile: entry['lzoFile'] is String
            ? entry['lzoFile'] as String
            : '$name.lzo',
        compressedSize: entry['compressedSize'] is int
            ? entry['compressedSize'] as int
            : null,
        compressedSha256: entry['compressedSha256'] is String
            ? entry['compressedSha256'] as String
            : null,
      ),
    );
  }

  return _Manifest(
    schema: schema,
    algorithm: algorithm,
    lzoVersion: lzoVersion,
    cases: cases,
  );
}

final class _Manifest {
  _Manifest({
    required this.schema,
    required this.algorithm,
    required this.lzoVersion,
    required this.cases,
  });

  final int schema;
  final String algorithm;
  final String lzoVersion;
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
