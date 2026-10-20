/// LZO1X throughput benchmarks (Dart side).
///
/// Measures, through the public `package:lzo_neo/lzo_neo.dart` API and nothing
/// else, one LZO1X-1 compression and one decompression per deterministic
/// corpus block. Compression ratio rows are emitted by `canonical.dart`, which
/// re-derives them from the same corpus so a chart always reports the ratio of
/// the encoder that was actually measured.
///
/// Run it from the repository root:
///
/// ```sh
/// dart run benchmark_test --compile aot --output jsonl \
///     benchmark/dart/lzo1x_benchmark_test.dart > build/bench/dart-aot.jsonl
/// dart run benchmark/dart/canonical.dart \
///     build/bench/dart-aot.jsonl build/bench/dart-aot.json
/// ```
library;

import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:lzo_neo/lzo_neo.dart';

import 'corpus.dart';

void main() {
  final codec = Lzo1x();
  final blocks = buildCorpus();
  final prepared = <String, _PreparedBlock>{
    for (final block in blocks) block.key: _prepare(codec, block),
  };

  // One benchmark per block: the body performs exactly one compression.
  for (final block in blocks) {
    final preparedBlock = prepared[block.key]!;
    benchmark(corpusId('compress', block.sizeLabel, block.kind), () {
      codec.compressInto(
        preparedBlock.source,
        preparedBlock.compressDestination,
      );
    });
  }

  // One benchmark per block: the body performs exactly one decompression.
  for (final block in blocks) {
    final preparedBlock = prepared[block.key]!;
    benchmark(corpusId('decompress', block.sizeLabel, block.kind), () {
      codec.decompressInto(
        preparedBlock.compressed,
        preparedBlock.decompressDestination,
      );
    });
  }
}

_PreparedBlock _prepare(Lzo1x codec, CorpusBlock block) {
  final compressDestination = Uint8List(Lzo1x.compressBound(block.size));
  final written = codec.compressInto(block.bytes, compressDestination);
  final compressed = Uint8List.sublistView(compressDestination, 0, written);
  final decompressDestination = Uint8List(block.size);
  final decoded = codec.decompressInto(compressed, decompressDestination);
  if (decoded != block.size) {
    throw StateError(
      'roundtrip failed for ${block.key}: decoded $decoded bytes, '
      'expected ${block.size}',
    );
  }
  for (var i = 0; i < block.size; i++) {
    if (decompressDestination[i] != block.bytes[i]) {
      throw StateError('roundtrip mismatch for ${block.key} at byte $i');
    }
  }
  return _PreparedBlock(
    source: block.bytes,
    compressed: compressed,
    compressDestination: compressDestination,
    decompressDestination: decompressDestination,
  );
}

final class _PreparedBlock {
  _PreparedBlock({
    required this.source,
    required this.compressed,
    required this.compressDestination,
    required this.decompressDestination,
  });

  final Uint8List source;
  final Uint8List compressed;
  final Uint8List compressDestination;
  final Uint8List decompressDestination;
}
