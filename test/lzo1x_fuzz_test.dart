import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

/// Runs [body] and returns either success or the LZO error code.
///
/// Any exception other than [LzoException] is a bug: the decoder must never
/// throw a `RangeError`, `StateError`, `TypeError` or leak an internal error.
LzoErrorCode? _runSafely(void Function() body) {
  try {
    body();
    return null;
  } on LzoException catch (error) {
    expect(
      error.code,
      isNot(LzoErrorCode.notYetImplemented),
      reason: 'no entry point may report "not implemented"',
    );
    return error.code;
  }
}

void main() {
  test('random buffers never escape as non-LzoException', () {
    final random = Random(0x5eed);
    final codec = Lzo1x();

    for (var i = 0; i < 20000; i++) {
      final inputLength = random.nextInt(80);
      final input = Uint8List.fromList(
        List<int>.generate(inputLength, (_) => random.nextInt(256)),
      );
      final outputLength = random.nextInt(256);
      final output = Uint8List(outputLength);

      _runSafely(() {
        final written = codec.decompressInto(input, output);
        expect(written, inInclusiveRange(0, outputLength));
      });
    }
  });

  test('mutated valid blocks never escape as non-LzoException', () {
    final random = Random(0xbeef);
    final codec = Lzo1x();
    final seeds = [
      File('test/data/hello.lzo').readAsBytesSync(),
      File('test/data/pattern.lzo').readAsBytesSync(),
      File('test/data/farmatch.lzo').readAsBytesSync(),
    ];

    for (var i = 0; i < 20000; i++) {
      final seed = seeds[i % seeds.length];
      var mutated = Uint8List.fromList(seed);

      final mutations = 1 + random.nextInt(4);
      for (var m = 0; m < mutations; m++) {
        if (mutated.isEmpty) break;
        switch (random.nextInt(3)) {
          case 0:
            mutated[random.nextInt(mutated.length)] = random.nextInt(256);
          case 1:
            // Truncate.
            final newLength = random.nextInt(mutated.length + 1);
            mutated = Uint8List.fromList(
              Uint8List.sublistView(mutated, 0, newLength),
            );
          case 2:
            // Append junk.
            final extra = random.nextInt(8);
            final grown = Uint8List(mutated.length + extra)
              ..setRange(0, mutated.length, mutated);
            for (var j = mutated.length; j < grown.length; j++) {
              grown[j] = random.nextInt(256);
            }
            mutated = grown;
        }
      }

      final output = Uint8List(random.nextInt(256));
      _runSafely(() => codec.decompressInto(mutated, output));
    }
  });
}
