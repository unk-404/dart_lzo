/// The LZO1F codec.
///
/// LZO1F is a raw block format: a sequence of literal runs and back-references
/// terminated by an end-of-stream marker. There is no header, so the original
/// length is not stored and decompression needs a destination buffer that is
/// large enough for the whole block.
///
/// Two compressors are provided. [Lzo1fLevel.fast1] follows liblzo2's
/// `lzo1f_1_compress`: a greedy hash-table match finder with a 16 KiB
/// dictionary. [Lzo1fLevel.max] follows `lzo1f_999_compress`: a lazy match
/// finder with a 16 KiB window and hash chains, which trades speed for a
/// better compression ratio. Both emit streams that any LZO1F decompressor
/// accepts.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/copy.dart';
import 'core/errors.dart';

/// Largest distance encoded by an LZO1F M2 match.
const int _m2MaxOffset = 0x0800;

/// Largest distance encoded by an LZO1F M3 match (`0x3FFF`).
const int _m3MaxOffset = 0x3fff;

/// Opcode marker shared by M3 matches and the end-of-stream marker.
const int _m3Marker = 224;

/// Number of entries in the level 1 hash dictionary.
const int _dictionarySize = 1 << 14;

/// Bit mask of a level 1 dictionary index.
const int _dictionaryMask = _dictionarySize - 1;

/// Largest distance addressable by an LZO1F match.
const int _windowSize = 16383;

/// Longest match the level 999 match finder reports.
const int _maxMatchLength = 2048;

/// Number of entries in the level 999 hash table.
const int _hashSize = 1 << 14;

/// Bit mask of a level 999 hash bucket.
const int _hashMask = _hashSize - 1;

/// Upper bound on the number of hash-chain nodes visited per position.
const int _maxChain = 2048;

/// An all-zero buffer used to clear the level 1 dictionary in bulk.
///
/// `Uint32List.fillRange` is a per-element loop; `setRange` from a zero buffer
/// is a bulk copy.
final Uint32List _emptyDictionary = Uint32List(_dictionarySize);

/// The LZO1F compression levels.
enum Lzo1fLevel {
  /// `lzo1f_1_compress`: greedy matching, 16 384 dictionary entries.
  fast1(1),

  /// `lzo1f_999_compress`: lazy matching over a 16 KiB window.
  max(999);

  const Lzo1fLevel(this.number);

  /// The liblzo2 level number.
  final int number;
}

/// A reusable LZO1F compressor/decompressor.
///
/// One instance owns the compression work memory, so reusing an instance
/// avoids re-allocating it for every block. Work memory is only allocated on
/// the first call to [compress] or [compressInto].
///
/// Since the constructor is `const`, the work memory cannot be stored in a
/// mutable instance field: identical `const` codecs are canonicalized, so the
/// buffers are tied to the instance through an [Expando] instead. Instances
/// are not reentrant.
final class Lzo1f extends LzoCodecBase {
  /// Creates a codec using [level] for compression.
  const Lzo1f({this.level = Lzo1fLevel.fast1});

  /// The compression level used by [compress] and [compressInto].
  final Lzo1fLevel level;

  /// Lazily allocated work memory shared by the compression calls of `this`.
  static final Expando<_Lzo1fWork> _workMemory = Expando<_Lzo1fWork>('Lzo1f');

  _Lzo1fWork _work() {
    final cached = _workMemory[this];
    if (cached != null) return cached;
    final work = _Lzo1fWork();
    _workMemory[this] = work;
    return work;
  }

  /// Compresses [source] into [destination] and returns the number of bytes
  /// written.
  ///
  /// The two buffers may overlap. [destination] must have room for the
  /// produced block; otherwise an [LzoException] with
  /// [LzoErrorCode.outputOverrun] is thrown.
  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final work = _work();
    return switch (level) {
      Lzo1fLevel.fast1 => _compressFast(input, destination, work),
      Lzo1fLevel.max => _compressMax(input, destination, work),
    };
  }

  /// Decompresses one raw LZO1F block into [destination] and returns the
  /// number of bytes written.
  ///
  /// Throws an [LzoException] when the block is malformed or [destination] is
  /// too small. No memory is allocated.
  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      _decompress(source, destination);
}

/// Work memory owned by one [Lzo1f] instance.
final class _Lzo1fWork {
  /// Level 1 dictionary: stored positions plus one (zero means empty).
  Uint32List? dictionary;

  /// Level 999 hash bucket heads: stored positions plus one.
  Uint32List? chainHeads;

  /// Level 999 chain links, indexed by `position & (_hashSize - 1)`.
  Uint32List? chainLinks;
}

/// A bounds-checked writer over the caller's destination buffer.
final class _Output {
  _Output(this.buffer);

  /// The caller's destination buffer.
  final Uint8List buffer;

  /// Number of bytes written so far.
  int offset = 0;

  /// Appends [value] as one byte.
  void writeByte(int value) {
    if (offset >= buffer.length) _throwBufferOverrun(offset);
    buffer[offset++] = value;
  }

  /// Appends [count] bytes from [source] starting at [start].
  void writeBytes(Uint8List source, int start, int count) {
    if (count > buffer.length - offset) _throwBufferOverrun(offset);
    buffer.setRange(offset, offset + count, source, start);
    offset += count;
  }

  /// Folds a literal run of [count] bytes into the low two bits of the byte at
  /// `offset - 2`, which is always part of the preceding match token.
  void foldLiterals(int count) {
    if (offset < 2) {
      throwLzo(
        LzoErrorCode.error,
        message: 'literal run has no preceding match token',
      );
    }
    buffer[offset - 2] |= count;
  }

  /// Appends the three-byte LZO1F end-of-stream marker.
  void writeEndOfStream() {
    writeByte(_m3Marker | 1);
    writeByte(0);
    writeByte(0);
  }
}

/// Stores a literal run of [count] bytes from [source] starting at [start].
///
/// Runs shorter than four bytes are folded into the preceding match token; the
/// other encodings are a single count byte or a base-255 extension.
void _storeRun(_Output output, Uint8List source, int start, int count) {
  if (count < 4 && output.offset > 0) {
    output.foldLiterals(count);
  } else if (count <= 31) {
    output.writeByte(count);
  } else {
    output.writeByte(0);
    var extra = count - 31;
    while (extra > 255) {
      extra -= 255;
      output.writeByte(0);
    }
    output.writeByte(extra);
  }
  output.writeBytes(source, start, count);
}

/// Writes one match of [length] bytes at [distance].
///
/// [hasLiterals] records whether a non-empty literal run was stored directly
/// before this match, which enables the compact three-byte form.
void _codeMatch(_Output output, int length, int distance, bool hasLiterals) {
  if (length <= 8 && distance <= _m2MaxOffset) {
    final offset = distance - 1;
    output.writeByte(((length - 2) << 5) | ((offset & 7) << 2));
    output.writeByte(offset >> 3);
  } else if (length == 3 && distance <= 2 * _m2MaxOffset && hasLiterals) {
    final offset = distance - 1 - _m2MaxOffset;
    output.writeByte((offset & 7) << 2);
    output.writeByte(offset >> 3);
  } else {
    if (length <= 33) {
      output.writeByte(_m3Marker | (length - 2));
    } else {
      var extra = length - 33;
      output.writeByte(_m3Marker);
      while (extra > 255) {
        extra -= 255;
        output.writeByte(0);
      }
      output.writeByte(extra);
    }
    output.writeByte((distance & 63) << 2);
    output.writeByte(distance >> 6);
  }
}

/// Computes the primary level 1 dictionary index of the three bytes at
/// [position].
///
/// This is liblzo2's `LZO_HASH_LZO_INCREMENTAL_A` value for the bytes
/// `position .. position + 2`, reduced to 14 bits.
int _dictionaryIndex1(Uint8List source, int position) {
  var value = source[position + 3] << 6;
  value = (value ^ source[position + 2]) << 5;
  value = (value ^ source[position + 1]) << 5;
  value ^= source[position];
  return ((value * 0x21) >> 5) & _dictionaryMask;
}

/// Computes the secondary level 1 dictionary index from a primary one.
int _dictionaryIndex2(int index) => (index & 0x7ff) ^ 0x201f;

/// Whether the three bytes at [a] and [b] are equal.
bool _threeBytesEqual(Uint8List source, int a, int b) =>
    source[a] == source[b] &&
    source[a + 1] == source[b + 1] &&
    source[a + 2] == source[b + 2];

/// Compresses [source] with the greedy `lzo1f_1_compress` match finder.
int _compressFast(Uint8List source, Uint8List destination, _Lzo1fWork work) {
  final length = source.length;
  final output = _Output(destination);

  if (length <= 10) {
    if (length > 0) {
      output.writeByte(length);
      output.writeBytes(source, 0, length);
    }
    output.writeEndOfStream();
    return output.offset;
  }

  final dictionary = work.dictionary ??= Uint32List(_dictionarySize);
  dictionary.setRange(0, _dictionarySize, _emptyDictionary);

  // Matches may only start while nine bytes of lookahead remain: the match
  // extension compares up to six bytes after the three-byte probe.
  final matchLimit = length - 9;
  var position = 1;
  var literalStart = 0;

  while (true) {
    var index = _dictionaryIndex1(source, position);
    var entry = dictionary[index];
    var matchPosition = 0;
    var distance = 0;
    var matched = false;

    if (entry != 0) {
      matchPosition = entry - 1;
      distance = position - matchPosition;
      if (distance > 0 && distance <= _m3MaxOffset) {
        // A four-byte probe filters most candidates without extending.
        if (distance <= _m2MaxOffset ||
            source[matchPosition + 3] == source[position + 3]) {
          matched = _threeBytesEqual(source, matchPosition, position);
        } else {
          index = _dictionaryIndex2(index);
          entry = dictionary[index];
          if (entry != 0) {
            matchPosition = entry - 1;
            distance = position - matchPosition;
            if (distance > 0 &&
                distance <= _m3MaxOffset &&
                (distance <= _m2MaxOffset ||
                    source[matchPosition + 3] == source[position + 3])) {
              matched = _threeBytesEqual(source, matchPosition, position);
            }
          }
        }
      }
    }

    if (!matched) {
      dictionary[index] = position + 1;
      position++;
      if (position >= matchLimit) break;
      continue;
    }

    dictionary[index] = position + 1;

    final literalCount = position - literalStart;
    if (literalCount > 0) {
      _storeRun(output, source, literalStart, literalCount);
      literalStart = position;
    }

    position += 3;
    matchPosition += 3;
    var probe = 0;
    while (probe < 6 && source[matchPosition] == source[position]) {
      probe++;
      matchPosition++;
      position++;
    }
    if (probe == 6) {
      while (position < length && source[matchPosition] == source[position]) {
        matchPosition++;
        position++;
      }
    }

    _codeMatch(output, position - literalStart, distance, literalCount > 0);

    literalStart = position;
    if (position >= matchLimit) break;
  }

  final finalCount = length - literalStart;
  if (finalCount > 0) {
    _storeRun(output, source, literalStart, finalCount);
  }
  output.writeEndOfStream();
  return output.offset;
}

/// Hash-chain match finder used by the level 999 compressor.
///
/// This is the sliding-window search of liblzo2's `lzo_swd.ch`, expressed with
/// absolute input positions: the hash table and the chain links are indexed by
/// `position & (_hashSize - 1)`, which is large enough to keep every position
/// inside the 16 383-byte window addressable.
final class _MatchFinder {
  _MatchFinder(this.source, this.heads, this.links) : length = source.length;

  /// The input being compressed.
  final Uint8List source;

  /// Length of [source].
  final int length;

  /// Hash bucket heads, storing `position + 1` (zero means empty).
  final Uint32List heads;

  /// Per-position chain links, storing `position + 1`.
  final Uint32List links;

  /// Highest position that has been inserted into the chains.
  int _insertedThrough = -1;

  /// Returns the hash of the three bytes at [position].
  int _hash(int position) {
    var value = (source[position] << 5) ^ source[position + 1];
    value = (value << 5) ^ source[position + 2];
    return ((value * 0x9f5f) >> 5) & _hashMask;
  }

  /// Inserts [position] into its hash chain.
  void _insert(int position) {
    if (position + 2 >= length) return;
    final bucket = _hash(position);
    links[position & _hashMask] = heads[bucket];
    heads[bucket] = position + 1;
  }

  /// Inserts every position up to and including [position].
  void insertThrough(int position) {
    while (_insertedThrough < position) {
      _insertedThrough++;
      if (_insertedThrough < length) _insert(_insertedThrough);
    }
  }

  /// Finds the longest match at [position] among the previous 16 383 bytes.
  ///
  /// Ties are broken in favour of the most recent candidate. Matches are
  /// capped at 2 048 bytes, matching liblzo2's `SWD_F`.
  ({int length, int offset}) find(int position) {
    insertThrough(position);

    final available = length - position;
    if (available < 3) return (length: 0, offset: 0);
    final maximum = available < _maxMatchLength ? available : _maxMatchLength;

    var bestLength = 0;
    var bestOffset = 0;
    var node = links[position & _hashMask];
    var chain = 0;
    while (node != 0 && chain < _maxChain) {
      final candidate = node - 1;
      if (position - candidate > _windowSize) break;
      if (source[candidate] == source[position] &&
          source[candidate + 1] == source[position + 1] &&
          source[candidate + 2] == source[position + 2]) {
        var matchLength = 3;
        while (matchLength < maximum &&
            source[candidate + matchLength] == source[position + matchLength]) {
          matchLength++;
        }
        if (matchLength > bestLength) {
          bestLength = matchLength;
          bestOffset = position - candidate;
          if (matchLength >= maximum) break;
        }
      }
      node = links[candidate & _hashMask];
      chain++;
    }
    return (length: bestLength, offset: bestOffset);
  }
}

/// Compresses [source] with the lazy `lzo1f_999_compress` match finder.
int _compressMax(Uint8List source, Uint8List destination, _Lzo1fWork work) {
  final heads = work.chainHeads ??= Uint32List(_hashSize);
  final links = work.chainLinks ??= Uint32List(_hashSize);
  heads.fillRange(0, _hashSize, 0);

  final length = source.length;
  final finder = _MatchFinder(source, heads, links);
  final output = _Output(destination);

  var match = finder.find(0);
  var matchLength = match.length;
  var matchOffset = match.offset;
  var position = 0;
  var literalCount = 0;

  while (position < length) {
    var lazyGain = -1;
    if (matchLength < 3) {
      matchLength = 0;
    } else {
      // Longer literal runs are more expensive to interrupt, so a later match
      // has to be that much better to be worth taking.
      lazyGain = (literalCount == 3 || literalCount == 31) ? 3 : 1;
    }

    final remaining = length - position;
    if (matchLength > 0 && remaining > matchLength) {
      final next = finder.find(position + 1);
      if (matchLength <= 8 &&
          matchOffset <= _m2MaxOffset &&
          next.offset > _m2MaxOffset) {
        lazyGain += 1;
      } else if (next.length <= 8 &&
          next.offset <= _m2MaxOffset &&
          matchOffset > _m2MaxOffset) {
        if (lazyGain > 0) lazyGain--;
      } else if (matchLength == 3 &&
          next.length == 3 &&
          next.offset <= 2 * _m2MaxOffset &&
          matchOffset > _m2MaxOffset) {
        if (lazyGain > 0) lazyGain--;
      }
      if (next.length >= matchLength + lazyGain) {
        literalCount++;
        position++;
        matchLength = next.length;
        matchOffset = next.offset;
        continue;
      }
    }

    if (matchLength == 0) {
      literalCount++;
      position++;
      match = finder.find(position);
      matchLength = match.length;
      matchOffset = match.offset;
    } else {
      final hasLiterals = literalCount > 0;
      if (hasLiterals) {
        _storeRun(output, source, position - literalCount, literalCount);
      }
      _codeMatch(output, matchLength, matchOffset, hasLiterals);
      finder.insertThrough(position + matchLength - 1);
      position += matchLength;
      match = finder.find(position);
      matchLength = match.length;
      matchOffset = match.offset;
      literalCount = 0;
    }
  }

  if (literalCount > 0) {
    _storeRun(output, source, position - literalCount, literalCount);
  }
  output.writeEndOfStream();
  return output.offset;
}

/// Decompresses one raw LZO1F block from [source] into [destination].
///
/// Follows liblzo2 2.10's `lzo1f_d.ch`: a literal run is a count byte (or a
/// zero-terminated base-255 extension) followed by that many bytes; matches are
/// the three-byte form, M2 (3..8 bytes, up to 2 KiB back) or M3 (up to 16 KiB
/// back, up to 33 bytes plus a base-255 extension). A match whose distance is
/// zero is the end-of-stream marker.
int _decompress(Uint8List source, Uint8List destination) {
  final sourceLength = source.length;
  final destinationLength = destination.length;
  var ip = 0;
  var op = 0;

  while (ip < sourceLength) {
    var t = source[ip++];

    if (t <= 31) {
      // A literal run. `t == 0` selects the base-255 length extension.
      if (t == 0) {
        if (ip >= sourceLength) _throwInputOverrun(ip, op);
        while (source[ip] == 0) {
          t += 255;
          ip++;
          if (ip >= sourceLength) _throwInputOverrun(ip, op);
        }
        t += 31 + source[ip++];
      }
      if (t > destinationLength - op) _throwOutputOverrun(ip, op);
      // The token that follows the literals must already be present.
      if (t + 1 > sourceLength - ip) _throwInputOverrun(ip, op);
      copyLiterals(source, ip, destination, op, t);
      ip += t;
      op += t;
      t = source[ip++];
      if (ip >= sourceLength) break;
    }

    while (true) {
      int matchLength;
      int distance;
      if (t < 32) {
        // The compact three-byte match used after a literal run.
        if (ip >= sourceLength) _throwInputOverrun(ip, op);
        distance = 0x801 + ((t >> 2) & 7) + (source[ip] << 3);
        ip++;
        matchLength = 3;
      } else if (t < _m3Marker) {
        // M2: three to eight bytes at a distance of at most 2 KiB.
        if (ip >= sourceLength) _throwInputOverrun(ip, op);
        matchLength = (t >> 5) + 2;
        distance = 1 + ((t >> 2) & 7) + (source[ip] << 3);
        ip++;
      } else {
        // M3: up to 33 bytes at a distance of at most 16 KiB.
        matchLength = t & 31;
        if (matchLength == 0) {
          if (ip >= sourceLength) _throwInputOverrun(ip, op);
          while (source[ip] == 0) {
            matchLength += 255;
            ip++;
            if (ip >= sourceLength) _throwInputOverrun(ip, op);
          }
          matchLength += 31 + source[ip++];
        }
        if (ip + 2 > sourceLength) _throwInputOverrun(ip, op);
        final operand = source[ip] | (source[ip + 1] << 8);
        ip += 2;
        distance = operand >> 2;
        if (distance == 0) {
          // A zero distance is the end-of-stream marker; its length bits are
          // irrelevant.
          if (ip < sourceLength) {
            throwLzo(
              LzoErrorCode.inputNotConsumed,
              message:
                  '${sourceLength - ip} trailing byte(s) after end of stream',
              inputOffset: ip,
              outputOffset: op,
            );
          }
          return op;
        }
        matchLength += 2;
      }

      if (distance > op) _throwLookbehindOverrun(ip, op);
      if (matchLength > destinationLength - op) _throwOutputOverrun(ip, op);
      copyMatch(destination, op, distance, matchLength);
      op += matchLength;

      // The match token's second byte carries a folded literal count in its low
      // two bits.
      final folded = source[ip - 2] & 3;
      if (folded == 0) break;
      if (folded > destinationLength - op) _throwOutputOverrun(ip, op);
      if (folded + 1 > sourceLength - ip) _throwInputOverrun(ip, op);
      copyLiterals(source, ip, destination, op, folded);
      ip += folded;
      op += folded;
      t = source[ip++];
      if (ip >= sourceLength) break;
    }
  }

  throwLzo(
    LzoErrorCode.eofNotFound,
    message: 'end-of-stream marker not found',
    inputOffset: ip,
    outputOffset: op,
  );
}

/// Throws [LzoErrorCode.inputOverrun] at the given position.
Never _throwInputOverrun(int inputOffset, int outputOffset) => throwLzo(
  LzoErrorCode.inputOverrun,
  inputOffset: inputOffset,
  outputOffset: outputOffset,
);

/// Throws [LzoErrorCode.outputOverrun] at the given position.
Never _throwOutputOverrun(int inputOffset, int outputOffset) => throwLzo(
  LzoErrorCode.outputOverrun,
  inputOffset: inputOffset,
  outputOffset: outputOffset,
);

/// Throws [LzoErrorCode.outputOverrun] while writing the compressed block.
Never _throwBufferOverrun(int outputOffset) => throwLzo(
  LzoErrorCode.outputOverrun,
  message: 'destination buffer too small',
  outputOffset: outputOffset,
);

/// Throws [LzoErrorCode.lookbehindOverrun] at the given position.
Never _throwLookbehindOverrun(int inputOffset, int outputOffset) => throwLzo(
  LzoErrorCode.lookbehindOverrun,
  message: 'back-reference before the start of the output',
  inputOffset: inputOffset,
  outputOffset: outputOffset,
);
