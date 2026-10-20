/// Generates byte-exact fixtures for every LZO algorithm family.
///
/// Every `.lzo` file is produced by liblzo2 2.10 through the oracle CLI, never
/// by this package's encoders, so the decode tests compare against the
/// reference implementation. Run from the repository root:
///
/// ```sh
/// dart run tool/vectors/generate_families.dart --oracle /tmp/lzo_oracle
/// dart run tool/vectors/generate_families.dart --oracle /tmp/lzo_oracle \
///     --via-wsl
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sha256.dart';

const List<(String, int)> _algorithms = <(String, int)>[
  ('lzo1', 1),
  ('lzo1', 99),
  ('lzo1a', 1),
  ('lzo1a', 99),
  ('lzo1b', 1),
  ('lzo1b', 2),
  ('lzo1b', 3),
  ('lzo1b', 4),
  ('lzo1b', 5),
  ('lzo1b', 6),
  ('lzo1b', 7),
  ('lzo1b', 8),
  ('lzo1b', 9),
  ('lzo1b', 99),
  ('lzo1b', 999),
  ('lzo1c', 1),
  ('lzo1c', 2),
  ('lzo1c', 3),
  ('lzo1c', 4),
  ('lzo1c', 5),
  ('lzo1c', 6),
  ('lzo1c', 7),
  ('lzo1c', 8),
  ('lzo1c', 9),
  ('lzo1c', 99),
  ('lzo1c', 999),
  ('lzo1f', 1),
  ('lzo1f', 999),
  ('lzo1x', 1),
  ('lzo1x', 11),
  ('lzo1x', 12),
  ('lzo1x', 15),
  ('lzo1x', 999),
  ('lzo1y', 1),
  ('lzo1y', 999),
  ('lzo1z', 999),
  ('lzo2a', 999),
];

const List<int> _sizes = <int>[1024, 4096, 16384];
const List<String> _kinds = <String>['text', 'random', 'zeros', 'pattern'];

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  final output = Directory(options.output)..createSync(recursive: true);
  for (final file in output.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (name.endsWith('.raw') ||
        name.endsWith('.lzo') ||
        name == 'manifest.json') {
      file.deleteSync();
    }
  }

  final corpus = <String, Uint8List>{
    'empty': Uint8List(0),
    for (final size in _sizes)
      for (final kind in _kinds) '${kind}_$size': _build(kind, size),
  };

  final cases = <Map<String, Object>>[];
  for (final (algorithm, level) in _algorithms) {
    for (final entry in corpus.entries) {
      final name = '${algorithm}_${level}_${entry.key}';
      final rawFile = File('${output.path}/$name.raw')
        ..writeAsBytesSync(entry.value);
      final lzoFile = File('${output.path}/$name.lzo');
      final result = _runOracle(options, <String>[
        'compress',
        algorithm,
        '$level',
        rawFile.path,
        lzoFile.path,
      ]);
      if (result.exitCode != 0) {
        stderr.writeln('oracle failed for $name: ${result.stderr}');
        exit(1);
      }
      final compressed = lzoFile.readAsBytesSync();
      cases.add(<String, Object>{
        'case': name,
        'algorithm': algorithm,
        'level': level,
        'source': entry.key,
        'size': entry.value.length,
        'sha256': sha256Hex(entry.value),
        'rawFile': '$name.raw',
        'lzoFile': '$name.lzo',
        'compressedSize': compressed.length,
        'compressedSha256': sha256Hex(compressed),
      });
    }
  }

  final manifest = <String, Object>{
    'schema': 1,
    'generatedBy': 'tool/vectors/generate_families.dart',
    'algorithm': 'all',
    'lzoVersion': '2.10',
    'cases': cases,
  };
  File('${output.path}/manifest.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  final rawBytes = cases.fold<int>(
    0,
    (sum, entry) => sum + (entry['size'] as int),
  );
  final compressedBytes = cases.fold<int>(
    0,
    (sum, entry) => sum + (entry['compressedSize'] as int),
  );
  print(
    'generated ${cases.length} family vectors '
    '(${rawBytes ~/ 1024} KiB raw, ${compressedBytes ~/ 1024} KiB compressed)',
  );
}

/// Fixed text sample for the `text` corpus.
///
/// The fixtures must not depend on repository files such as README.md: editing
/// the README would otherwise change every committed text vector and make the
/// CI reproducibility check fail. This sample is part of the generator.
const String _textSeed =
    'LZO is a lossless block compression algorithm focused on fast '
    'decompression. It represents a block as a sequence of literal runs and '
    'back-references into a sliding dictionary.\n'
    'The compressor trades ratio for speed: level 1 is a single-pass greedy '
    'search, while level 999 performs a lazy search over a large window and is '
    'intended for pre-compressed data.\n'
    'Decompression is deliberately simple and allocation-free. Every opcode is '
    'validated so that truncated or corrupted blocks fail with a typed error '
    'instead of reading out of bounds.\n'
    'LZO1X is the variant used by lzop, the Linux kernel, btrfs and SquashFS. '
    'LZO1B and LZO1C favour more redundant data, and LZO2A uses a bit-oriented '
    'grammar.\n';

Uint8List _build(String kind, int size) {
  final out = Uint8List(size);
  switch (kind) {
    case 'text':
      for (var i = 0; i < size; i++) {
        out[i] = _textSeed.codeUnitAt(i % _textSeed.length);
      }
    case 'random':
      var state = 0x9e3779b9;
      for (var i = 0; i < size; i++) {
        state ^= (state << 13) & 0xffffffff;
        state ^= state >> 17;
        state ^= (state << 5) & 0xffffffff;
        state &= 0xffffffff;
        out[i] = (state >> 24) & 0xff;
      }
    case 'zeros':
      break;
    case 'pattern':
      const pattern = 'lzo1x-neo-bench!';
      for (var i = 0; i < size; i++) {
        out[i] = pattern.codeUnitAt(i % pattern.length);
      }
  }
  return out;
}

ProcessResult _runOracle(_Options options, List<String> arguments) {
  if (options.viaWsl) {
    return Process.runSync('wsl', <String>[options.oracle, ...arguments]);
  }
  return Process.runSync(options.oracle, arguments);
}

final class _Options {
  _Options(this.oracle, this.output, this.viaWsl);

  final String oracle;
  final String output;
  final bool viaWsl;

  static _Options parse(List<String> arguments) {
    var oracle = Platform.environment['LZO_ORACLE'] ?? '';
    var output = 'test/data/families';
    var viaWsl = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--oracle':
          oracle = arguments[++i];
        case '--output':
          output = arguments[++i];
        case '--via-wsl':
          viaWsl = true;
        default:
          throw ArgumentError('unknown argument: ${arguments[i]}');
      }
    }
    if (oracle.isEmpty) {
      throw ArgumentError('pass --oracle <path> or set LZO_ORACLE');
    }
    return _Options(oracle, output, viaWsl);
  }
}
