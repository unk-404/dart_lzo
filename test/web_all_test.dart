/// Browser smoke test for the complete algorithm matrix.
///
/// Runs under `dart test -p chrome`; the VM-only fixtures use `dart:io`, so this
/// file builds its own deterministic in-memory data instead.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:lzo_neo/lzop.dart';
import 'package:test/test.dart';

Uint8List _data(int length, int seed) {
  final out = Uint8List(length);
  var state = seed == 0 ? 1 : seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    out[i] = state >> 16;
  }
  return out;
}

void main() {
  test('every algorithm and level round-trips', () {
    final source = _data(4096, 42);
    for (final algorithm in LzoAlgorithm.values) {
      for (final level in _levels(algorithm)) {
        final codec = lzoCodec(algorithm, level: level);
        final compressed = codec.compress(Bytes.fromUint8List(source));
        final restored = codec.decompress(compressed, source.length);
        expect(
          restored.asUint8List(),
          orderedEquals(source),
          reason: '${algorithm.name} level $level',
        );
      }
    }
  });

  test('LZO-RLE round-trips', () {
    final source = Uint8List(8192);
    final compressed = Lzo1xRle().compress(Bytes.fromUint8List(source));
    final restored = Lzo1xRle().decompress(compressed, source.length);
    expect(restored.asUint8List(), orderedEquals(source));
  });

  test('lzop container round-trips', () {
    final source = _data(8192, 7);
    final file = const Lzop().compress(source);
    expect(const Lzop().decompress(file), orderedEquals(source));
  });
}

List<int> _levels(LzoAlgorithm algorithm) => switch (algorithm) {
  LzoAlgorithm.lzo1 => <int>[1, 99],
  LzoAlgorithm.lzo1a => <int>[1, 99],
  LzoAlgorithm.lzo1b => <int>[1, 9, 99, 999],
  LzoAlgorithm.lzo1c => <int>[1, 9, 99, 999],
  LzoAlgorithm.lzo1f => <int>[1, 999],
  LzoAlgorithm.lzo1x => <int>[1, 11, 12, 15, 999],
  LzoAlgorithm.lzo1y => <int>[1, 999],
  LzoAlgorithm.lzo1z => <int>[999],
  LzoAlgorithm.lzo2a => <int>[999],
};
