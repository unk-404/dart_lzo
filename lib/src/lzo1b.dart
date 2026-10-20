/// The LZO1B codec.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/copy.dart';
import 'core/errors.dart';
import 'core/limits.dart';

/// The compression levels of the LZO1B family.
///
/// LZO1B blocks are self-describing: the level only selects how hard the
/// compressor looks for matches, never how the output is decoded. Every level
/// below produces a stream that any LZO1B decoder accepts.
enum Lzo1bLevel {
  /// Fastest level: the shallowest match search.
  l1(1, 14, 1),

  /// Fast level with a slightly wider search.
  l2(2, 14, 1),

  /// The first level that tries more than one dictionary candidate.
  l3(3, 14, 2),

  /// Level 4 widens the search again.
  l4(4, 14, 2),

  /// Balanced level.
  l5(5, 14, 4),

  /// Balanced level with a wider search.
  l6(6, 14, 6),

  /// Compression-oriented level.
  l7(7, 14, 8),

  /// Compression-oriented level with a wider search.
  l8(8, 14, 16),

  /// The default, best compression of the 1..9 range.
  l9(9, 14, 24),

  /// The heavier variant with a 16-bit dictionary.
  l99(99, 16, 64),

  /// The heaviest variant with a 16-bit dictionary and a deep search.
  l999(999, 16, 96);

  const Lzo1bLevel(this.number, this.dictionaryBits, this.searchDepth);

  /// The liblzo2 level number.
  final int number;

  /// `log2` of the number of dictionary entries the compressor uses.
  final int dictionaryBits;

  /// Maximum number of dictionary candidates examined per input position.
  final int searchDepth;

  /// Number of entries in the compression dictionary.
  int get dictionarySize => 1 << dictionaryBits;

  /// Dictionary work memory of this level, in bytes.
  ///
  /// The compressor additionally keeps one chain link per input byte.
  int get memCompress => dictionarySize * lzoDictEntrySize;
}

/// A reusable LZO1B compressor/decompressor.
///
/// The stream format is the raw LZO1B block format of liblzo2 2.10: a block
/// carries no header and no original length, so [decompressInto] needs a
/// destination buffer that is large enough for the whole output. A block ends
/// with the end-of-stream marker, which is also the only record of its length.
///
/// One instance owns the compression work memory, so reusing an instance
/// avoids re-allocating it for every block. Instances are not reentrant and
/// must not be shared between isolates.
final class Lzo1b extends LzoCodecBase {
  /// Creates a codec using [level] for compression.
  const Lzo1b({this.level = Lzo1bLevel.l9});

  /// The compression level used by [compress] and [compressInto].
  final Lzo1bLevel level;

  /// Lazily allocated work memory; an [Expando] keeps the constructor `const`.
  static final Expando<_Lzo1bWork> _workMemory = Expando<_Lzo1bWork>(
    'Lzo1b.work',
  );

  /// Compresses [source] into [destination] and returns the number of bytes
  /// written.
  ///
  /// The two buffers may overlap. [destination] must have room for the
  /// produced block; otherwise an [LzoException] with
  /// [LzoErrorCode.outputOverrun] is thrown.
  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final work = _workMemory[this] ??= _Lzo1bWork(level.dictionaryBits);
    return _compress(input, destination, level, work);
  }

  /// Decompresses one raw LZO1B block into [destination] and returns the number
  /// of bytes written.
  ///
  /// Throws an [LzoException] when the block is malformed or [destination] is
  /// too small. No memory is allocated.
  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      _decompress(source, destination);
}

/// Compression work memory: a dictionary head table plus chain links.
final class _Lzo1bWork {
  _Lzo1bWork(this.dictionaryBits) : head = Uint32List(1 << dictionaryBits);

  /// `log2` of the head table size; fixed for the owning codec.
  final int dictionaryBits;

  /// Dictionary bucket heads, stored as `position + 1` (`0` means empty).
  final Uint32List head;

  Uint32List? _previous;

  /// Chain links, stored as `position + 1` (`0` terminates a chain).
  Uint32List previousFor(int length) {
    final existing = _previous;
    if (existing != null && existing.length >= length) return existing;
    final grown = Uint32List(length);
    _previous = grown;
    return grown;
  }
}

const int _r0Min = 32;
const int _r0Fast = 280;
const int _m2MinLen = 3;
const int _m2MaxLen = 8;
const int _m2MaxOffset = 8192;
const int _m3MinLen = 4;
const int _m3MaxLen = 34;
const int _m3MaxOffset = 0xFFFF;
const int _m4MinLen = 35;
const int _m4Marker = 0x20;
const int _m3MarkerBits = 0x1F;
const int _niceLength = 258;
const int _endMarker = 0x21;

/// Compresses [source] with the LZO1B stream format.
int _compress(
  Uint8List source,
  Uint8List destination,
  Lzo1bLevel level,
  _Lzo1bWork work,
) {
  final length = source.length;
  final writer = _Writer(destination);
  if (length == 0) {
    writer
      ..writeByte(_endMarker)
      ..writeByte(0)
      ..writeByte(0);
    return writer.offset;
  }

  final head = work.head;
  head.setRange(0, head.length, _zeroTable);
  final previous = work.previousFor(length);
  final mask = head.length - 1;
  final searchDepth = level.searchDepth;

  var ip = 0;
  var literalStart = 0;

  while (ip + _m2MinLen <= length) {
    final hash = _hashAt(source, ip, mask);
    final candidate = head[hash];
    previous[ip] = candidate;
    head[hash] = ip + 1;

    var bestLength = 0;
    var bestOffset = 0;
    var entry = candidate;
    var budget = searchDepth;
    final remaining = length - ip;
    while (entry != 0 && budget-- > 0) {
      final position = entry - 1;
      final distance = ip - position;
      if (distance > _m3MaxOffset) break;
      if (bestLength >= remaining) break;
      // Reject cheaply unless this candidate can at least tie the best match.
      if (source[position] != source[ip] ||
          source[position + bestLength] != source[ip + bestLength]) {
        entry = previous[position];
        continue;
      }
      var matched = 1;
      while (matched < remaining &&
          source[position + matched] == source[ip + matched]) {
        matched++;
      }
      if (matched > bestLength) {
        bestLength = matched;
        bestOffset = distance;
        if (matched >= _niceLength) break;
      }
      entry = previous[position];
    }

    // A three-byte match is only encodable as M2; M3 needs four bytes.
    final encodable =
        bestLength >= _m2MinLen &&
        (bestLength >= _m3MinLen || bestOffset <= _m2MaxOffset);
    if (!encodable) {
      ip++;
      continue;
    }

    if (ip > literalStart) {
      writer.writeRun(source, literalStart, ip - literalStart);
    }
    // Remember the phrases that start inside the match, except its first byte
    // (already inserted above) and positions too close to the end to hash.
    for (
      var position = ip + 1;
      position < ip + bestLength && position + _m2MinLen <= length;
      position++
    ) {
      final positionHash = _hashAt(source, position, mask);
      previous[position] = head[positionHash];
      head[positionHash] = position + 1;
    }
    writer.writeMatch(bestOffset, bestLength);
    ip += bestLength;
    literalStart = ip;
  }

  if (literalStart < length) {
    writer.writeRun(source, literalStart, length - literalStart);
  }
  writer
    ..writeByte(_endMarker)
    ..writeByte(0)
    ..writeByte(0);
  return writer.offset;
}

/// The bucket index of the three-byte phrase at [index].
int _hashAt(Uint8List source, int index, int mask) {
  final phrase =
      (source[index] << 16) | (source[index + 1] << 8) | source[index + 2];
  return (((phrase * 0x9E3779B1) & 0xFFFFFFFF) >> 14) & mask;
}

/// Decompresses one raw LZO1B block from [source] into [destination].
int _decompress(Uint8List source, Uint8List destination) {
  final sourceLength = source.length;
  final destinationLength = destination.length;

  if (sourceLength < 3) {
    throwLzo(
      LzoErrorCode.inputOverrun,
      message: 'compressed block shorter than 3 bytes',
      inputOffset: sourceLength,
    );
  }

  var ip = 0;
  var op = 0;

  while (true) {
    if (ip >= sourceLength) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'missing end-of-stream marker',
        inputOffset: ip,
        outputOffset: op,
      );
    }

    var t = source[ip++];
    if (t < _r0Min) {
      // A literal run. Marker 0 selects the long form.
      var literalLength = t;
      var longRun = false;
      if (literalLength == 0) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        final extension = source[ip++];
        if (extension >= _r0Fast - _r0Min) {
          final power = extension - (_r0Fast - _r0Min);
          literalLength = power == 0 ? _r0Fast : 256 << power;
          longRun = true;
        } else {
          literalLength = extension + _r0Min;
        }
      }
      if (literalLength > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (literalLength > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, literalLength);
      ip += literalLength;
      op += literalLength;

      // A long R0 run is followed directly by the next marker. Only a short
      // literal run may be followed by R1 opcodes: a three-byte match whose
      // high offset byte is followed by one literal.
      if (longRun) continue;
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'missing end-of-stream marker',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      t = source[ip++];
      while (t < _r0Min) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        final distance = 1 + t + (source[ip++] << 5);
        if (distance > op) {
          throwLzo(
            LzoErrorCode.lookbehindOverrun,
            message: 'back-reference before the start of the output',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        if (op + 4 > destinationLength) {
          throwLzo(
            LzoErrorCode.outputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        copyMatch(destination, op, distance, _m2MinLen);
        op += _m2MinLen;
        destination[op++] = source[ip++];

        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            message: 'missing end-of-stream marker',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        t = source[ip++];
      }
    }

    // A match. M2 carries its length in the marker's top bits; M3 and M4 use a
    // 16-bit offset with a marker length field, where zero selects M4.
    if (t >= 0x40) {
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final distance = 1 + (t & 0x1F) + (source[ip++] << 5);
      final matchLength = (t >> 5) + 1;
      if (distance > op) {
        throwLzo(
          LzoErrorCode.lookbehindOverrun,
          message: 'back-reference before the start of the output',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      if (matchLength > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyMatch(destination, op, distance, matchLength);
      op += matchLength;
      continue;
    }

    var matchLength = t & _m3MarkerBits;
    if (matchLength == 0) {
      // M4: a zero-terminated run of 255-byte length extensions.
      while (true) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        if (source[ip] != 0) break;
        matchLength += 255;
        ip++;
      }
      matchLength += (_m4MinLen - _m3MinLen) + source[ip++];
    }
    if (ip + 2 > sourceLength) {
      throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
    }
    final distance = source[ip] | (source[ip + 1] << 8);
    ip += 2;
    if (distance == 0) {
      if (ip != sourceLength) {
        throwLzo(
          LzoErrorCode.inputNotConsumed,
          message: '${sourceLength - ip} trailing byte(s) after end of stream',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      return op;
    }
    matchLength += _m3MinLen - 1;
    if (distance > op) {
      throwLzo(
        LzoErrorCode.lookbehindOverrun,
        message: 'back-reference before the start of the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    if (matchLength > destinationLength - op) {
      throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
    }
    copyMatch(destination, op, distance, matchLength);
    op += matchLength;
  }
}

/// Bounds-checked writer for one compressed block.
final class _Writer {
  _Writer(this._destination);

  final Uint8List _destination;
  int offset = 0;

  void writeByte(int value) {
    if (offset >= _destination.length) {
      throwLzo(LzoErrorCode.outputOverrun, outputOffset: offset);
    }
    _destination[offset++] = value;
  }

  void writeBytes(Uint8List source, int start, int count) {
    if (count > _destination.length - offset) {
      throwLzo(LzoErrorCode.outputOverrun, outputOffset: offset);
    }
    _destination.setRange(offset, offset + count, source, start);
    offset += count;
  }

  /// Writes a literal run using the LZO1B run encoding.
  void writeRun(Uint8List source, int start, int count) {
    var position = start;
    var remaining = count;

    // Long R0 runs: 512, 1024, ..., 32768 bytes per two-byte header.
    if (remaining >= 512) {
      var bits = 6;
      var size = 32768;
      while (remaining >= size) {
        remaining -= size;
        writeByte(0);
        writeByte((_r0Fast - _r0Min) + 7);
        writeBytes(source, position, size);
        position += size;
      }
      size >>= 1;
      do {
        if (remaining >= size) {
          remaining -= size;
          writeByte(0);
          writeByte((_r0Fast - _r0Min) + bits);
          writeBytes(source, position, size);
          position += size;
        }
        size >>= 1;
        bits--;
      } while (bits > 0);
    }

    // The largest non-special R0 run.
    while (remaining >= _r0Fast) {
      remaining -= _r0Fast;
      writeByte(0);
      writeByte(_r0Fast - _r0Min);
      writeBytes(source, position, _r0Fast);
      position += _r0Fast;
    }

    if (remaining >= _r0Min) {
      writeByte(0);
      writeByte(remaining - _r0Min);
      writeBytes(source, position, remaining);
    } else if (remaining > 0) {
      writeByte(remaining);
      writeBytes(source, position, remaining);
    }
  }

  /// Writes one M2, M3 or M4 match.
  void writeMatch(int distance, int length) {
    if (length <= _m2MaxLen && distance <= _m2MaxOffset) {
      final encoded = distance - 1;
      writeByte(((length - 1) << 5) | (encoded & 0x1F));
      writeByte(encoded >> 5);
      return;
    }
    final encoded = distance;
    if (length <= _m3MaxLen) {
      writeByte(_m4Marker | (length - (_m3MinLen - 1)));
      writeByte(encoded & 0xFF);
      writeByte(encoded >> 8);
      return;
    }
    writeByte(_m4Marker);
    var extension = length - (_m4MinLen - 1);
    while (extension > 255) {
      extension -= 255;
      writeByte(0);
    }
    writeByte(extension);
    writeByte(encoded & 0xFF);
    writeByte(encoded >> 8);
  }
}

/// Shared all-zero source for bulk table clears.
final Uint32List _zeroTable = Uint32List(1 << 16);
