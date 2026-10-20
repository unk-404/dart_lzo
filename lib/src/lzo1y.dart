/// The LZO1Y codec.
///
/// LZO1Y is a variant of LZO1X with a wider two-byte match: an M2 token stores
/// lengths 3..14 and distances up to 1 KiB (`M2_MAX_LEN = 14`,
/// `M2_MAX_OFFSET = 0x400`). The remaining instructions (M1, M3, M4 and the
/// end-of-stream marker) keep the LZO1X layout.
///
/// The class offers the two liblzo2 levels: [Lzo1yLevel.fast1] (`lzo1y_1`) and
/// [Lzo1yLevel.max] (`lzo1y_999`, quality 1..9 and an optional preset
/// dictionary).
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/errors.dart';
import 'lzo1x/encoder_9x.dart';

/// Compression levels of the LZO1Y family.
enum Lzo1yLevel {
  /// `lzo1y_1_compress`: single-pass greedy match finder.
  fast1(1, 16384, 32768),

  /// `lzo1y_999_compress`: lazy search with a 458 752 byte workspace.
  max(999, 16384, Lzo999Workspace.memCompress);

  const Lzo1yLevel(this.number, this.dictionarySize, this.memCompress);

  /// The liblzo2 level number.
  final int number;

  /// Number of entries in the LZO1Y-1 hash dictionary.
  final int dictionarySize;

  /// Work memory required by this level, in bytes.
  final int memCompress;
}

/// A reusable LZO1Y compressor/decompressor.
///
/// Instances are not reentrant and must not be shared between isolates. Work
/// memory is allocated lazily on the first compression.
final class Lzo1y extends LzoCodecBase {
  /// Creates a codec using [level] for compression.
  ///
  /// [quality] only applies to [Lzo1yLevel.max] and must be in 1..9.
  /// [dictionary] is the optional preset dictionary of the 999 level; it is
  /// also used by [decompressInto] to expand blocks that reference a
  /// dictionary.
  const Lzo1y({
    this.level = Lzo1yLevel.fast1,
    this.quality = 9,
    this.dictionary,
  });

  /// The compression level used by [compressInto].
  final Lzo1yLevel level;

  /// The 999 search effort (1 = fastest, 9 = strongest).
  final int quality;

  /// The optional preset dictionary.
  final Uint8List? dictionary;

  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final work = _workspaces[this] ??= _Lzo1yWorkspace();
    switch (level) {
      case Lzo1yLevel.fast1:
        if (dictionary != null) {
          throwLzo(
            LzoErrorCode.invalidArgument,
            message: 'a preset dictionary requires Lzo1yLevel.max',
          );
        }
        return lzo1yCompress1(input, destination, work.dictionary);
      case Lzo1yLevel.max:
        final nine = work.nine ??= Lzo999Workspace();
        return lzo1yCompress999(
          input,
          destination,
          quality: quality,
          dictionary: dictionary,
          workspace: nine,
        );
    }
  }

  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      lzo1yDecompress(source, destination, dictionary: dictionary);
}

final class _Lzo1yWorkspace {
  /// Hash dictionary for `lzo1y_1`, storing `position + 1` (0 = empty).
  final Uint32List dictionary = Uint32List(1 << 14);

  /// Work memory for `lzo1y_999`, allocated on first use.
  Lzo999Workspace? nine;
}

/// One workspace per codec instance, allocated lazily.
///
/// The codec has a `const` constructor, so the mutable work memory cannot be a
/// field; an [Expando] keeps it out of the const value while still tying it to
/// the instance lifetime. Canonicalized `const` codecs share one workspace,
/// which is safe because a codec is documented as non-reentrant.
final Expando<_Lzo1yWorkspace> _workspaces = Expando<_Lzo1yWorkspace>(
  'lzo1y.workspace',
);

/// All-zero source used to clear the LZO1Y-1 dictionary in bulk.
final Uint32List _zeroDictionary = Uint32List(1 << 14);

/// Largest distance encodable by an LZO1Y M2 match (`M2_MAX_OFFSET`).
const int _m2MaxOffset = 0x0400;

/// Largest distance encodable by an LZO1Y M3 match.
const int _m3MaxOffset = 0x4000;

/// Largest distance encodable by an LZO1Y M4 match.
const int _m4MaxOffset = 0xbfff;

/// Compresses an LZO1Y block with the `lzo1y_1` algorithm.
///
/// The match finder is the single-pass greedy dictionary search of
/// `lzo1x_1`/`lzo1y_1`: a 16 384-entry hash of four-byte values remembers the
/// most recent occurrence of each value, and matches are only accepted when
/// all four bytes agree. Returns the number of bytes written.
///
/// Throws [LzoException] with [LzoErrorCode.outputOverrun] when [destination]
/// is too small.
int lzo1yCompress1(
  Uint8List source,
  Uint8List destination,
  Uint32List dictionary,
) {
  if (dictionary.length < (1 << 14)) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'dictionary must hold ${1 << 14} entries',
    );
  }
  dictionary.setRange(0, 1 << 14, _zeroDictionary);

  final input = snapshotIfOverlapping(source, destination);
  final sourceLength = input.length;
  var op = 0;
  var literalStart = 0;

  // The first token must not be a match, and a four-byte match needs four
  // bytes of history. liblzo2 starts its search at offset 4.
  final lastMatchStart = sourceLength - 4;
  var ip = 4;

  while (ip <= lastMatchStart) {
    final b0 = input[ip];
    final b1 = input[ip + 1];
    final b2 = input[ip + 2];
    final b3 = input[ip + 3];
    final value = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    final hash = ((value * 0x1824429d) >>> (32 - 14)) & ((1 << 14) - 1);

    final entry = dictionary[hash];
    dictionary[hash] = ip + 1;

    // `entry` is a stored position plus one; zero means the hash slot is empty.
    if (entry != 0 && entry <= ip) {
      final matchPosition = entry - 1;
      final distance = ip - matchPosition;
      if (distance <= _m4MaxOffset &&
          input[matchPosition] == b0 &&
          input[matchPosition + 1] == b1 &&
          input[matchPosition + 2] == b2 &&
          input[matchPosition + 3] == b3) {
        var length = 4;
        final maxLength = sourceLength - ip;
        while (length < maxLength &&
            input[matchPosition + length] == input[ip + length]) {
          length++;
        }

        op = _emitLiteralRun(
          destination,
          op,
          input,
          literalStart,
          ip - literalStart,
        );
        op = _emitMatch(destination, op, length, distance);

        ip += length;
        literalStart = ip;
        continue;
      }
    }

    // No match here: skip ahead faster the longer the literal run has become.
    final gap = ip - literalStart;
    ip += 1 + ((gap < 0xc000 ? gap : 0xc000) >> 5);
  }

  op = _emitLiteralRun(
    destination,
    op,
    input,
    literalStart,
    sourceLength - literalStart,
  );
  _require(destination, op, 3);
  destination[op++] = 0x11;
  destination[op++] = 0x00;
  destination[op++] = 0x00;
  return op;
}

/// Decompresses one raw LZO1Y block from [source] into [destination].
///
/// [dictionary], when given, supplies the bytes before the output when the
/// block was produced by the 999 level with a preset dictionary. Only the
/// final 49 151 dictionary bytes are visible.
///
/// Throws an [LzoException] when the input is truncated, malformed, or would
/// write past the end of [destination].
int lzo1yDecompress(
  Uint8List source,
  Uint8List destination, {
  Uint8List? dictionary,
}) => lzoFamilyDecompress(
  source,
  destination,
  family: LzoFamily.lzo1y,
  dictionary: dictionary,
);

/// Emits [count] literal bytes from [source] starting at [start].
///
/// A zero-length run is a no-op. Runs of 1..3 bytes are folded into the low two
/// bits of the preceding match token; longer runs use the standalone literal
/// instruction, with the compact `17 + count` form for the leading run.
int _emitLiteralRun(
  Uint8List destination,
  int op,
  Uint8List source,
  int start,
  int count,
) {
  if (count <= 0) return op;

  if (op == 0 && count <= 238) {
    _require(destination, op, 1 + count);
    destination[op++] = 17 + count;
    destination.setRange(op, op + count, source, start);
    return op + count;
  }

  if (count <= 3) {
    // The preceding token is a match; its first byte (op - 2) has two free
    // low bits in LZO1Y.
    _require(destination, op, count);
    destination[op - 2] |= count;
    destination.setRange(op, op + count, source, start);
    return op + count;
  }

  if (count <= 18) {
    _require(destination, op, 1 + count);
    destination[op++] = count - 3;
  } else {
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
/// The smallest token that can express the distance is chosen: M2 up to 1 KiB,
/// M3 up to 16 KiB and M4 up to the LZO maximum. LZO1Y's M2 token stores
/// lengths up to 14.
int _emitMatch(Uint8List destination, int op, int length, int distance) {
  if (length <= 14 && distance <= _m2MaxOffset) {
    final offset = distance - 1;
    _require(destination, op, 2);
    destination[op++] = ((length + 1) << 4) | ((offset & 3) << 2);
    destination[op++] = offset >> 2;
    return op;
  }

  if (distance <= _m3MaxOffset) {
    final offset = distance - 1;
    if (length <= 33) {
      _require(destination, op, 3);
      destination[op++] = 0x20 | (length - 2);
    } else {
      final extra = length - 33;
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

  // M4: distance relative to 0x4000; zero is reserved for the stream end.
  final offset = distance - 0x4000;
  final high = (offset >> 11) & 8;
  if (length <= 9) {
    _require(destination, op, 3);
    destination[op++] = 0x10 | high | (length - 2);
  } else {
    final extra = length - 9;
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
void _require(Uint8List destination, int offset, int count) {
  if (count > destination.length - offset) {
    throwLzo(
      LzoErrorCode.outputOverrun,
      message: 'destination buffer too small',
      outputOffset: offset,
    );
  }
}
