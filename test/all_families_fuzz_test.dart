import 'dart:math';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

/// A representative level for each family; the decoders are level-independent
/// within a family, so one per family exercises every grammar.
const Map<LzoAlgorithm, int> _sampleLevels = <LzoAlgorithm, int>{
  LzoAlgorithm.lzo1: 1,
  LzoAlgorithm.lzo1a: 1,
  LzoAlgorithm.lzo1b: 9,
  LzoAlgorithm.lzo1c: 9,
  LzoAlgorithm.lzo1f: 1,
  LzoAlgorithm.lzo1x: 1,
  LzoAlgorithm.lzo1y: 1,
  LzoAlgorithm.lzo1z: 999,
  LzoAlgorithm.lzo2a: 999,
};

void main() {
  test('random input never escapes as a non-LzoException', () {
    final random = Random(0x5eed);
    for (final entry in _sampleLevels.entries) {
      final codec = lzoCodec(entry.key, level: entry.value);
      for (var i = 0; i < 800; i++) {
        final length = random.nextInt(96);
        final input = Uint8List.fromList(
          List<int>.generate(length, (_) => random.nextInt(256)),
        );
        final output = Uint8List(random.nextInt(160));
        try {
          codec.decompressInto(input, output);
        } on LzoException {
          // Expected for malformed input.
        }
      }
    }
  });

  test('mutated valid blocks never escape as a non-LzoException', () {
    final random = Random(0xbeef);
    final source = Uint8List.fromList(
      List<int>.generate(4096, (i) => (i * 37 + (i >> 5)) & 0xff),
    );
    for (final entry in _sampleLevels.entries) {
      final codec = lzoCodec(entry.key, level: entry.value);
      final bound = codec.compressedSizeBound(source.length);
      final compressed = Uint8List(bound);
      final written = codec.compressInto(source, compressed);
      final valid = Uint8List.sublistView(compressed, 0, written);

      for (var i = 0; i < 400; i++) {
        final mutated = Uint8List.fromList(valid);
        for (var m = 0; m < 1 + random.nextInt(3); m++) {
          mutated[random.nextInt(mutated.length)] = random.nextInt(256);
        }
        final output = Uint8List(source.length);
        try {
          codec.decompressInto(mutated, output);
        } on LzoException {
          // Expected for corrupted streams.
        }
      }
    }
  });
}
