/// Tests for [lzo1xOptimize] and [lzo1xDecompressInPlace].
///
/// The golden fixtures below (`_Golden`) are raw LZO1X blocks together with the
/// exact blocks that liblzo2 2.10's `lzo1x_optimize` produces for them, and the
/// expected decompressed bytes. They were generated with the reference
/// implementation in WSL (liblzo2 2.10, built from the official tarball):
///
/// * `o_m1_a`, `o_m1_b`, `o_m2`, `o_m3_a`, `o_m3_b` are hand-written streams
///   that exercise each of the five rewrites in `lzo1x_oo.ch`, including the
///   self-referential `copy2`/`copy3` cases (match distance 1 and 2);
/// * `lzo1x_999_small` is the output of `lzo1x_999_compress` on 512 bytes of
///   text/pattern data.
///
/// `lzo1xOptimize` must reproduce the liblzo2 blocks byte for byte, which is
/// the strongest available proof that the port is faithful. Because those
/// golden blocks are liblzo2's own output, the byte-equality assertions also
/// establish that liblzo2's `lzo1x_decompress_safe` decodes the streams this
/// package produces (they are literally byte-identical).
///
/// The in-place layout matches lzop: the compressed block sits at the end of a
/// buffer whose start holds the output, with the buffer sized
/// `outputLength + outputLength ~/ 16 + 64 + 3`.
///
/// Setting `LZO_ORACLE` to a `lzo_oracle` build (see `tool/oracle`) enables an
/// extra group that feeds the optimized streams back through liblzo2's
/// `lzo1x_decompress_safe`; without it that group is skipped and the golden
/// fixtures remain the liblzo2 cross-check.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lzo_neo/lzo_neo.dart';
import 'package:lzo_neo/src/lzo1x/optimize.dart';
import 'package:test/test.dart';

/// A compressed block, liblzo2's optimized version of it, and the output.
final class _Golden {
  _Golden(this.name, String raw, String block, String optimized)
    : raw = _bytes(raw),
      block = _bytes(block),
      optimized = _bytes(optimized);

  final String name;
  final Uint8List raw;
  final Uint8List block;
  final Uint8List optimized;
}

final _goldenBlocks = <_Golden>[
  // o_m1_a: one pending literal, then a two-byte M1 match (distance 1), then a
  // match. The match becomes two literals of the previous short run.
  _Golden(
    'o_m1_a_off1',
    '41414141424242',
    '1241210100420000110000',
    '1241210300424242110000',
  ),
  // o_m1_b: two pending literals, an M1 match (distance 1), then a literal run.
  _Golden(
    'o_m1_b_off1',
    '414141414243434378797a77',
    '1241210200424300000178797a77110000',
    '1241210000054243434378797a77110000',
  ),
  // o_m2: a long literal run, an M2 match of length 3 (distance 2), then a
  // literal run. The match bytes come from a self-referential source.
  _Golden(
    'o_m2_off2',
    '41424142414241707172737473747375767778',
    '1541424142440002707172737444000175767778110000',
    '1541424142440009707172737473747375767778110000',
  ),
  // o_m3_a: an M3 match of length 3 (distance 1), no pending literals, then a
  // match.
  _Golden(
    'o_m3_a_off1',
    '41424344414243434343',
    '1541424344210c00210000110000',
    '1541424344210f00434343110000',
  ),
  // o_m3_b: two pending literals, an M3 match of length 3 (distance 2), then a
  // literal run.
  _Golden(
    'o_m3_b_off2',
    '41424142414241424342434275767778',
    '154142414221060042432104000175767778110000',
    '154142414221040006424342434275767778110000',
  ),
  // LZO1X-999 output for a 512-byte mixed text/pattern input: several rewrites.
  _Golden(
    'lzo1x_999_small',
    '626c6f636b206f7665722062726f776e20626c6f636b20666f78206275666665'
        '72206275666665722072756e206a756d70732072756e2072756e206c7a6f2071'
        '7569636b206d617463682072756e206d617463682073747265616d206c697465'
        '72616c20646f67206a756d7073206c69746572616c20626c6f636b206d617463'
        '6820626c6f636b2073747265616d206d617463682062726f776e206c617a7920'
        '72756e20717569636b20d23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c'
        'd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c'
        'd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c'
        'd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c'
        'd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c'
        'd23cd23cd23cd23cd23cd23cd23cd23cd23cd23c646f67206c617a7920627566'
        '6665722062726f776e206c617a792072756e206c69746572616c206a756d7073'
        '2072756e206275666665722062756666657220717569636b206c617a79207275'
        '6e20646f67206d6174636820646f67206a756d7073206d61746368206f766572'
        '206a756d7073206f766572206c617a79206c7a6f206c7a6f2062756666657220'
        '6c617a7920626c6f636b206f76657220746865206c69746572616c206d617463',
    '22626c6f636b206f7665722062726f776e20a302666f7807027566667802ba00'
        '72750c06026a756d707384016c00046c7a6f207175695405026d617463688c02'
        'a4010f73747265616d206c69746572616c20646f67c807e402b00cb005ac01c8'
        '06c8028411016c617a79900ab20cd23c208704007c1d9017e4282c3803f02028'
        '34052ca405b81d27b8007409b822281c05bc019436a0028801880674326c00d0'
        '09bc102893077468652700027408110000',
    '22626c6f636b206f7665722062726f776e20a302666f7807027566667802b800'
        '0672756e206a756d707384016c000c6c7a6f20717569636b206d617463688c02'
        'a4010f73747265616d206c69746572616c20646f67c807e402b00cb005ac01c8'
        '06c8028411016c617a79900ab20cd23c208704007c1d9017e4282c3803f02028'
        '34052ca405b81d27b8007409b822281c05bc019436a0028801880674326c00d0'
        '09bc102893077468652700027408110000',
  ),
];

/// Decodes a whitespace-separated hex fixture.
Uint8List _bytes(String hex) {
  final digits = hex.replaceAll(RegExp(r'\s'), '');
  if (digits.length.isOdd) {
    throw ArgumentError.value(hex, 'hex', 'odd number of digits');
  }
  final result = Uint8List(digits.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(digits.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return result;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _expectBytes(List<int> actual, List<int> expected, [String where = '']) {
  expect(actual.length, expected.length, reason: 'length $where');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail(
        'byte $i differs: 0x${actual[i].toRadixString(16).padLeft(2, '0')} '
        '!= 0x${expected[i].toRadixString(16).padLeft(2, '0')} $where',
      );
    }
  }
}

/// Throws only [LzoException] for an input that must be rejected.
void _mustThrowLzo(void Function() action, [String where = '']) {
  try {
    action();
  } on LzoException {
    return;
  } catch (error) {
    fail('threw ${error.runtimeType} instead of LzoException $where: $error');
  }
  fail('expected an LzoException $where');
}

/// Allows success but never any error other than [LzoException].
void _mustOnlyThrowLzo(void Function() action, [String where = '']) {
  try {
    action();
  } on LzoException {
    // A malformed block is allowed to be rejected.
  } catch (error) {
    fail('threw ${error.runtimeType} instead of LzoException $where: $error');
  }
}

/// Deterministic corpus used by the round-trip and in-place tests.
Uint8List _corpus(String kind, int size, int seed) {
  final random = Random(seed);
  final result = Uint8List(size);
  switch (kind) {
    case 'random':
      for (var i = 0; i < size; i++) {
        result[i] = random.nextInt(256);
      }
      return result;
    case 'text':
      const words = [
        'the',
        'quick',
        'brown',
        'fox',
        'jumps',
        'over',
        'lazy',
        'dog',
        'lzo',
        'compress',
        'decompress',
        'buffer',
        'block',
        'literal',
        'match',
        'run',
        'stream',
        'byte',
        'window',
        'distance',
      ];
      var position = 0;
      while (position < size) {
        for (final byte in words[random.nextInt(words.length)].codeUnits) {
          if (position < size) result[position++] = byte;
        }
        if (position < size) result[position++] = 32;
      }
      return result;
    case 'pattern':
      final period = 3;
      final seedBytes = List<int>.generate(period, (_) => random.nextInt(256));
      for (var i = 0; i < size; i++) {
        result[i] = seedBytes[i % period];
      }
      return result;
    default:
      throw ArgumentError.value(kind, 'kind');
  }
}

/// Places [block] at the end of a fresh buffer, lzop style.
({Uint8List buffer, int offset}) _placeAtEnd(
  Uint8List block,
  int outputLength,
  int overhead,
) {
  final length = max(outputLength + overhead, block.length);
  final buffer = Uint8List(length);
  final offset = length - block.length;
  buffer.setRange(offset, length, block);
  return (buffer: buffer, offset: offset);
}

/// Runs `lzo1xOptimize` with guard bytes around both views.
///
/// Returns whether the block was rejected. Fails the test if either buffer is
/// written outside the range the API was given.
bool _optimizeGuarded(Uint8List blockSource, int scratchLength) {
  const guard = 8;
  final blockBacking = Uint8List(blockSource.length + 2 * guard)
    ..fillRange(0, guard, 0xa5)
    ..fillRange(
      guard + blockSource.length,
      blockSource.length + 2 * guard,
      0x5a,
    );
  blockBacking.setRange(guard, guard + blockSource.length, blockSource);
  final block = Uint8List.sublistView(
    blockBacking,
    guard,
    guard + blockSource.length,
  );
  final scratchBacking = Uint8List(scratchLength + 2 * guard)
    ..fillRange(0, guard, 0xc3)
    ..fillRange(scratchLength + guard, scratchLength + 2 * guard, 0x3c);
  final scratch = Uint8List.sublistView(
    scratchBacking,
    guard,
    guard + scratchLength,
  );
  var rejected = false;
  try {
    lzo1xOptimize(block, scratch);
  } on LzoException {
    // Some of the fuzzed blocks are expected to be rejected.
    rejected = true;
  }
  for (var i = 0; i < guard; i++) {
    expect(blockBacking[i], 0xa5, reason: 'block guard before byte $i');
    expect(
      blockBacking[guard + blockSource.length + i],
      0x5a,
      reason: 'block guard after byte $i',
    );
    expect(scratchBacking[i], 0xc3, reason: 'scratch guard before byte $i');
    expect(
      scratchBacking[scratchLength + guard + i],
      0x3c,
      reason: 'scratch guard after byte $i',
    );
  }
  return rejected;
}

void main() {
  final codec = Lzo1x();

  group('golden blocks from liblzo2 2.10', () {
    for (final golden in _goldenBlocks) {
      group(golden.name, () {
        test('the fixture stream and the liblzo2 block agree', () {
          // Both the original and the liblzo2-optimized block decode to the
          // same bytes; the fixture is only useful if the optimizer rewrote
          // something.
          expect(_sameBytes(golden.block, golden.optimized), isFalse);
          final fromOriginal = Uint8List(golden.raw.length);
          expect(
            codec.decompressInto(golden.block, fromOriginal),
            golden.raw.length,
          );
          _expectBytes(fromOriginal, golden.raw);
          final fromOptimized = Uint8List(golden.raw.length);
          expect(
            codec.decompressInto(golden.optimized, fromOptimized),
            golden.raw.length,
          );
          _expectBytes(fromOptimized, golden.raw);
        });

        test('optimize reproduces liblzo2 byte for byte', () {
          final block = Uint8List.fromList(golden.block);
          final scratch = Uint8List(golden.raw.length);
          expect(lzo1xOptimize(block, scratch), golden.raw.length);
          _expectBytes(scratch, golden.raw);
          _expectBytes(block, golden.optimized);
          expect(
            block.length,
            golden.block.length,
            reason: 'optimization must not change the block length',
          );
        });

        test('the liblzo2-optimized block decodes in place', () {
          final overhead = golden.raw.length ~/ 16 + 64 + 3;
          final placed = _placeAtEnd(
            golden.optimized,
            golden.raw.length,
            overhead,
          );
          final written = lzo1xDecompressInPlace(
            placed.buffer,
            compressedOffset: placed.offset,
            compressedLength: golden.optimized.length,
            outputLength: golden.raw.length,
          );
          expect(written, golden.raw.length);
          _expectBytes(
            Uint8List.sublistView(placed.buffer, 0, golden.raw.length),
            golden.raw,
          );
        });
      });
    }
  });

  group('lzo1xOptimize contract', () {
    final sample = _goldenBlocks.last;

    test('an empty stream optimizes to zero bytes', () {
      final block = Uint8List.fromList(const [0x11, 0x00, 0x00]);
      final original = Uint8List.fromList(block);
      expect(lzo1xOptimize(block, Uint8List(0)), 0);
      _expectBytes(block, original);
    });

    test('an already optimized block stays valid', () {
      for (final golden in _goldenBlocks) {
        final block = Uint8List.fromList(golden.optimized);
        final scratch = Uint8List(golden.raw.length);
        expect(lzo1xOptimize(block, scratch), golden.raw.length);
        _expectBytes(scratch, golden.raw);
        final decoded = Uint8List(golden.raw.length);
        codec.decompressInto(block, decoded);
        _expectBytes(decoded, golden.raw);
      }
    });

    test('the decoded length is returned, not the scratch capacity', () {
      // A larger scratch buffer must not be reported as fully written.
      final block = Uint8List.fromList(sample.block);
      final scratch = Uint8List(sample.raw.length + 9)
        ..fillRange(sample.raw.length, sample.raw.length + 9, 0x99);
      expect(lzo1xOptimize(block, scratch), sample.raw.length);
      _expectBytes(
        Uint8List.sublistView(scratch, 0, sample.raw.length),
        sample.raw,
      );
      for (var i = sample.raw.length; i < scratch.length; i++) {
        expect(scratch[i], 0x99, reason: 'scratch tail modified at $i');
      }
    });

    test('a too small scratch buffer is an output overrun', () {
      final block = Uint8List.fromList(sample.block);
      expect(
        () => lzo1xOptimize(block, Uint8List(sample.raw.length - 1)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.outputOverrun,
          ),
        ),
      );
    });

    test('blocks shorter than three bytes are rejected', () {
      for (final length in [0, 1, 2]) {
        _mustThrowLzo(
          () => lzo1xOptimize(Uint8List(length), Uint8List(8)),
          'length $length',
        );
      }
    });

    test('overlapping block and scratch buffers are rejected', () {
      final backing = Uint8List(128);
      final matcher = throwsA(
        isA<LzoException>().having(
          (error) => error.code,
          'code',
          LzoErrorCode.invalidArgument,
        ),
      );
      expect(() => lzo1xOptimize(backing, backing), matcher);
      expect(
        () => lzo1xOptimize(
          Uint8List.sublistView(backing, 0, 64),
          Uint8List.sublistView(backing, 32, 96),
        ),
        matcher,
      );
      // Adjacent (non-overlapping) views of one buffer are not an overlap
      // error; the zeroed block is rejected for being malformed instead.
      expect(
        () => lzo1xOptimize(
          Uint8List.sublistView(backing, 0, 32),
          Uint8List.sublistView(backing, 32, 64),
        ),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            isNot(LzoErrorCode.invalidArgument),
          ),
        ),
      );
    });

    test('truncated blocks throw only LzoException', () {
      for (final golden in _goldenBlocks) {
        for (var keep = 0; keep < golden.block.length; keep++) {
          final truncated = Uint8List.fromList(golden.block.sublist(0, keep));
          _mustThrowLzo(
            () => lzo1xOptimize(truncated, Uint8List(golden.raw.length)),
            '${golden.name} truncated to $keep',
          );
        }
      }
    });

    test('trailing bytes after the end-of-stream marker are rejected', () {
      final padded = Uint8List.fromList([...sample.block, 0x00]);
      expect(
        () => lzo1xOptimize(padded, Uint8List(sample.raw.length)),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.inputNotConsumed,
          ),
        ),
      );
    });

    test('a match before the start of the output is rejected', () {
      // One leading literal, then an M2 match with distance 9.
      expect(
        () => lzo1xOptimize(
          Uint8List.fromList(const [0x12, 0x41, 0x40, 0x01]),
          Uint8List(16),
        ),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.lookbehindOverrun,
          ),
        ),
      );
    });

    test(
      'malformed byte soup throws only LzoException and stays in bounds',
      () {
        final random = Random(20240210);
        for (var iteration = 0; iteration < 500; iteration++) {
          final length = random.nextInt(64);
          final block = Uint8List(length);
          for (var i = 0; i < length; i++) {
            block[i] = random.nextInt(3) == 0 ? 0 : random.nextInt(256);
          }
          final capacity = random.nextInt(160);
          // `_optimizeGuarded` lets LzoException through and fails the test on
          // any other error, so a bare call is the whole assertion.
          _optimizeGuarded(block, capacity);
        }
      },
    );

    test('a rejected block never writes outside its buffers', () {
      expect(
        _optimizeGuarded(Uint8List.fromList(const [0x12, 0x41]), 16),
        isTrue,
      );
    });
  });

  group('in-place decode equals out-of-place decode', () {
    for (final kind in ['random', 'text', 'pattern']) {
      for (final size in [1024, 65536, 1048576]) {
        test('$kind / $size bytes', () {
          final raw = _corpus(kind, size, size + kind.length);
          final buffer = Uint8List(Lzo1x.compressBound(size));
          final blockLength = codec.compressInto(raw, buffer);
          final block = Uint8List.sublistView(buffer, 0, blockLength);

          // Baseline: unoptimized block decodes out of place.
          final baseline = Uint8List(size);
          expect(codec.decompressInto(block, baseline), size);
          _expectBytes(baseline, raw);

          // With the lzop buffer layout, the unoptimized stream is in-place
          // safe as well: the n/16 + 64 + 3 overhead always keeps the write
          // cursor behind the read cursor.
          final overhead = size ~/ 16 + 64 + 3;
          final unoptimized = _placeAtEnd(block, size, overhead);
          final unoptimizedWritten = lzo1xDecompressInPlace(
            unoptimized.buffer,
            compressedOffset: unoptimized.offset,
            compressedLength: block.length,
            outputLength: size,
          );
          expect(unoptimizedWritten, size);
          _expectBytes(
            Uint8List.sublistView(unoptimized.buffer, 0, size),
            raw,
            'unoptimized in place',
          );

          // Optimize, then decode out of place and in place.
          final optimized = Uint8List.fromList(block);
          final scratch = Uint8List(size);
          expect(lzo1xOptimize(optimized, scratch), size);
          _expectBytes(scratch, raw);

          final outOfPlace = Uint8List(size);
          expect(codec.decompressInto(optimized, outOfPlace), size);
          _expectBytes(outOfPlace, raw);

          final placed = _placeAtEnd(optimized, size, overhead);
          final written = lzo1xDecompressInPlace(
            placed.buffer,
            compressedOffset: placed.offset,
            compressedLength: optimized.length,
            outputLength: size,
          );
          expect(written, size);
          _expectBytes(
            Uint8List.sublistView(placed.buffer, 0, size),
            outOfPlace,
            'optimized in place',
          );

          // Disjoint layout: output first, compressed block after it.
          final disjoint = Uint8List(size + optimized.length)
            ..setRange(size, size + optimized.length, optimized);
          expect(
            lzo1xDecompressInPlace(
              disjoint,
              compressedOffset: size,
              compressedLength: optimized.length,
              outputLength: size,
            ),
            size,
          );
          _expectBytes(
            Uint8List.sublistView(disjoint, 0, size),
            raw,
            'disjoint layout',
          );
        });
      }
    }

    test('every committed reference vector decodes in place', () {
      final directory = Directory('test/data');
      final blocks =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.lzo'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(blocks, isNotEmpty);
      for (final file in blocks) {
        final rawFile = File(file.path.replaceAll('.lzo', '.raw'));
        // Every block in the corpus has a matching .raw file.
        final raw = rawFile.readAsBytesSync();
        final block = file.readAsBytesSync();
        final name = file.uri.pathSegments.last;

        final optimized = Uint8List.fromList(block);
        final scratch = Uint8List(raw.length);
        expect(lzo1xOptimize(optimized, scratch), raw.length, reason: name);
        _expectBytes(scratch, raw, name);

        final outOfPlace = Uint8List(raw.length);
        expect(
          codec.decompressInto(optimized, outOfPlace),
          raw.length,
          reason: name,
        );
        _expectBytes(outOfPlace, raw, name);

        final overhead = raw.length ~/ 16 + 64 + 3;
        final placed = _placeAtEnd(optimized, raw.length, overhead);
        expect(
          lzo1xDecompressInPlace(
            placed.buffer,
            compressedOffset: placed.offset,
            compressedLength: optimized.length,
            outputLength: raw.length,
          ),
          raw.length,
          reason: name,
        );
        _expectBytes(
          Uint8List.sublistView(placed.buffer, 0, raw.length),
          raw,
          name,
        );
      }
    });
  });

  group('overlap safety contract', () {
    test('a compressed block placed at offset 0 is explicitly rejected', () {
      final raw = _corpus('text', 1024, 31);
      final buffer = Uint8List(Lzo1x.compressBound(raw.length));
      final blockLength = codec.compressInto(raw, buffer);
      final block = Uint8List.fromList(
        Uint8List.sublistView(buffer, 0, blockLength),
      );

      // Sanity check: the stream is perfectly valid out of place.
      final decoded = Uint8List(raw.length);
      expect(codec.decompressInto(block, decoded), raw.length);
      _expectBytes(decoded, raw);

      // With the output at offset 0 and no room before the compressed data,
      // a match would overwrite compressed bytes that have not been read yet.
      final overlapping = Uint8List(raw.length);
      overlapping.setRange(0, block.length, block);
      expect(
        () => lzo1xDecompressInPlace(
          overlapping,
          compressedOffset: 0,
          compressedLength: block.length,
          outputLength: raw.length,
        ),
        throwsA(
          isA<LzoException>()
              .having((error) => error.code, 'code', LzoErrorCode.error)
              .having(
                (error) => error.message,
                'message',
                contains('overwrite unread compressed data'),
              ),
        ),
      );
    });

    test('an unoptimized block in a too tight layout is rejected or safe', () {
      // Smaller overheads may or may not be safe; the decoder must either
      // produce the exact output or reject the layout, never corrupt silently.
      final raw = _corpus('text', 65536, 77);
      final buffer = Uint8List(Lzo1x.compressBound(raw.length));
      final blockLength = codec.compressInto(raw, buffer);
      final block = Uint8List.sublistView(buffer, 0, blockLength);
      for (final overhead in [0, 1, 2, 4, 8, 16]) {
        final placed = _placeAtEnd(block, raw.length, overhead);
        try {
          final written = lzo1xDecompressInPlace(
            placed.buffer,
            compressedOffset: placed.offset,
            compressedLength: block.length,
            outputLength: raw.length,
          );
          expect(written, raw.length);
          _expectBytes(
            Uint8List.sublistView(placed.buffer, 0, raw.length),
            raw,
            'overhead $overhead',
          );
        } on LzoException {
          // Explicit rejection is the documented alternative.
        }
      }
    });

    test('in-place decoding validates its arguments', () {
      final buffer = Uint8List(32);
      final invalid = <void Function()>[
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: -1,
          compressedLength: 3,
          outputLength: 8,
        ),
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 0,
          compressedLength: -1,
          outputLength: 8,
        ),
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 0,
          compressedLength: 3,
          outputLength: -1,
        ),
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 32,
          compressedLength: 3,
          outputLength: 8,
        ),
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 31,
          compressedLength: 3,
          outputLength: 8,
        ),
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 0,
          compressedLength: 3,
          outputLength: 33,
        ),
      ];
      for (final action in invalid) {
        expect(
          action,
          throwsA(
            isA<LzoException>().having(
              (error) => error.code,
              'code',
              LzoErrorCode.invalidArgument,
            ),
          ),
        );
      }
      expect(
        () => lzo1xDecompressInPlace(
          buffer,
          compressedOffset: 0,
          compressedLength: 2,
          outputLength: 8,
        ),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.inputOverrun,
          ),
        ),
      );
    });

    test('truncated and malformed input throws only LzoException', () {
      for (final golden in _goldenBlocks) {
        for (var keep = 0; keep < golden.optimized.length; keep++) {
          final truncated = Uint8List.fromList(
            golden.optimized.sublist(0, keep),
          );
          final overhead = golden.raw.length ~/ 16 + 64 + 3;
          final length = max(golden.raw.length + overhead, truncated.length);
          final buffer = Uint8List(length);
          final offset = length - truncated.length;
          buffer.setRange(offset, length, truncated);
          _mustThrowLzo(
            () => lzo1xDecompressInPlace(
              buffer,
              compressedOffset: offset,
              compressedLength: truncated.length,
              outputLength: golden.raw.length,
            ),
            '${golden.name} truncated to $keep',
          );
        }
      }

      final random = Random(90210);
      for (var iteration = 0; iteration < 300; iteration++) {
        final outputLength = random.nextInt(96);
        final compressedLength = 3 + random.nextInt(48);
        final length = max(outputLength, compressedLength) + random.nextInt(24);
        final buffer = Uint8List(length);
        for (var i = 0; i < length; i++) {
          buffer[i] = random.nextInt(256);
        }
        final offset = length - compressedLength;
        _mustOnlyThrowLzo(
          () => lzo1xDecompressInPlace(
            buffer,
            compressedOffset: offset,
            compressedLength: compressedLength,
            outputLength: outputLength,
          ),
          'iteration $iteration',
        );
      }
    });

    test('trailing bytes after the end-of-stream marker are rejected', () {
      final golden = _goldenBlocks.first;
      final overhead = golden.raw.length ~/ 16 + 64 + 3;
      final block = Uint8List.fromList([...golden.optimized, 0x00]);
      final placed = _placeAtEnd(block, golden.raw.length, overhead);
      expect(
        () => lzo1xDecompressInPlace(
          placed.buffer,
          compressedOffset: placed.offset,
          compressedLength: block.length,
          outputLength: golden.raw.length,
        ),
        throwsA(
          isA<LzoException>().having(
            (error) => error.code,
            'code',
            LzoErrorCode.inputNotConsumed,
          ),
        ),
      );
    });
  });

  group('liblzo2 interop', () {
    final oracle = _Oracle.discover();
    test('liblzo2 decodes the optimized streams', () {
      final work = Directory.systemTemp.createTempSync('lzo_neo_inplace_');
      try {
        // The golden blocks are liblzo2's own optimizer output.
        for (final golden in _goldenBlocks) {
          final decoded = oracle.decompress(
            golden.optimized,
            golden.raw.length,
            work,
          );
          _expectBytes(decoded, golden.raw, golden.name);
        }
        // Streams produced by this package's optimizer.
        for (final kind in ['random', 'text', 'pattern']) {
          for (final size in [1024, 65536]) {
            final raw = _corpus(kind, size, size);
            final buffer = Uint8List(Lzo1x.compressBound(size));
            final blockLength = codec.compressInto(raw, buffer);
            final block = Uint8List.fromList(
              Uint8List.sublistView(buffer, 0, blockLength),
            );
            final scratch = Uint8List(size);
            expect(lzo1xOptimize(block, scratch), size);
            _expectBytes(scratch, raw);
            final decoded = oracle.decompress(block, size, work);
            _expectBytes(decoded, raw, '$kind/$size');
          }
        }
      } finally {
        if (work.existsSync()) work.deleteSync(recursive: true);
      }
    }, skip: oracle.available ? null : 'set LZO_ORACLE to run liblzo2 interop');
  });
}

/// A thin wrapper around the `lzo_oracle` command line tool.
final class _Oracle {
  _Oracle._(this.executable, this.throughWsl);

  final String executable;
  final bool throughWsl;

  bool get available => executable.isNotEmpty;

  static _Oracle discover() {
    final value = Platform.environment['LZO_ORACLE'] ?? '';
    return _Oracle._(value, value.startsWith('/'));
  }

  ProcessResult _run(List<String> args) => throughWsl
      ? Process.runSync('wsl', ['-e', executable, ...args])
      : Process.runSync(executable, args);

  Uint8List decompress(Uint8List source, int outputLength, Directory work) {
    final input = File('${work.path}${Platform.pathSeparator}dart.lzo')
      ..writeAsBytesSync(source);
    final output = File('${work.path}${Platform.pathSeparator}dart.raw');
    final result = _run([
      'decompress',
      'lzo1x',
      throughWsl ? _toWslPath(input.path) : input.path,
      throughWsl ? _toWslPath(output.path) : output.path,
      '$outputLength',
    ]);
    if (result.exitCode != 0) {
      fail(
        'oracle decompress lzo1x failed (${result.exitCode}): '
        '${result.stderr}',
      );
    }
    return output.readAsBytesSync();
  }
}

/// Converts a Windows path to the WSL `/mnt/<drive>/...` form.
String _toWslPath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final match = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (match == null) return normalized;
  return '/mnt/${match.group(1)!.toLowerCase()}/${match.group(2)!}';
}
