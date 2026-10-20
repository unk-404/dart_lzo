/// Generates the byte-exact LZO1X fixtures under `test/data/`.
///
/// The fixtures are produced by the reference implementation, never by this
/// package's encoder, so the decode and differential tests compare against
/// real liblzo2 output. Run this from the repository root:
///
/// ```sh
/// make -C tool/oracle LZO_PREFIX=/path/to/lzo-2.10
/// dart run tool/vectors/generate.dart --oracle tool/oracle/lzo_oracle
/// ```
///
/// or use `tool/vectors/generate.sh`, which builds the oracle when needed.
/// The oracle path can also come from `LZO_ORACLE`.
///
/// The eight imported fixtures (`empty`, `hello`, `run_a`, `pattern`,
/// `incompressible`, `farmatch`, `readme`, `libsrc`) keep their original
/// `.raw` bytes; only their `.lzo` file is regenerated, at the level recorded
/// in the corpus table (the README and source imports were produced by the
/// Rust `lzo` crate with `lzo1x_999`). All other cases are generated from the
/// deterministic builders below.
///
/// Files are written as raw bytes with `dart:io`; no text mode is involved, so
/// line-ending conversion cannot corrupt them. `.gitattributes` keeps Git from
/// touching `test/data/**` as well.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sha256.dart';

/// One fixture in the corpus.
final class VectorCase {
  const VectorCase({
    required this.name,
    required this.level,
    required this.source,
    required this.size,
    this.build,
    this.expectedImportedSize,
  });

  /// Case name, also the basename of the `.raw` and `.lzo` files.
  final String name;

  /// liblzo2 compression level used for the committed `.lzo` file.
  ///
  /// The LZO1X fast levels are 1, 11, 12 and 15. The two imported text
  /// fixtures use 999, which this package's Dart encoder does not implement
  /// but the decoder must handle.
  final int level;

  /// Human-readable provenance recorded in the manifest.
  final String source;

  /// Expected decompressed size.
  final int size;

  /// Generates the raw bytes. `null` for imported fixtures, whose committed
  /// `.raw` file is the source of truth.
  final Uint8List Function()? build;

  /// For imported fixtures: the size the committed `.raw` file must have.
  ///
  /// This catches accidental text-mode conversion (the CRLF incident) before
  /// it can silently change a reference vector.
  final int? expectedImportedSize;

  bool get imported => build == null;
}

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options.help) {
    _Options.printUsage();
    return;
  }

  final oracle = _resolveOracle(options.oracle);
  final version = _oracleVersion(oracle);
  if (version != '2.10' && !options.allowVersionMismatch) {
    _fail(
      'oracle $oracle uses liblzo2 $version, but the committed vectors were '
      'generated with 2.10.\n'
      'Pass --allow-version-mismatch to generate anyway '
      '(expect a git diff in test/data).',
    );
  }
  stdout.writeln('oracle: ${oracle.path} (liblzo2 $version)');

  final dataDirectory = Directory(options.dataDirectory);
  dataDirectory.createSync(recursive: true);

  final manifestCases = <Map<String, Object?>>[];
  var totalRaw = 0;
  var totalCompressed = 0;

  for (final vector in _corpus) {
    final rawPath = '${dataDirectory.path}/${vector.name}.raw';
    final compressedPath = '${dataDirectory.path}/${vector.name}.lzo';

    final Uint8List raw;
    if (vector.imported) {
      final imported = File(rawPath);
      if (!imported.existsSync()) {
        _fail(
          'imported fixture $rawPath does not exist; it is part of the '
          'repository and this generator only rewrites its .lzo file.',
        );
      }
      raw = imported.readAsBytesSync();
      final expected = vector.expectedImportedSize;
      if (expected != null && raw.length != expected) {
        _fail(
          'imported fixture $rawPath is ${raw.length} bytes, expected '
          '$expected. It was probably converted from LF to CRLF; restore the '
          'committed bytes (see .gitattributes).',
        );
      }
    } else {
      raw = vector.build!();
      if (raw.length != vector.size) {
        _fail(
          'internal error: ${vector.name} builder produced ${raw.length} '
          'bytes, expected ${vector.size}.',
        );
      }
      File(rawPath).writeAsBytesSync(raw, flush: true);
    }

    _compress(
      oracle: oracle,
      level: vector.level,
      rawPath: rawPath,
      compressedPath: compressedPath,
      algorithm: 'lzo1x',
    );

    final compressed = File(compressedPath).readAsBytesSync();
    if (compressed.isEmpty) {
      _fail('oracle produced an empty compressed file for ${vector.name}.');
    }

    manifestCases.add({
      'case': vector.name,
      'algorithm': 'lzo1x',
      'level': vector.level,
      'source': vector.source,
      'size': raw.length,
      'sha256': sha256Hex(raw),
      'rawFile': '${vector.name}.raw',
      'lzoFile': '${vector.name}.lzo',
      'compressedSize': compressed.length,
      'compressedSha256': sha256Hex(compressed),
    });

    totalRaw += raw.length;
    totalCompressed += compressed.length;
    final percent = raw.isEmpty ? 0.0 : compressed.length * 100 / raw.length;
    stdout.writeln(
      '  ${vector.name.padRight(16)} level ${vector.level.toString().padLeft(3)}  '
      '${raw.length.toString().padLeft(8)} B -> '
      '${compressed.length.toString().padLeft(7)} B  '
      '(${percent.toStringAsFixed(1)}%)',
    );
  }

  final manifest = <String, Object?>{
    'schema': 1,
    'generatedBy': 'tool/vectors/generate.dart',
    'algorithm': 'lzo1x',
    'lzoVersion': version,
    'cases': manifestCases,
  };
  final manifestPath =
      options.manifest ?? '${dataDirectory.path}/manifest.json';
  File(manifestPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );

  stdout
    ..writeln(
      '\n${manifestCases.length} vectors, '
      '$totalRaw raw bytes -> $totalCompressed compressed bytes '
      '(${totalRaw == 0 ? '0' : (totalCompressed * 100 / totalRaw).toStringAsFixed(1)}%).',
    )
    ..writeln('manifest: $manifestPath');
}

/// Runs the oracle to compress [rawPath] into [compressedPath].
void _compress({
  required File oracle,
  required String algorithm,
  required int level,
  required String rawPath,
  required String compressedPath,
}) {
  final temporary = File('$compressedPath.tmp');
  if (temporary.existsSync()) {
    temporary.deleteSync();
  }

  final result = Process.runSync(oracle.path, [
    'compress',
    algorithm,
    '$level',
    rawPath,
    temporary.path,
  ]);
  if (result.exitCode != 0) {
    if (temporary.existsSync()) {
      temporary.deleteSync();
    }
    _fail(
      'oracle failed to compress ${File(rawPath).uri.pathSegments.last} '
      'at level $level (exit ${result.exitCode}).\n'
      '${result.stderr.toString().trim()}',
    );
  }

  if (File(compressedPath).existsSync()) {
    File(compressedPath).deleteSync();
  }
  temporary.renameSync(compressedPath);
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
  final result = Process.runSync(oracle.path, ['version']);
  if (result.exitCode != 0) {
    _fail(
      'oracle $oracle does not answer "version" (exit ${result.exitCode}).\n'
      '${result.stderr.toString().trim()}',
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
  stderr.writeln('generate: $message');
  exit(1);
}

/// The fixed corpus. Order is stable because the manifest is committed.
final List<VectorCase> _corpus = <VectorCase>[
  // Imported reference fixtures. Their `.raw` files are part of the
  // repository; only the compressed form is (re)generated.
  const VectorCase(
    name: 'empty',
    level: 1,
    source: 'imported:rust-lzo smoke fixture',
    size: 0,
    expectedImportedSize: 0,
  ),
  const VectorCase(
    name: 'hello',
    level: 1,
    source: 'imported:rust-lzo smoke fixture',
    size: 17,
    expectedImportedSize: 17,
  ),
  const VectorCase(
    name: 'run_a',
    level: 1,
    source: 'imported:rust-lzo run-of-a fixture',
    size: 5000,
    expectedImportedSize: 5000,
  ),
  const VectorCase(
    name: 'pattern',
    level: 1,
    source: 'imported:rust-lzo pattern fixture',
    size: 10200,
    expectedImportedSize: 10200,
  ),
  const VectorCase(
    name: 'incompressible',
    level: 1,
    source: 'imported:rust-lzo incompressible fixture',
    size: 3000,
    expectedImportedSize: 3000,
  ),
  const VectorCase(
    name: 'farmatch',
    level: 1,
    source: 'imported:rust-lzo far-match fixture',
    size: 40000,
    expectedImportedSize: 40000,
  ),
  const VectorCase(
    name: 'readme',
    level: 999,
    source: 'imported:rust-lzo README text',
    size: 2770,
    expectedImportedSize: 2770,
  ),
  const VectorCase(
    name: 'libsrc',
    level: 999,
    source: 'imported:rust-lzo Rust source text',
    size: 8284,
    expectedImportedSize: 8284,
  ),

  // Encoding boundaries: literal runs of 1..15 bytes use the leading
  // `18..33` form, longer runs use the `0` opcode with length extensions, and
  // 238/239 are the last lengths that fit in a single extended literal run.
  VectorCase(
    name: 'one_byte',
    level: 1,
    source: 'generated:single-byte',
    size: 1,
    build: () => Uint8List.fromList(const [0x2a]),
  ),
  for (final size in const [16, 17, 18, 19, 237, 238, 239, 240])
    VectorCase(
      name: 'boundary_$size',
      level: 1,
      source: 'generated:boundary-random',
      size: size,
      build: () => _randomBytes(size, 0x5eed0000 + size),
    ),

  // 1 KiB: every data class.
  VectorCase(
    name: 'text_1k',
    level: 1,
    source: 'generated:text',
    size: 1024,
    build: () => _textBytes(1024),
  ),
  VectorCase(
    name: 'zeros_1k',
    level: 1,
    source: 'generated:zeros',
    size: 1024,
    build: () => Uint8List(1024),
  ),
  VectorCase(
    name: 'pattern_1k',
    level: 12,
    source: 'generated:repeating-pattern',
    size: 1024,
    build: () => _patternBytes(1024),
  ),
  VectorCase(
    name: 'random_1k',
    level: 1,
    source: 'generated:seeded-random xorshift32',
    size: 1024,
    build: () => _randomBytes(1024, 0x12340001),
  ),
  VectorCase(
    name: 'binary_1k',
    level: 11,
    source: 'generated:binary-records',
    size: 1024,
    build: () => _binaryBytes(1024),
  ),

  // 64 KiB: the same classes one size tier up.
  VectorCase(
    name: 'text_64k',
    level: 1,
    source: 'generated:text',
    size: 65536,
    build: () => _textBytes(65536),
  ),
  VectorCase(
    name: 'zeros_64k',
    level: 1,
    source: 'generated:zeros',
    size: 65536,
    build: () => Uint8List(65536),
  ),
  VectorCase(
    name: 'pattern_64k',
    level: 15,
    source: 'generated:repeating-pattern',
    size: 65536,
    build: () => _patternBytes(65536),
  ),
  VectorCase(
    name: 'random_64k',
    level: 1,
    source: 'generated:seeded-random xorshift32',
    size: 65536,
    build: () => _randomBytes(65536, 0x12340002),
  ),
  VectorCase(
    name: 'binary_64k',
    level: 12,
    source: 'generated:binary-records',
    size: 65536,
    build: () => _binaryBytes(65536),
  ),

  // 256 KiB and 1 MiB: longer inputs, larger windows and distances.
  VectorCase(
    name: 'text_256k',
    level: 15,
    source: 'generated:text',
    size: 262144,
    build: () => _textBytes(262144),
  ),
  VectorCase(
    name: 'random_256k',
    level: 1,
    source: 'generated:seeded-random xorshift32',
    size: 262144,
    build: () => _randomBytes(262144, 0x12340003),
  ),
  VectorCase(
    name: 'pattern_256k',
    level: 12,
    source: 'generated:repeating-pattern',
    size: 262144,
    build: () => _patternBytes(262144),
  ),
  VectorCase(
    name: 'text_1m',
    level: 1,
    source: 'generated:text',
    size: 1048576,
    build: () => _textBytes(1048576),
  ),
];

/// Deterministic xorshift32 byte stream, independent of Dart's `Random`
/// implementation and seed handling.
Uint8List _randomBytes(int size, int seed) {
  var state = seed == 0 ? 0xdeadbeef : seed & 0xffffffff;
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    state &= 0xffffffff;
    bytes[i] = state & 0xff;
  }
  return bytes;
}

/// Repeating-pattern data with a period that is not a power of two.
Uint8List _patternBytes(int size) {
  final period = utf8.encode(
    'lzo1x-0123456789-abcdefghijklmnopqrstuvwxyz-'
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ-lzo1x-block\n',
  );
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = period[i % period.length];
  }
  return bytes;
}

/// All-zero data: long, overlapping matches with distance one.
Uint8List _binaryBytes(int size) {
  const payloads = <List<int>>[
    [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef],
    [0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe],
    [0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff],
    [0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe],
    [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
    [0x7f, 0x80, 0x01, 0xfe, 0x02, 0xfd, 0x03, 0xfc],
    [0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48],
    [0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97],
  ];
  final bytes = Uint8List(size);
  var offset = 0;
  var record = 0;
  void put(int value) {
    if (offset < bytes.length) {
      bytes[offset++] = value;
    }
  }

  while (offset < bytes.length) {
    put(0xca);
    put(0xfe);
    put(record & 0xff);
    put((record >> 8) & 0xff);
    put((record >> 16) & 0xff);
    put((record >> 24) & 0xff);
    put(0x00);
    put(0x00);
    final payload = payloads[record % payloads.length];
    for (final byte in payload) {
      put(byte);
    }
    record++;
  }
  return bytes;
}

/// Text-like data: a repeating set of README/Dart-source paragraphs, each
/// prefixed with a unique line number so that the stream does not collapse
/// into a single long match.
Uint8List _textBytes(int size) {
  final builder = BytesBuilder(copy: false);
  var line = 0;
  while (builder.length < size) {
    final paragraph = _textParagraphs[line % _textParagraphs.length];
    final number = line.toString().padLeft(5, '0');
    builder.add(utf8.encode('// $number $paragraph\n'));
    line++;
  }
  final bytes = builder.takeBytes();
  return bytes.length == size
      ? bytes
      : Uint8List.fromList(bytes.sublist(0, size));
}

const List<String> _textParagraphs = <String>[
  '# lzo_neo',
  'A pure Dart implementation of the LZO1X block codec. Raw blocks carry no '
      'header and no original length, so the caller supplies the size of the '
      'destination buffer.',
  'The encoder emits literal runs and back-references; each match names an '
      'earlier position in the output, and short matches are encoded with the '
      'distance operand in the low bits.',
  'LZO1X favours decompression speed: the format has four match encodings '
      '(M1 through M4) with different distance and length ranges, followed by '
      'the end-of-stream marker 0x11 0x00 0x00.',
  'const bound = source.length + (source.length >> 4) + 64 + 3; // n + n/16 '
      '+ 64 + 3 is the documented worst case for one LZO1X block.',
  'The decoder validates every literal run and back-reference before it '
      'copies, which keeps malformed input from reading or writing outside '
      'either buffer.',
  'Matches may overlap the bytes they produce, so copying one byte at a time '
      'reproduces the behaviour of liblzo2\'s lzo1x_decompress_safe and of the '
      'in-kernel decoder.',
  'Seeded fixtures keep the corpus reproducible: the xorshift32 streams below '
      'never depend on the platform, the Dart SDK version or the host default '
      'random number generator.',
];

/// Command line options for the generator.
final class _Options {
  _Options({
    required this.dataDirectory,
    required this.manifest,
    required this.oracle,
    required this.allowVersionMismatch,
    required this.help,
  });

  final String dataDirectory;
  final String? manifest;
  final String? oracle;
  final bool allowVersionMismatch;
  final bool help;

  static _Options parse(List<String> arguments) {
    var dataDirectory = 'test/data';
    String? manifest;
    String? oracle;
    var allowVersionMismatch = false;
    var help = false;

    String valueFor(String argument, String name, int index) {
      if (argument == '--$name') {
        if (index + 1 >= arguments.length) {
          _fail('--$name requires a value.');
        }
        return arguments[index + 1];
      }
      return argument.substring('--$name='.length);
    }

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument == '--data-dir' ||
          argument.startsWith('--data-dir=')) {
        dataDirectory = valueFor(argument, 'data-dir', i);
        if (argument == '--data-dir') {
          i++;
        }
      } else if (argument == '--manifest' ||
          argument.startsWith('--manifest=')) {
        manifest = valueFor(argument, 'manifest', i);
        if (argument == '--manifest') {
          i++;
        }
      } else if (argument == '--oracle' || argument.startsWith('--oracle=')) {
        oracle = valueFor(argument, 'oracle', i);
        if (argument == '--oracle') {
          i++;
        }
      } else if (argument == '--allow-version-mismatch') {
        allowVersionMismatch = true;
      } else {
        _fail('unknown argument "$argument". Use --help for usage.');
      }
    }

    return _Options(
      dataDirectory: dataDirectory,
      manifest: manifest,
      oracle: oracle,
      allowVersionMismatch: allowVersionMismatch,
      help: help,
    );
  }

  static void printUsage() {
    stdout.writeln('''
Regenerate the committed LZO1X fixtures in test/data/.

Options:
  --oracle <path>              lzo_oracle binary (env: LZO_ORACLE)
  --data-dir <dir>             output directory (default: test/data)
  --manifest <path>            manifest path (default: <data-dir>/manifest.json)
  --allow-version-mismatch     accept liblzo2 versions other than 2.10
  -h, --help                   show this help

The committed .lzo files are plain liblzo2 output, so regenerate them with
liblzo2 2.10 to keep them byte-for-byte reproducible.''');
  }
}
