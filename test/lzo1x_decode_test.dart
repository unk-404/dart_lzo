import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:lzo_neo/lzo_neo.dart';
import 'package:test/test.dart';

Uint8List _read(String name) => File('test/data/$name').readAsBytesSync();

Matcher _throwsCode(LzoErrorCode code) =>
    throwsA(isA<LzoException>().having((error) => error.code, 'code', code));

void main() {
  final codec = Lzo1x();

  const vectors = <String>[
    'empty',
    'hello',
    'run_a',
    'pattern',
    'incompressible',
    'farmatch',
    'readme',
    'libsrc',
  ];

  group('reference vectors produced by liblzo2', () {
    for (final name in vectors) {
      test(name, () {
        final compressed = _read('$name.lzo');
        final original = _read('$name.raw');
        final output = Uint8List(original.length);

        final written = codec.decompressInto(compressed, output);

        expect(written, original.length);
        expect(output, orderedEquals(original));
      });
    }
  });

  group('end-of-stream handling', () {
    test('canonical marker decodes to empty output', () {
      final output = Uint8List(0);
      expect(
        codec.decompressInto(Uint8List.fromList([0x11, 0x00, 0x00]), output),
        0,
      );
    });

    test('any zero-distance M4 match terminates the stream', () {
      // 0x10..0x17 have the high distance bit clear, so a zero operand means
      // distance zero. 0x10 itself selects the length extension and therefore
      // consumes the would-be operand bytes. Only 0x11 can appear as the very
      // first byte (18..23 are the leading-literal-run encoding), so the other
      // markers follow a one-byte literal run.
      final single = Uint8List(0);
      expect(
        codec.decompressInto(Uint8List.fromList([0x11, 0x00, 0x00]), single),
        0,
      );

      final oneByte = Uint8List(1);
      for (final marker in [0x12, 0x13, 0x14, 0x15, 0x16, 0x17]) {
        final block = Uint8List.fromList([0x12, 0x41, marker, 0x00, 0x00]);
        expect(
          codec.decompressInto(block, oneByte),
          1,
          reason: 'marker 0x${marker.toRadixString(16)}',
        );
        expect(oneByte[0], 0x41);
      }
    });

    test('trailing bytes are rejected', () {
      final compressed = _read('hello.lzo');
      final padded = Uint8List(compressed.length + 1)
        ..setRange(0, compressed.length, compressed);
      expect(
        () => codec.decompressInto(padded, Uint8List(17)),
        _throwsCode(LzoErrorCode.inputNotConsumed),
      );
    });

    test('missing marker is an input overrun', () {
      final compressed = _read('hello.lzo');
      final truncated = compressed.sublist(0, compressed.length - 1);
      expect(
        () => codec.decompressInto(truncated, Uint8List(17)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });
  });

  group('malformed input', () {
    test('empty input', () {
      expect(
        () => codec.decompressInto(Uint8List(0), Uint8List(16)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });

    test('shorter than the smallest block', () {
      expect(
        () => codec.decompressInto(Uint8List(2), Uint8List(16)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });

    test('back-reference before the output start', () {
      // One literal byte, then an M2 match whose distance (9) exceeds the
      // one byte of output produced so far.
      expect(
        () => codec.decompressInto(
          Uint8List.fromList([0x12, 0x41, 0x40, 0x01]),
          Uint8List(16),
        ),
        _throwsCode(LzoErrorCode.lookbehindOverrun),
      );
    });

    test('output buffer too small', () {
      expect(
        () => codec.decompressInto(_read('hello.lzo'), Uint8List(16)),
        _throwsCode(LzoErrorCode.outputOverrun),
      );
    });

    test('truncated literal run', () {
      // Literal run of 18 bytes followed by only 3 literal bytes.
      final compressed = Uint8List.fromList([
        0x0f, // t = 15 -> 18 literals
        1, 2, 3,
      ]);
      expect(
        () => codec.decompressInto(compressed, Uint8List(64)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });

    test('length extension without a terminator', () {
      // t = 0 (literal run) followed by zero bytes only.
      final compressed = Uint8List.fromList([0x00, 0x00, 0x00]);
      expect(
        () => codec.decompressInto(compressed, Uint8List(64)),
        _throwsCode(LzoErrorCode.inputOverrun),
      );
    });
  });

  group('Bytes API', () {
    test('compress then decompress', () {
      final source = Bytes.fromString('hello, lzo world!');
      final compressed = codec.compress(source);
      final decoded = codec.decompress(compressed, source.length);

      expect(decoded.asUint8List(), orderedEquals(source.asUint8List()));
    });

    test('incompressible literal block matches the reference encoder', () {
      // liblzo2 encodes a 17-byte incompressible block as a leading literal
      // run followed by the end-of-stream marker.
      final source = Bytes.fromString('hello, lzo world!');
      expect(
        codec.compress(source).asUint8List(),
        orderedEquals(_read('hello.lzo')),
      );
    });

    test('negative output length is rejected', () {
      expect(
        () => codec.decompress(Bytes.fromList(const [0x11, 0, 0]), -1),
        _throwsCode(LzoErrorCode.invalidArgument),
      );
    });
  });
}
