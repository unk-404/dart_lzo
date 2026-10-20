/// Converts a `benchmark_test` JSONL run into benchcat canonical JSON.
///
/// `benchmark_test` reports operations per second for each benchmark; benchcat
/// draws a comparison card from canonical records (`benchcat/report@1`). This
/// script is that adapter. It
///
/// * maps every JSONL `name` onto the shared benchmark id
///   (`lzo1x.<operation>.<size>.<corpus>`),
/// * converts `ops/sec` into MB/s using the known block size,
/// * adds one compression-ratio row per block (`unit: "x"`, lower is better),
///   recompressing the deterministic corpus so the ratio belongs to the same
///   encoder that was measured,
/// * emits rows in a fixed order with fixed ids so the SVG stays stable.
///
/// Usage (from the repository root):
///
/// ```sh
/// dart run benchmark/dart/canonical.dart <input.jsonl> <output.json> \
///     [--text README.md]
/// ```
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:lzo_neo/lzo.dart';

import 'corpus.dart';

/// Version of the `benchmark_test` package recorded in `meta.tool_version`.
const String _benchmarkTestVersion = '0.1.2';

/// Operations that are measured by `benchmark_test`.
const List<String> _measuredOperations = <String>['compress', 'decompress'];

/// Operations that end up in the report, in rendering order.
const List<String> _reportOperations = <String>[
  'compress',
  'decompress',
  'ratio',
];

/// Section headings drawn by benchcat, keyed by operation.
const Map<String, String> _groupLabels = <String, String>{
  'compress': 'Compress (LZO1X-1)',
  'decompress': 'Decompress',
  'ratio': 'Ratio (compressed/original)',
};

const String _usage =
    'usage: dart run benchmark/dart/canonical.dart <input.jsonl> '
    '<output.json> [--text README.md]';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  var textPath = defaultTextPath;
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--text') {
      if (i + 1 >= args.length) _die('--text requires a path');
      textPath = args[++i];
    } else if (arg.startsWith('-')) {
      _die('unknown option "$arg"\n$_usage');
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 2) _die('expected two paths\n$_usage');

  final inputPath = positional[0];
  final outputPath = positional[1];

  final blocks = buildCorpus(textPath: textPath);
  final knownIds = <String>{
    for (final operation in _reportOperations)
      for (final block in blocks)
        corpusId(operation, block.sizeLabel, block.kind),
  };
  final measurements = _readJsonl(inputPath, knownIds);

  final missing = <String>[
    for (final operation in _measuredOperations)
      for (final block in blocks)
        if (!measurements.containsKey(
          corpusId(operation, block.sizeLabel, block.kind),
        ))
          corpusId(operation, block.sizeLabel, block.kind),
  ];
  if (missing.isNotEmpty) {
    _die('no benchmark result for: ${missing.join(', ')}');
  }

  final ratios = _compressionRatios(blocks);
  final rows = <Map<String, Object?>>[];
  for (final operation in _reportOperations) {
    for (final block in blocks) {
      final id = corpusId(operation, block.sizeLabel, block.kind);
      final params = <String, Object?>{
        'corpus': block.kind,
        'size': block.sizeLabel,
        'bytes': block.size,
        'level': 'fast1',
      };
      final note = '${block.sizeLabel} block, fast1';
      if (operation == 'ratio') {
        rows.add(
          _row(
            id: id,
            group: _groupLabels[operation]!,
            label: '${block.kind} ${block.sizeLabel}',
            note: 'compressed/original, lower is better',
            unit: 'x',
            value: _round(ratios[block.key]!, 6),
            direction: 'lower',
            params: params,
          ),
        );
        continue;
      }
      final measurement = measurements[id]!;
      final mbPerSecond =
          measurement.operationsPerSecond * block.size / (1000 * 1000);
      rows.add(
        _row(
          id: id,
          group: _groupLabels[operation]!,
          label: '${block.kind} ${block.sizeLabel}',
          note: note,
          unit: 'MB/s',
          value: _round(mbPerSecond, 6),
          direction: 'higher',
          params: params,
          stats: <String, Object?>{
            'rme_pct': _round(measurement.relativeMarginOfError, 3),
            'samples': measurement.samples,
          },
        ),
      );
    }
  }

  final commit = Platform.environment['GITHUB_SHA'];
  final report = <String, Object?>{
    'schema': 'benchcat/report@1',
    'meta': <String, Object?>{
      'tool': 'benchmark_test',
      'tool_version': _benchmarkTestVersion,
      if (commit != null && commit.isNotEmpty) 'commit': commit,
      'platform': <String, Object?>{'os': _osName(), 'arch': _archName()},
    },
    'benchmarks': rows,
  };

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'canonical: wrote ${rows.length} rows for ${blocks.length} blocks to '
    '$outputPath',
  );
}

/// Reads the JSONL run and keeps records whose name maps to a known id.
Map<String, _Measurement> _readJsonl(String path, Set<String> knownIds) {
  final file = File(path);
  if (!file.existsSync()) _die('input file not found: $path');

  final measurements = <String, _Measurement>{};
  final unknown = <String>{};
  for (final line in const LineSplitter().convert(
    _decodeText(file.readAsBytesSync()),
  )) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    final name = decoded['name'];
    final throughput = decoded['throughput'];
    if (name is! String || throughput is! Map<String, Object?>) continue;
    final value = throughput['value'];
    final unit = throughput['unit'];
    if (value is! num) continue;
    if (unit is String && unit != 'ops/sec') continue;
    final id = _resolveId(name, knownIds);
    if (id == null) {
      unknown.add(name);
      continue;
    }
    final statistics = decoded['statistics'];
    var rme = 0.0;
    var samples = 0;
    if (statistics is Map<String, Object?>) {
      final relativeMargin = statistics['relativeMarginOfError'];
      final sampleCount = statistics['samples'];
      if (relativeMargin is num) rme = relativeMargin.toDouble();
      if (sampleCount is num) samples = sampleCount.toInt();
    }
    measurements[id] = _Measurement(
      operationsPerSecond: value.toDouble(),
      relativeMarginOfError: rme,
      samples: samples,
    );
  }
  if (unknown.isNotEmpty) {
    final preview = unknown.take(5).join(', ');
    stderr.writeln(
      'canonical: warning: ignored ${unknown.length} unrecognised '
      'benchmark name(s): $preview',
    );
  }
  return measurements;
}

/// Decodes a redirected JSONL file.
///
/// CI redirects with bash (plain UTF-8). Windows PowerShell 5.1 writes UTF-16
/// with a BOM, so both are accepted; malformed UTF-8 is tolerated because the
/// reporter interleaves non-JSON progress output.
String _decodeText(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return String.fromCharCodes(<int>[
      for (var i = 2; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ]);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return String.fromCharCodes(<int>[
      for (var i = 2; i + 1 < bytes.length; i += 2)
        (bytes[i] << 8) | bytes[i + 1],
    ]);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Maps a `benchmark_test` name (which may carry group prefixes) to an id.
String? _resolveId(String name, Set<String> knownIds) {
  if (knownIds.contains(name)) return name;
  String? best;
  for (final id in knownIds) {
    if (name == id || name.endsWith(' $id')) {
      if (best == null || id.length > best.length) best = id;
    }
  }
  return best;
}

/// One compression pass over the corpus -> compressed/original ratio per block.
Map<String, double> _compressionRatios(List<CorpusBlock> blocks) {
  final codec = Lzo1x();
  final ratios = <String, double>{};
  for (final block in blocks) {
    final destination = Uint8List(Lzo1x.compressBound(block.size));
    final written = codec.compressInto(block.bytes, destination);
    ratios[block.key] = written / block.size;
  }
  return ratios;
}

Map<String, Object?> _row({
  required String id,
  required String group,
  required String label,
  required String note,
  required String unit,
  required double value,
  required String direction,
  required Map<String, Object?> params,
  Map<String, Object?>? stats,
}) {
  return <String, Object?>{
    'id': id,
    'group': group,
    'label': label,
    'note': note,
    'unit': unit,
    'value': value,
    'direction': direction,
    'params': params,
    'stats': ?stats,
  };
}

double _round(double value, int digits) =>
    double.parse(value.toStringAsFixed(digits));

String _osName() {
  if (Platform.isLinux) return 'Linux';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  return Platform.operatingSystem;
}

String _archName() {
  final abi = Abi.current();
  if (abi == Abi.linuxX64 ||
      abi == Abi.windowsX64 ||
      abi == Abi.macosX64 ||
      abi == Abi.androidX64) {
    return 'x86_64';
  }
  if (abi == Abi.linuxArm64 ||
      abi == Abi.windowsArm64 ||
      abi == Abi.macosArm64 ||
      abi == Abi.androidArm64) {
    return 'aarch64';
  }
  if (abi == Abi.linuxIA32 || abi == Abi.windowsIA32) return 'x86';
  if (abi == Abi.linuxArm || abi == Abi.androidArm) return 'arm';
  return abi.toString();
}

Never _die(String message) {
  stderr.writeln('canonical: $message');
  exit(2);
}

final class _Measurement {
  const _Measurement({
    required this.operationsPerSecond,
    required this.relativeMarginOfError,
    required this.samples,
  });

  final double operationsPerSecond;
  final double relativeMarginOfError;
  final int samples;
}
