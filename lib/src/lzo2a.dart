/// The LZO2A codec.
///
/// LZO2A is the bit-oriented LZO2 format. Its grammar is defined by liblzo2
/// 2.10's `src/lzo2a_9x.c` (compressor) and `src/lzo2a_d.ch` (decompressor):
///
/// ```text
/// bit 0        a literal byte follows
/// bits 10      an M1 match: 2 length bits, then one offset byte
/// bits 11      one marker byte and one offset-high byte; a zero marker
///              selects an M3 match (length in extension bytes), otherwise an
///              M2 match (length = 2 + marker high bits)
/// ```
///
/// Flags are packed least-significant-bit first; payload bytes always follow
/// the current flag byte. The M4 escape for distances above 8191 is disabled
/// in the reference configuration (`SWD_N` is 8191), and so is not emitted.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/copy.dart';
import 'core/errors.dart';
import 'core/limits.dart';

/// Compression levels of the LZO2A codec.
///
/// The reference library only ships `lzo2a_999_compress`, the "max" level.
enum Lzo2aLevel {
  /// `lzo2a_999_compress`.
  max(999);

  const Lzo2aLevel(this.number);

  /// The liblzo2 level number.
  final int number;
}

/// Mutable work memory owned by one [Lzo2a] instance.
///
/// The codec objects are immutable (their constructors are `const`), so the
/// scratch buffers live in an [Expando] keyed by the codec instance. Constant
/// instances are canonicalised, so `const Lzo2a()` shares one set of buffers,
/// while separate instances get separate buffers. Expando storage is local to
/// the isolate, which matches the codec's non-reentrant contract.
final class _Lzo2aWork {
  Uint32List? head2;
  Uint32List? head3;
  Uint32List? chain;
}

final Expando<_Lzo2aWork> _workCache = Expando<_Lzo2aWork>('Lzo2a work memory');

/// A reusable LZO2A compressor/decompressor.
///
/// One instance owns the compression work memory, so reusing an instance
/// avoids re-allocating it for every block. Instances are not reentrant and
/// must not be shared between isolates.
///
/// LZO2A is a raw block codec: compressed data carries no header and no
/// original length, so [decompressInto] needs a destination buffer that is
/// large enough for the whole output.
final class Lzo2a extends LzoCodecBase {
  /// Creates a codec using the only LZO2A level, [Lzo2aLevel.max].
  const Lzo2a({this.level = Lzo2aLevel.max});

  /// The compression level used by [compress] and [compressInto].
  final Lzo2aLevel level;

  /// The worst-case compressed size for [sourceLength] input bytes.
  ///
  /// LZO2A pays one flag bit for every literal byte, so its worst case is
  /// larger than the `n + n / 16 + 64 + 3` figure shared by the byte-oriented
  /// families: the incompressible bound is `n + n / 8 + 3`. This override
  /// returns the larger of the two so that [compress] can never overrun its
  /// own buffer.
  @override
  int compressBound(int sourceLength) {
    final standard = lzoCompressBound(sourceLength);
    final worstCase = sourceLength + ((sourceLength + 7) >> 3) + 3;
    return standard > worstCase ? standard : worstCase;
  }

  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final work = _workCache[this] ??= _Lzo2aWork();
    final head2 = work.head2 ??= Uint32List(1 << 16);
    final head3 = work.head3 ??= Uint32List(_hashBuckets);
    var chain = work.chain;
    if (chain == null || chain.length < input.length) {
      chain = work.chain = Uint32List(input.length);
    }
    return _lzo2aCompress(input, destination, head2, head3, chain);
  }

  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      _lzo2aDecompress(source, destination);
}

// ---------------------------------------------------------------------------
// Format constants (`src/config2a.h`, SWD_N = 8191, SWD_F = 2048).
// ---------------------------------------------------------------------------

/// Largest distance a stream can address (`SWD_N`).
const int _maxOffset = 8191;

/// Largest match length the reference compressor emits (`SWD_F`).
const int _maxMatch = 2048;

/// Number of buckets of the three-byte hash (`SWD_HSIZE`).
const int _hashBuckets = 16384;

/// Hash-chain probe budget.
const int _maxChain = 512;

// ---------------------------------------------------------------------------
// Decoder (`src/lzo2a_d.ch`).
// ---------------------------------------------------------------------------

/// Decompresses one raw LZO2A block from [source] into [destination].
///
/// Returns the number of bytes written. A valid block always ends with the
/// end-of-stream marker (distance zero); a block without it is rejected with
/// [LzoErrorCode.eofNotFound].
///
/// Throws an [LzoException] when the input is truncated, malformed, or would
/// write past the end of [destination]. No memory beyond the two buffers is
/// allocated.
int _lzo2aDecompress(Uint8List source, Uint8List destination) {
  final sourceLength = source.length;
  final destinationLength = destination.length;
  var ip = 0;
  var op = 0;
  var bits = 0;
  var bitCount = 0;
  var endOfStream = false;

  while (ip < sourceLength) {
    if (bitCount < 1) {
      bits |= source[ip++] << bitCount;
      bitCount += 8;
    }
    if ((bits & 1) == 0) {
      // A literal.
      bits >>= 1;
      bitCount--;
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'truncated literal',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      if (op >= destinationLength) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      destination[op++] = source[ip++];
      continue;
    }
    bits >>= 1;
    bitCount--;

    if (bitCount < 1) {
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'truncated match flag',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      bits |= source[ip++] << bitCount;
      bitCount += 8;
    }
    if ((bits & 1) == 0) {
      // An M1 match: length 2..5, distance 1..256.
      bits >>= 1;
      bitCount--;
      if (bitCount < 2) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            message: 'truncated M1 length',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        bits |= source[ip++] << bitCount;
        bitCount += 8;
      }
      final length = 2 + (bits & 3);
      bits >>= 2;
      bitCount -= 2;
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'truncated M1 offset',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      final distance = 1 + source[ip++];
      if (distance > op) {
        throwLzo(
          LzoErrorCode.lookbehindOverrun,
          message: 'back-reference before the start of the output',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      if (length > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyMatch(destination, op, distance, length);
      op += length;
      continue;
    }
    bits >>= 1;
    bitCount--;

    // An M2/M3 match: two payload bytes follow the flag byte.
    if (sourceLength - ip < 2) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'truncated match marker',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    final low = source[ip++];
    final high = source[ip++];
    var distance = (low & 31) | (high << 5);
    var length = low >> 5;

    if (length == 0) {
      // An M3 match: length 9 plus extension bytes.
      length = 9;
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'truncated M3 length',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      while (source[ip] == 0) {
        length += 255;
        ip++;
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            message: 'truncated M3 length',
            inputOffset: ip,
            outputOffset: op,
          );
        }
      }
      length += source[ip++];
    } else {
      if (distance == 0) {
        // The end-of-stream marker.
        endOfStream = true;
        break;
      }
      length += 2;
    }

    if (distance == 0 || distance > op) {
      throwLzo(
        LzoErrorCode.lookbehindOverrun,
        message: 'back-reference before the start of the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    if (length > destinationLength - op) {
      throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
    }
    copyMatch(destination, op, distance, length);
    op += length;
  }

  if (!endOfStream) {
    throwLzo(
      LzoErrorCode.eofNotFound,
      message: 'missing end-of-stream marker',
      inputOffset: ip,
      outputOffset: op,
    );
  }
  if (ip < sourceLength) {
    throwLzo(
      LzoErrorCode.inputNotConsumed,
      message: '${sourceLength - ip} trailing byte(s) after end of stream',
      inputOffset: ip,
      outputOffset: op,
    );
  }
  return op;
}

// ---------------------------------------------------------------------------
// Encoder (`src/lzo2a_9x.c`).
// ---------------------------------------------------------------------------

/// A bounds-checked bit writer.
///
/// The layout matches the reference `putbits` macros: the pending flag bits are
/// accumulated least-significant-bit first in the byte reserved by [bitp], and
/// payload bytes are appended after it.
final class _BitWriter {
  _BitWriter(this.destination);

  final Uint8List destination;
  int offset = 0;

  int _bits = 0;
  int _bitCount = 0;
  int _bitPosition = -1;

  void _reserveByte() {
    if (offset >= destination.length) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'compressed block does not fit the destination buffer',
        outputOffset: offset,
      );
    }
    _bitPosition = offset++;
  }

  /// Appends [count] bits (at most two) of [value], LSB first.
  void putBits(int count, int value) {
    if (_bitCount == 0) _reserveByte();
    _bits |= (value & ((1 << count) - 1)) << _bitCount;
    _bitCount += count;
    if (_bitCount >= 8) {
      destination[_bitPosition] = _bits & 0xff;
      _bits >>= 8;
      _bitCount -= 8;
      if (_bitCount > 0) _reserveByte();
    }
  }

  void putBit(int value) => putBits(1, value);

  void putByte(int value) {
    if (offset >= destination.length) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'compressed block does not fit the destination buffer',
        outputOffset: offset,
      );
    }
    destination[offset++] = value;
  }

  /// Flushes the pending partial flag byte.
  void finish() {
    if (_bitCount > 0) {
      destination[_bitPosition] = _bits & ((1 << _bitCount) - 1);
      _bitCount = 0;
      _bits = 0;
    }
  }
}

/// A hash-chain match finder over the input.
///
/// Two dictionaries are kept, mirroring the reference sliding window: a
/// two-byte table for the short M1 matches (distance at most 256) and a
/// three-byte table with chains for everything longer.
final class _MatchFinder {
  _MatchFinder(this.source, this.head2, this.head3, this.chain);

  final Uint8List source;
  final Uint32List head2;
  final Uint32List head3;
  final Uint32List chain;
  var _inserted = 0;

  void reset() {
    head2.setRange(0, head2.length, _zeroTable);
    head3.setRange(0, head3.length, _zeroTable);
    _inserted = 0;
  }

  /// Inserts every position below [target] into both tables.
  void insertUpTo(int target) {
    final sourceLength = source.length;
    while (_inserted < target) {
      final position = _inserted++;
      if (position + 1 < sourceLength) {
        head2[source[position] | (source[position + 1] << 8)] = position + 1;
      }
      if (position + 2 < sourceLength) {
        final value =
            (((source[position] << 5) ^ source[position + 1]) << 5) ^
            source[position + 2];
        final index = ((0x9f5f * value) >> 5) & (_hashBuckets - 1);
        chain[position] = head3[index];
        head3[index] = position + 1;
      }
    }
  }

  /// Returns the best match at [position] as `(length, offset)`.
  (int, int) find(int position) {
    final sourceLength = source.length;
    final remaining = sourceLength - position;
    final limit = remaining < _maxMatch ? remaining : _maxMatch;
    var bestLength = 0;
    var bestOffset = 0;

    if (limit >= 3) {
      final value =
          (((source[position] << 5) ^ source[position + 1]) << 5) ^
          source[position + 2];
      final index = ((0x9f5f * value) >> 5) & (_hashBuckets - 1);
      final b0 = source[position];
      final b1 = source[position + 1];
      final b2 = source[position + 2];
      var candidate = head3[index] - 1;
      var probes = _maxChain;
      while (candidate >= 0 && probes-- > 0) {
        final offset = position - candidate;
        if (offset > _maxOffset) break;
        if (source[candidate] == b0 &&
            source[candidate + 1] == b1 &&
            source[candidate + 2] == b2) {
          var length = 3;
          while (length < limit &&
              source[candidate + length] == source[position + length]) {
            length++;
          }
          if (length > bestLength) {
            bestLength = length;
            bestOffset = offset;
            if (length >= limit) break;
          }
        }
        candidate = chain[candidate] - 1;
      }
    }

    if (limit >= 2) {
      final candidate =
          head2[source[position] | (source[position + 1] << 8)] - 1;
      if (candidate >= 0) {
        final offset = position - candidate;
        if (offset >= 1 && offset <= 256) {
          var length = 2;
          while (length < limit &&
              source[candidate + length] == source[position + length]) {
            length++;
          }
          if (length > bestLength) {
            bestLength = length;
            bestOffset = offset;
          }
        }
      }
    }

    return (bestLength, bestOffset);
  }
}

/// Compresses [source] into [destination], returning the number of bytes
/// written.
int _lzo2aCompress(
  Uint8List source,
  Uint8List destination,
  Uint32List head2,
  Uint32List head3,
  Uint32List chain,
) {
  final sourceLength = source.length;
  final writer = _BitWriter(destination);

  if (sourceLength > 0) {
    final finder = _MatchFinder(source, head2, head3, chain)..reset();
    var position = 0;
    finder.insertUpTo(0);
    var match = finder.find(0);

    while (position < sourceLength) {
      var matchLength = match.$1;
      var matchOffset = match.$2;
      var gain = 0;
      var extraGain = 0;

      final isM1 = matchLength >= 2 && matchLength <= 5 && matchOffset <= 256;
      if (isM1) {
        gain = 2;
        extraGain = 2;
      } else if (matchLength >= 10) {
        gain = 1;
      } else if (matchLength >= 3) {
        gain = 1;
      } else {
        matchLength = 0;
      }

      // Lazy matching, with the reference's M1 preference adjustment.
      if (gain > 0 && sourceLength - position > matchLength) {
        final literal = source[position];
        finder.insertUpTo(position + 1);
        final next = finder.find(position + 1);
        final nextIsM1 = next.$1 >= 2 && next.$1 <= 5 && next.$2 <= 256;
        if (isM1 && !nextIsM1) gain += extraGain;
        if (nextIsM1) gain -= 1;
        if (gain < 1) gain = 1;
        if (next.$1 >= matchLength + gain) {
          writer.putBit(0);
          writer.putByte(literal);
          position++;
          match = next;
          continue;
        }
      }

      if (matchLength == 0) {
        writer.putBit(0);
        writer.putByte(source[position]);
        position++;
        finder.insertUpTo(position);
        match = finder.find(position);
        continue;
      }

      if (isM1) {
        // M1: two flag bits, two length bits, one offset byte.
        writer.putBit(1);
        writer.putBit(0);
        writer.putBits(2, matchLength - 2);
        writer.putByte(matchOffset - 1);
      } else if (matchLength <= 9) {
        // M2: length 3..9 in the top bits of the marker byte.
        writer.putBit(1);
        writer.putBit(1);
        writer.putByte(((matchLength - 2) << 5) | (matchOffset & 31));
        writer.putByte(matchOffset >> 5);
      } else {
        // M3: marker byte with zero length bits, then extension bytes.
        writer.putBit(1);
        writer.putBit(1);
        writer.putByte(matchOffset & 31);
        writer.putByte(matchOffset >> 5);
        var rest = matchLength - 9;
        while (rest > 255) {
          rest -= 255;
          writer.putByte(0);
        }
        writer.putByte(rest);
      }

      position += matchLength;
      finder.insertUpTo(position);
      match = finder.find(position);
    }
  }

  // The end-of-stream marker: two flag bits, marker byte 0x20, offset 0x00.
  writer.putBit(1);
  writer.putBit(1);
  writer.putByte(1 << 5);
  writer.putByte(0);
  writer.finish();
  return writer.offset;
}

/// Shared all-zero source for bulk table clears.
final Uint32List _zeroTable = Uint32List(1 << 16);
