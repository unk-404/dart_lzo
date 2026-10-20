/// Deterministic benchmark corpus shared by the Dart and C harnesses.
///
/// The generator is duplicated on purpose in `benchmark/c/bench.c`; both
/// implementations must stay byte-identical so the two series of a chart
/// measure the same input. Every block is regenerated from a fixed seed and a
/// fixed recipe, so ids, sizes and contents never depend on the machine.
///
/// | corpus  | bytes                                                        |
/// |---------|--------------------------------------------------------------|
/// | random  | xorshift32, seed `0x9E3779B9`, byte = `state >> 24`            |
/// | text    | `README.md` repeated cyclically to fill the block             |
/// | zeros   | `0x00`                                                        |
/// | pattern | the 16 bytes of `lzo1x-neo-bench!` repeated cyclically        |
///
/// Blocks are ordered size-major, then corpus-kind-minor:
/// 64 KiB, 1 MiB, 8 MiB x (random, text, zeros, pattern) = 12 blocks.
library;

import 'dart:io';
import 'dart:typed_data';

/// Block sizes used by both harnesses, in bytes.
const List<int> corpusSizes = <int>[64 * 1024, 1024 * 1024, 8 * 1024 * 1024];

/// Display labels for [corpusSizes], used in benchmark ids.
const List<String> corpusSizeLabels = <String>['64KiB', '1MiB', '8MiB'];

/// Corpus kinds, in the order they appear in reports.
const List<String> corpusKinds = <String>['random', 'text', 'zeros', 'pattern'];

/// Seed for the `random` corpus. Reset for every block.
const int randomSeed = 0x9E3779B9;

/// The 16 bytes that make up the `pattern` corpus.
const String patternSeed = 'lzo1x-neo-bench!';

/// Text source for the `text` corpus, relative to the repository root.
const String defaultTextPath = 'README.md';

/// Stable benchmark id for [operation] (`compress`, `decompress`, `ratio`).
///
/// The C harness builds the exact same string; it is the join key used by
/// benchcat to line the two series up.
String corpusId(String operation, String sizeLabel, String kind) =>
    'lzo1x.$operation.$sizeLabel.$kind';

/// One deterministic input block of the benchmark corpus.
final class CorpusBlock {
  CorpusBlock({
    required this.kind,
    required this.sizeLabel,
    required this.size,
    required this.bytes,
  });

  /// Corpus kind (`random`, `text`, `zeros`, `pattern`).
  final String kind;

  /// Size label (`64KiB`, `1MiB`, `8MiB`).
  final String sizeLabel;

  /// Block length in bytes.
  final int size;

  /// The block bytes.
  final Uint8List bytes;

  /// Key used to look the block up in per-benchmark maps.
  String get key => '$sizeLabel.$kind';
}

/// Builds the full 12-block corpus in a stable order.
///
/// [textPath] is read on every invocation so the corpus follows the checkout;
/// it defaults to the package README. Run the harness from the repository root.
List<CorpusBlock> buildCorpus({String textPath = defaultTextPath}) {
  final text = _readText(textPath);
  final blocks = <CorpusBlock>[];
  for (var i = 0; i < corpusSizes.length; i++) {
    final size = corpusSizes[i];
    final sizeLabel = corpusSizeLabels[i];
    for (final kind in corpusKinds) {
      final bytes = Uint8List(size);
      switch (kind) {
        case 'random':
          _fillRandom(bytes);
        case 'text':
          _fillCyclic(bytes, text);
        case 'zeros':
          break; // Uint8List is already zero-filled.
        case 'pattern':
          _fillCyclic(bytes, patternSeed.codeUnits);
        default:
          throw StateError('unknown corpus kind: $kind');
      }
      blocks.add(
        CorpusBlock(kind: kind, sizeLabel: sizeLabel, size: size, bytes: bytes),
      );
    }
  }
  return blocks;
}

Uint8List _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      'text corpus source "$path" not found; run the benchmark from the '
      'repository root or pass --text <path>',
    );
  }
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) {
    throw StateError('text corpus source "$path" is empty');
  }
  return bytes;
}

/// Fills [out] with an xorshift32 byte stream.
///
/// Mirrors `fill_random()` in `benchmark/c/bench.c` exactly.
void _fillRandom(Uint8List out) {
  var state = randomSeed;
  for (var i = 0; i < out.length; i++) {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    state &= 0xFFFFFFFF;
    out[i] = (state >> 24) & 0xFF;
  }
}

/// Fills [out] by repeating [source] cyclically.
void _fillCyclic(Uint8List out, List<int> source) {
  for (var i = 0; i < out.length; i++) {
    out[i] = source[i % source.length];
  }
}
