/// LZO1X encoder.
///
/// The encoder writes a raw `lzo1x` block: a sequence of literal runs and
/// matches terminated by the end-of-stream marker. Compression levels only
/// change how matches are searched; every level produces a stream that any
/// LZO1X decompressor accepts.
///
/// The match finder follows liblzo2's `lzo1x_1` family: a dictionary indexed by
/// a hash of the four bytes at the current position remembers the most recent
/// occurrence of that value, positions with no match are skipped at an
/// increasing rate, and a found match is extended as far as the input allows.
/// Trailing literal runs of up to three bytes are folded into the low two bits
/// of the preceding match, which is how LZO keeps the per-match overhead low.
library;

import 'dart:typed_data';

import '../core/errors.dart';
import 'level.dart';

/// Largest distance encoded by an M2 match.
const int _m2MaxOffset = 0x0800;

/// Largest distance encoded by an M3 match.
const int _m3MaxOffset = 0x4000;

/// Largest distance encoded by an M4 match.
const int _m4MaxOffset = 0xbfff;

/// Upper bound on the literal-run length that controls the skip stride.
///
/// liblzo2 restarts its dictionary and skip counter every 48 KiB (the largest
/// distance an M4 match can address), so its stride never grows beyond this
/// value. Keeping the same density on longer blocks avoids skipping over
/// matches in partly incompressible data.
const int _maxSkipGap = 0xc000;

/// All-zero source used to clear the caller's dictionary.
///
/// `Uint32List.fillRange` is a slow per-element loop for typed data (tens of
/// microseconds for 16 K entries); `setRange` from a zero buffer is a bulk
/// copy. The buffer covers the largest level (`fast15`, 32 K entries).
final Uint32List _zeroDictionary = Uint32List(1 << 15);

/// Compresses [source] into [destination].
///
/// Returns the number of bytes written. [destination] must be large enough for
/// the produced block; [Lzo1xLevel] selects the match-finding strategy and
/// [dictionary] is the caller-owned work memory of `level.dictionarySize`
/// entries.
///
/// Throws an [LzoException] with [LzoErrorCode.outputOverrun] when
/// [destination] is too small, and with [LzoErrorCode.invalidArgument] when
/// [dictionary] is smaller than the level requires.
int lzo1xCompress(
  Uint8List source,
  Uint8List destination,
  Lzo1xLevel level,
  Uint32List dictionary,
) {
  final sourceLength = source.length;
  final dictionaryBits = level.dictionaryBits;
  final dictionarySize = 1 << dictionaryBits;

  if (dictionary.length < dictionarySize) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'dictionary must hold $dictionarySize entries',
    );
  }
  // The dictionary is caller-owned and may be reused across blocks, so stale
  // entries from an earlier block have to be discarded. A bulk copy is much
  // faster than `fillRange`, which iterates element by element.
  dictionary.setRange(0, dictionarySize, _zeroDictionary);

  var op = 0;
  var literalStart = 0;

  // Unaligned 32-bit reads through `ByteData` are considerably faster than
  // four separate `Uint8List` reads on the Dart VM.
  final data = source.buffer.asByteData(
    source.offsetInBytes,
    source.lengthInBytes,
  );

  // The first token must not be a match: a match needs at least one byte of
  // history, and a leading literal run can be encoded very compactly in the
  // first byte. liblzo2 starts its match search at offset 4 for the same
  // reason; shorter inputs are emitted as a single literal run.
  final lastMatchStart = sourceLength - 4;
  var ip = 4;

  while (ip <= lastMatchStart) {
    final value = data.getUint32(ip, Endian.little);
    final hash =
        ((value * 0x1824429d) >>> (32 - dictionaryBits)) & (dictionarySize - 1);

    final entry = dictionary[hash];
    dictionary[hash] = ip + 1;

    // `entry` is a stored position plus one; zero means "empty slot".
    if (entry != 0 && entry <= ip) {
      final matchPos = entry - 1;
      final distance = ip - matchPos;
      if (distance <= _m4MaxOffset &&
          data.getUint32(matchPos, Endian.little) == value) {
        var length = 4;
        final maxLength = sourceLength - ip;
        // Long matches dominate compressible blocks; compare eight bytes per
        // iteration, then finish with a byte loop at the first differing block.
        while (length + 8 <= maxLength) {
          if (data.getUint32(matchPos + length, Endian.little) !=
                  data.getUint32(ip + length, Endian.little) ||
              data.getUint32(matchPos + length + 4, Endian.little) !=
                  data.getUint32(ip + length + 4, Endian.little)) {
            break;
          }
          length += 8;
        }
        while (length < maxLength &&
            source[matchPos + length] == source[ip + length]) {
          length++;
        }

        op = _emitLiteralRun(
          destination,
          op,
          source,
          literalStart,
          ip - literalStart,
        );
        op = _emitMatch(destination, op, length, distance);

        ip += length;
        literalStart = ip;
        continue;
      }
    }

    // No match here. Skip ahead faster the longer the current literal run has
    // become: highly compressible data finds a match almost immediately, while
    // incompressible data is scanned at a growing stride. The stride is capped
    // at the density liblzo2 uses inside one 48 KiB dictionary window so that
    // long incompressible stretches do not degrade match finding.
    final gap = ip - literalStart;
    ip += 1 + ((gap < _maxSkipGap ? gap : _maxSkipGap) >> 5);
  }

  op = _emitLiteralRun(
    destination,
    op,
    source,
    literalStart,
    sourceLength - literalStart,
  );

  _require(destination, op, 3);
  destination[op++] = 0x11;
  destination[op++] = 0x00;
  destination[op++] = 0x00;
  return op;
}

/// Emits [count] literal bytes from [source] starting at [start].
///
/// A zero-length run is a no-op. When [op] is zero the run is the leading
/// literal run and uses the compact `17 + count` first byte. When [count] is at
/// most three it is folded into the `SS` bits of the preceding match (which is
/// always the last token at that point); otherwise a standalone literal-run
/// opcode is written. Returns the updated output offset.
@pragma('vm:prefer-inline')
int _emitLiteralRun(
  Uint8List destination,
  int op,
  Uint8List source,
  int start,
  int count,
) {
  if (count <= 0) return op;

  if (op == 0 && count <= 238) {
    // The leading literal run has its own compact encoding.
    _require(destination, op, 1 + count);
    destination[op++] = 17 + count;
    destination.setRange(op, op + count, source, start);
    return op + count;
  }

  if (count <= 3) {
    // The preceding token is a match; encode the literals in its SS bits.
    // Matches always end with the SS byte at `op - 2`, either the M2 opcode or
    // the first byte of the M3/M4 distance operand.
    _require(destination, op, count);
    destination[op - 2] |= count;
    destination.setRange(op, op + count, source, start);
    return op + count;
  }

  if (count <= 18) {
    _require(destination, op, 1 + count);
    destination[op++] = count - 3;
  } else {
    // Length extension: length = 18 + 255 * zeros + terminator, with a
    // non-zero terminator in 1..255.
    final extra = count - 18;
    final zeros = (extra - 1) ~/ 255;
    final terminator = extra - zeros * 255;
    _require(destination, op, 2 + zeros + count);
    destination[op++] = 0;
    for (var i = 0; i < zeros; i++) {
      destination[op++] = 0;
    }
    destination[op++] = terminator;
  }

  destination.setRange(op, op + count, source, start);
  return op + count;
}

/// Emits a match of [length] bytes at [distance] (1..0xBFFF).
///
/// The smallest match token is chosen for the distance: M2 up to 2 KiB, M3 up
/// to 16 KiB and M4 up to the LZO1X maximum. Returns the updated output offset.
@pragma('vm:prefer-inline')
int _emitMatch(Uint8List destination, int op, int length, int distance) {
  if (length <= 8 && distance <= _m2MaxOffset) {
    final offset = distance - 1;
    _require(destination, op, 2);
    destination[op++] = ((length - 1) << 5) | ((offset & 7) << 2);
    destination[op++] = offset >> 3;
    return op;
  }

  if (distance <= _m3MaxOffset) {
    final offset = distance - 1;
    if (length <= 33) {
      _require(destination, op, 3);
      destination[op++] = 0x20 | (length - 2);
    } else {
      var extra = length - 33;
      final zeros = (extra - 1) ~/ 255;
      final terminator = extra - zeros * 255;
      _require(destination, op, 4 + zeros);
      destination[op++] = 0x20;
      for (var i = 0; i < zeros; i++) {
        destination[op++] = 0;
      }
      destination[op++] = terminator;
    }
    destination[op++] = (offset << 2) & 0xff;
    destination[op++] = (offset >> 6) & 0xff;
    return op;
  }

  // M4: the distance is stored relative to 0x4000. Distance 0 is reserved for
  // the end-of-stream marker, so every M4 match has a positive offset.
  final offset = distance - 0x4000;
  final high = (offset >> 11) & 8;
  if (length <= 9) {
    _require(destination, op, 3);
    destination[op++] = 0x10 | high | (length - 2);
  } else {
    var extra = length - 9;
    final zeros = (extra - 1) ~/ 255;
    final terminator = extra - zeros * 255;
    _require(destination, op, 4 + zeros);
    destination[op++] = 0x10 | high;
    for (var i = 0; i < zeros; i++) {
      destination[op++] = 0;
    }
    destination[op++] = terminator;
  }
  destination[op++] = (offset << 2) & 0xff;
  destination[op++] = (offset >> 6) & 0xff;
  return op;
}

/// Throws [LzoErrorCode.outputOverrun] unless [count] bytes are available.
@pragma('vm:prefer-inline')
void _require(Uint8List destination, int offset, int count) {
  if (count > destination.length - offset) {
    throwLzo(
      LzoErrorCode.outputOverrun,
      message: 'destination buffer too small',
      outputOffset: offset,
    );
  }
}
