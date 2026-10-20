/// The LZO1 codec.
///
/// LZO1 is the original LZO block format. Its grammar is defined by liblzo2
/// 2.10's `src/lzo1.c`:
///
/// ```text
/// 76543210
/// --------
/// 00000000   a long literal run ('R0' run), length in the next byte
/// 000rrrrr   a short literal run of `r` bytes
/// mmmooooo   a short match (length = 2 + m, low offset bits in `o`)
/// 111ooooo   a long match, length in a third byte
/// ```
///
/// The two compression levels only change how matches are searched: both write
/// the same stream grammar, and every stream is decodable by `lzo1_decompress`.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/copy.dart';
import 'core/errors.dart';

/// Compression levels of the LZO1 codec.
enum Lzo1Level {
  /// `lzo1_compress`: lzo1-5/1, a single-candidate dictionary.
  fast(1),

  /// `lzo1_99_compress`: lazy matching over a hash chain.
  max(99);

  const Lzo1Level(this.number);

  /// The liblzo2 level number.
  final int number;
}

/// Mutable work memory owned by one [Lzo1] instance.
///
/// The codec objects are immutable (their constructors are `const`), so the
/// scratch buffers live in an [Expando] keyed by the codec instance. Constant
/// instances are canonicalised, so `const Lzo1()` shares one set of buffers,
/// while separate instances get separate buffers. Expando storage is local to
/// the isolate, which matches the codec's non-reentrant contract.
final class _Lzo1Work {
  Uint32List? dictionary;
  Uint32List? heads;
  Uint32List? chain;
}

final Expando<_Lzo1Work> _workCache = Expando<_Lzo1Work>('Lzo1 work memory');

/// A reusable LZO1 compressor/decompressor.
///
/// One instance owns the compression work memory, so reusing an instance
/// avoids re-allocating it for every block. Instances are not reentrant and
/// must not be shared between isolates.
///
/// LZO1 is a raw block codec: compressed data carries no header and no
/// original length, so [decompressInto] needs a destination buffer that is
/// large enough for the whole output.
final class Lzo1 extends LzoCodecBase {
  /// Creates a codec using [level] for compression.
  const Lzo1({this.level = Lzo1Level.fast});

  /// The compression level used by [compress] and [compressInto].
  final Lzo1Level level;

  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    if (input.isEmpty) return 0;

    final work = _workCache[this] ??= _Lzo1Work();
    if (level == Lzo1Level.fast) {
      final dictionary = work.dictionary ??= Uint32List(_dictionarySize);
      return _compressFast(input, destination, dictionary);
    }

    final heads = work.heads ??= Uint32List(_maxHeads);
    var chain = work.chain;
    if (chain == null || chain.length < input.length) {
      chain = work.chain = Uint32List(input.length);
    }
    return _compressMax(input, destination, heads, chain);
  }

  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      _lzo1Decompress(source, destination);
}

// ---------------------------------------------------------------------------
// Format constants (`src/lzo1.c`, RBITS = 5).
// ---------------------------------------------------------------------------

/// Minimum length of an R0 literal run, `RSIZE`.
const int _r0Min = 32;

/// R0 run length that is always encoded with two bytes, `R0MAX & ~7`.
const int _r0Fast = 280;

/// Maximum distance of a match, `1 << (8 + OBITS)`.
const int _maxOffset = 8192;

/// Maximum length of a short match, coded in two bytes.
const int _maxShortMatch = 8;

/// Maximum length of a match, coded in three bytes.
const int _maxLongMatch = 264;

/// Number of short-match length bits (`MBITS = 8 - OBITS`).
const int _lengthBits = 5;

/// Offset mask of a short match (`OMASK`).
const int _offsetMask = 31;

/// Marker bits of a long match (`((MSIZE - 1) << OBITS)`).
const int _longMatchMarker = 0xe0;

/// Number of dictionary entries (`DBITS = 8 + RBITS`).
const int _dictionarySize = 8192;

/// Dictionary mask.
const int _dictionaryMask = _dictionarySize - 1;

/// Hash-chain bucket count used by [Lzo1Level.max].
const int _maxHeads = 1 << 14;

/// Hash-chain probe budget used by [Lzo1Level.max].
const int _maxChain = 256;

/// All-zero source used to clear the caller's dictionary.
final Uint32List _zeroDictionary = Uint32List(_dictionarySize);

// ---------------------------------------------------------------------------
// Decoder (`src/lzo1.c`, `lzo1_decompress`).
// ---------------------------------------------------------------------------

/// Decompresses one raw LZO1 block from [source] into [destination].
///
/// Returns the number of bytes written. LZO1 has no end-of-stream marker: the
/// block simply ends after its last instruction and must not contain trailing
/// bytes.
///
/// Throws an [LzoException] when the input is truncated, malformed, or would
/// write past the end of [destination]. No memory beyond the two buffers is
/// allocated.
int _lzo1Decompress(Uint8List source, Uint8List destination) {
  final sourceLength = source.length;
  final destinationLength = destination.length;
  var ip = 0;
  var op = 0;

  while (ip < sourceLength) {
    final token = source[ip++];

    if (token < _r0Min) {
      // A literal run.
      var length = token;
      if (length == 0) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            message: 'missing R0 length byte',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        final value = source[ip++];
        if (value >= _r0Fast - _r0Min) {
          // A long R0 run: code 0 means R0FAST bytes, otherwise 256 << code.
          final code = value - (_r0Fast - _r0Min);
          length = code == 0 ? _r0Fast : 256 << code;
          if (length > sourceLength - ip) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          if (length > destinationLength - op) {
            throwLzo(
              LzoErrorCode.outputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          copyLiterals(source, ip, destination, op, length);
          ip += length;
          op += length;
          continue;
        }
        length = value + _r0Min;
      }
      if (length > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (length > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, length);
      ip += length;
      op += length;
      continue;
    }

    // A match: the distance is `1 + low bits + (high byte << OBITS)`.
    if (ip >= sourceLength) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'missing match offset byte',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    final lowOffset = token & _offsetMask;
    final highOffset = source[ip++];
    final distance = 1 + lowOffset + (highOffset << _lengthBits);

    int length;
    if (token >= _longMatchMarker) {
      // All length bits set: a long match with a third byte.
      if (ip >= sourceLength) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'missing long match length byte',
          inputOffset: ip,
          outputOffset: op,
        );
      }
      length = 2 + 7 + source[ip++];
    } else {
      length = 2 + (token >> _lengthBits);
    }

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
  }

  return op;
}

// ---------------------------------------------------------------------------
// Fast encoder: a faithful port of `do_compress` in `src/lzo1.c` at CLEVEL 1.
// ---------------------------------------------------------------------------

/// A bounds-checked byte writer.
final class _Sink {
  _Sink(this.destination);

  final Uint8List destination;
  int offset = 0;

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

  void putBytes(Uint8List source, int start, int length) {
    if (length > destination.length - offset) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'compressed block does not fit the destination buffer',
        outputOffset: offset,
      );
    }
    destination.setRange(offset, offset + length, source, start);
    offset += length;
  }

  /// Clears the high bits of an already-written byte (`op[-2] &= mask`).
  void maskByte(int back, int mask) {
    destination[offset - back] &= mask;
  }
}

/// Codes a literal run exactly like `store_run` in `src/lzo1.c`.
void _storeRun(_Sink sink, Uint8List source, int start, int length) {
  var remaining = length;
  var position = start;

  if (remaining >= 512) {
    var runBits = 7; // 256 << 7 == 32768
    do {
      while (remaining >= (256 << runBits)) {
        remaining -= 256 << runBits;
        sink.putByte(0);
        sink.putByte((_r0Fast - _r0Min) + runBits);
        sink.putBytes(source, position, 256 << runBits);
        position += 256 << runBits;
      }
    } while (--runBits > 0);
  }
  while (remaining >= _r0Fast) {
    remaining -= _r0Fast;
    sink.putByte(0);
    sink.putByte(_r0Fast - _r0Min);
    sink.putBytes(source, position, _r0Fast);
    position += _r0Fast;
  }
  if (remaining >= _r0Min) {
    sink.putByte(0);
    sink.putByte(remaining - _r0Min);
    sink.putBytes(source, position, remaining);
  } else if (remaining > 0) {
    sink.putByte(remaining);
    sink.putBytes(source, position, remaining);
  }
}

/// Hash of the three bytes at [position], `D_INDEX1` (`0x21` multiplier).
///
/// `D_INDEX1` folds the bytes in the `DX2` order — last byte first.
int _probeHash(Uint8List source, int position) {
  final value =
      (((source[position + 2] << 5) ^ source[position + 1]) << 5) ^
      source[position];
  return ((0x21 * value) >> 5) & _dictionaryMask;
}

/// Hash of the three bytes at [position], `DINDEX` (`0x9f5f` multiplier).
///
/// `DVAL_FIRST` folds the bytes in the `DX2` order with the first byte last,
/// so this hash is not interchangeable with [_probeHash].
int _insertHash(Uint8List source, int position) {
  final value =
      (((source[position] << 5) ^ source[position + 1]) << 5) ^
      source[position + 2];
  return ((0x9f5f * value) >> 5) & _dictionaryMask;
}

/// Compresses [source] with the LZO1-5/1 algorithm of `src/lzo1.c`.
///
/// [dictionary] holds `_dictionarySize` entries of position + 1; zero means an
/// empty slot.
int _compressFast(
  Uint8List source,
  Uint8List destination,
  Uint32List dictionary,
) {
  final sourceLength = source.length;
  final sink = _Sink(destination);

  // Blocks that cannot hold one long match plus the hash look-ahead are coded
  // as one literal run, exactly like the liblzo2 entry point.
  const minimumBlock = 9 + 3 + 1; // MIN_MATCH_LONG + DVAL_LEN + 1
  if (sourceLength <= minimumBlock) {
    _storeRun(sink, source, 0, sourceLength);
    return sink.offset;
  }

  dictionary.setRange(0, _dictionarySize, _zeroDictionary);

  // The first phrase is always inserted, at the index produced by DINDEX.
  dictionary[_insertHash(source, 0)] = 1;

  final searchEnd = sourceLength - 12; // in_len - DVAL_LEN - MIN_MATCH_LONG
  final matchEnd = sourceLength - 3; // in_len - DVAL_LEN
  var ip = 1;
  var literalStart = 0;

  while (true) {
    // Probe the first candidate, then — only when that candidate is a valid
    // phrased but mismatching entry — the mirrored bucket, exactly like the
    // reference compressor.
    var index = _probeHash(source, ip);
    var matchPosition = -1;
    final first = dictionary[index];
    if (first != 0) {
      final candidate = first - 1;
      final offset = ip - candidate;
      if (offset <= _maxOffset) {
        if (source[candidate] == source[ip] &&
            source[candidate + 1] == source[ip + 1] &&
            source[candidate + 2] == source[ip + 2]) {
          matchPosition = candidate;
        } else {
          index ^= _dictionaryMask;
          final second = dictionary[index];
          if (second != 0) {
            final mirrored = second - 1;
            if (ip - mirrored <= _maxOffset &&
                source[mirrored] == source[ip] &&
                source[mirrored + 1] == source[ip + 1] &&
                source[mirrored + 2] == source[ip + 2]) {
              matchPosition = mirrored;
            }
          }
        }
      }
    }

    if (matchPosition < 0) {
      dictionary[index] = ip + 1;
      ip++;
      if (ip >= searchEnd) break;
      continue;
    }

    dictionary[index] = ip + 1;
    final distance = ip - matchPosition;

    // 1) Store the pending literal run.
    if (ip > literalStart) {
      _storeRun(sink, source, literalStart, ip - literalStart);
    }
    final matchStart = ip;

    // 2) Try to reach a long match: six further bytes decide the class.
    var matched = 0;
    while (matched < 6 &&
        source[matchPosition + 3 + matched] ==
            source[matchStart + 3 + matched]) {
      matched++;
    }

    if (matched < 6) {
      final matchLength = 3 + matched;
      final encodedOffset = distance - 1;
      sink.putByte(
        ((matchLength - 2) << _lengthBits) | (encodedOffset & _offsetMask),
      );
      sink.putByte(encodedOffset >> _lengthBits);
      ip = matchStart + matchLength;
    } else {
      final encodedOffset = distance - 1;
      var position = matchStart + 9;
      final limit = matchEnd - position <= 255 ? matchEnd : position + 255;
      var candidate = matchPosition + 9;
      while (position < limit && source[candidate] == source[position]) {
        position++;
        candidate++;
      }
      final matchLength = position - matchStart;
      sink.putByte(0xe0 | (encodedOffset & _offsetMask));
      sink.putByte(encodedOffset >> _lengthBits);
      sink.putByte(matchLength - 9);
      ip = position;
    }

    literalStart = ip;
    if (ip >= searchEnd) break;
  }

  if (literalStart < sourceLength) {
    _storeRun(sink, source, literalStart, sourceLength - literalStart);
  }
  return sink.offset;
}

// ---------------------------------------------------------------------------
// Max encoder: lazy matching over a hash chain (level 99).
// ---------------------------------------------------------------------------

/// A single-candidate hash chain over the input.
final class _Chain {
  _Chain(this.source, this.heads, this.chain);

  final Uint8List source;
  final Uint32List heads;
  final Uint32List chain;
  var _inserted = 0;

  void reset() {
    heads.setRange(0, heads.length, _zeroTable);
    _inserted = 0;
  }

  /// Inserts every position below [target] into the chain.
  void insertUpTo(int target) {
    final sourceLength = source.length;
    while (_inserted < target) {
      final position = _inserted++;
      if (position + 2 >= sourceLength) continue;
      final value =
          (((source[position] << 5) ^ source[position + 1]) << 5) ^
          source[position + 2];
      final index = ((0x9f5f * value) >> 5) & (_maxHeads - 1);
      chain[position] = heads[index];
      heads[index] = position + 1;
    }
  }

  /// Returns the longest match at [position] as `(length, offset)`.
  (int, int) find(int position) {
    final sourceLength = source.length;
    final remaining = sourceLength - position;
    final limit = remaining < _maxLongMatch ? remaining : _maxLongMatch;
    var bestLength = 0;
    var bestOffset = 0;

    if (limit >= 3) {
      final value =
          (((source[position] << 5) ^ source[position + 1]) << 5) ^
          source[position + 2];
      final index = ((0x9f5f * value) >> 5) & (_maxHeads - 1);
      final b0 = source[position];
      final b1 = source[position + 1];
      final b2 = source[position + 2];
      var candidate = heads[index] - 1;
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
    return (bestLength, bestOffset);
  }
}

/// Compresses [source] with the lazy hash-chain encoder of level 99.
int _compressMax(
  Uint8List source,
  Uint8List destination,
  Uint32List heads,
  Uint32List chain,
) {
  final sourceLength = source.length;
  final sink = _Sink(destination);

  const minimumBlock = 9 + 3 + 1;
  if (sourceLength <= minimumBlock) {
    _storeRun(sink, source, 0, sourceLength);
    return sink.offset;
  }

  final finder = _Chain(source, heads, chain)..reset();
  var position = 0;
  var literalStart = 0;
  finder.insertUpTo(0);
  var match = finder.find(0);

  while (position < sourceLength) {
    var matchLength = match.$1;
    var matchOffset = match.$2;
    if (matchLength < 3) matchLength = 0;

    // Lazy matching: prefer a longer match one byte later.
    if (matchLength > 0 && position + 1 < sourceLength) {
      finder.insertUpTo(position + 1);
      final next = finder.find(position + 1);
      final nextLength = next.$1 >= 3 ? next.$1 : 0;
      final gain = matchLength <= _maxShortMatch ? 2 : 1;
      if (nextLength >= matchLength + gain) {
        position++;
        match = next;
        continue;
      }
    }

    if (matchLength == 0) {
      position++;
      finder.insertUpTo(position);
      match = finder.find(position);
      continue;
    }

    if (position > literalStart) {
      _storeRun(sink, source, literalStart, position - literalStart);
    }
    final encodedOffset = matchOffset - 1;
    if (matchLength <= _maxShortMatch) {
      sink.putByte(
        ((matchLength - 2) << _lengthBits) | (encodedOffset & _offsetMask),
      );
      sink.putByte(encodedOffset >> _lengthBits);
    } else {
      sink.putByte(0xe0 | (encodedOffset & _offsetMask));
      sink.putByte(encodedOffset >> _lengthBits);
      sink.putByte(matchLength - 9);
    }
    position += matchLength;
    literalStart = position;
    finder.insertUpTo(position);
    match = finder.find(position);
  }

  if (literalStart < sourceLength) {
    _storeRun(sink, source, literalStart, sourceLength - literalStart);
  }
  return sink.offset;
}

/// Shared all-zero source for bulk table clears.
final Uint32List _zeroTable = Uint32List(1 << 16);
