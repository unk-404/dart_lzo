/// LZO-RLE: the Linux kernel's LZO bitstream version 1.
///
/// Version 1 keeps the LZO1X instruction grammar but adds a version marker
/// (`0x11 0x01`) and turns one otherwise valid M4 match (distance `0xBFFF`)
/// into a zero-run instruction. It is backwards compatible in one direction:
/// a version 1 decoder reads version 0 streams, but a version 0 decoder does
/// not read version 1 streams.
library;

import 'dart:typed_data';

import '../core/codec.dart';
import '../core/copy.dart';
import '../core/errors.dart';

/// Smallest zero run encoded by the RLE instruction.
const int _minZeroRun = 4;

/// Largest zero run encoded by a single RLE instruction (`2047 + 4`).
const int _maxZeroRun = 2047 + _minZeroRun;

/// LZO1X maximum M4 distance in bitstream version 1 (`0xBFFF` is the RLE
/// marker, so normal matches stop one byte earlier).
const int _m4MaxOffsetV1 = 0xbffe;

const int _m2MaxOffset = 0x0800;
const int _m3MaxOffset = 0x4000;
const int _maxSkipGap = 0xc000;

final Uint32List _zeroDictionary = Uint32List(1 << 15);
final Uint8List _zeroRunBuffer = Uint8List(_maxZeroRun);

/// LZO-RLE codec (Linux kernel bitstream version 1).
///
/// It uses the same fast LZO1X-1 match finder as [Lzo1x] and adds zero-run
/// encoding, which is what the kernel uses for zram. The decoder also accepts
/// plain version 0 LZO1X streams.
final class Lzo1xRle extends LzoCodecBase {
  Lzo1xRle();

  Uint32List? _dictionary;

  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final dictionary = _dictionary ??= Uint32List(1 << 14);
    return _compress(input, destination, dictionary);
  }

  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      _decompress(source, destination);
}

int _compress(Uint8List source, Uint8List destination, Uint32List dictionary) {
  var op = 0;
  _require(destination, op, 2);
  destination[op++] = 0x11;
  destination[op++] = 0x01;

  final length = source.length;
  if (length < 4) {
    return _finish(source, destination, op, 0, length, stateOffset: -1);
  }

  final dictionarySize = dictionary.length;
  dictionary.setRange(0, dictionarySize, _zeroDictionary);

  var literalStart = 0;
  var stateOffset = -1;
  var ip = 4;
  final lastMatchStart = length - 4;

  while (ip <= lastMatchStart) {
    // A four-byte zero window is always a zero run in version 1. The run can
    // be at most MAX_ZERO_RUN_LENGTH bytes per instruction.
    if (source[ip] == 0 &&
        source[ip + 1] == 0 &&
        source[ip + 2] == 0 &&
        source[ip + 3] == 0) {
      var runEnd = ip + 4;
      final limit = ip + _maxZeroRun < length ? ip + _maxZeroRun : length;
      while (runEnd < limit && source[runEnd] == 0) {
        runEnd++;
      }
      var run = runEnd - ip;
      if (run > _maxZeroRun) run = _maxZeroRun;

      op = _emitLiterals(
        destination,
        op,
        source,
        literalStart,
        ip - literalStart,
        stateOffset,
      );
      op = _emitZeroRun(destination, op, run);
      stateOffset = op - 3;
      ip += run;
      literalStart = ip;
      continue;
    }

    final value =
        source[ip] |
        (source[ip + 1] << 8) |
        (source[ip + 2] << 16) |
        (source[ip + 3] << 24);
    final hash = ((value * 0x1824429d) >>> (32 - 14)) & (dictionarySize - 1);
    final entry = dictionary[hash];
    dictionary[hash] = ip + 1;

    if (entry != 0 && entry <= ip) {
      final matchPosition = entry - 1;
      final distance = ip - matchPosition;
      if (distance <= _m4MaxOffsetV1 &&
          source[matchPosition] == source[ip] &&
          source[matchPosition + 1] == source[ip + 1] &&
          source[matchPosition + 2] == source[ip + 2] &&
          source[matchPosition + 3] == source[ip + 3]) {
        var matchLength = 4;
        final maximum = length - ip;
        while (matchLength < maximum &&
            source[matchPosition + matchLength] == source[ip + matchLength]) {
          matchLength++;
        }

        // Under lzo-rle, a long match whose distance and length collide with
        // the zero-run encoding must be shortened to 260 bytes.
        if ((distance & 0x803f) == 0x803f &&
            matchLength >= 261 &&
            matchLength <= 264) {
          matchLength = 260;
        }

        op = _emitLiterals(
          destination,
          op,
          source,
          literalStart,
          ip - literalStart,
          stateOffset,
        );
        op = _emitMatch(destination, op, matchLength, distance);
        stateOffset = op - 2;
        ip += matchLength;
        literalStart = ip;
        continue;
      }
    }

    final gap = ip - literalStart;
    ip += 1 + ((gap < _maxSkipGap ? gap : _maxSkipGap) >> 5);
  }

  return _finish(
    source,
    destination,
    op,
    literalStart,
    length - literalStart,
    stateOffset: stateOffset,
  );
}

int _finish(
  Uint8List source,
  Uint8List destination,
  int op,
  int literalStart,
  int literalCount, {
  required int stateOffset,
}) {
  op = _emitLiterals(
    destination,
    op,
    source,
    literalStart,
    literalCount,
    stateOffset,
  );
  _require(destination, op, 3);
  destination[op++] = 0x11;
  destination[op++] = 0x00;
  destination[op++] = 0x00;
  return op;
}

int _emitLiterals(
  Uint8List destination,
  int op,
  Uint8List source,
  int start,
  int count,
  int stateOffset,
) {
  if (count <= 0) return op;

  if (stateOffset < 0) {
    // First instruction after the version marker: the compact leading-literal
    // form is still available (the kernel's `op == data_start` branch).
    if (count <= 238) {
      _require(destination, op, 1 + count);
      destination[op++] = 17 + count;
      destination.setRange(op, op + count, source, start);
      return op + count;
    }
  } else if (count <= 3) {
    _require(destination, op, count);
    destination[stateOffset] |= count;
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

int _emitZeroRun(Uint8List destination, int op, int runLength) {
  final encoded = runLength - _minZeroRun;
  final word = ((encoded << 21) | 0xfffc18 | (encoded & 0x7)) & 0xffffffff;
  _require(destination, op, 4);
  destination[op++] = word & 0xff;
  destination[op++] = (word >> 8) & 0xff;
  destination[op++] = (word >> 16) & 0xff;
  destination[op++] = (word >> 24) & 0xff;
  return op;
}

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

int _decompress(Uint8List source, Uint8List destination) {
  final sourceLength = source.length;
  final destinationLength = destination.length;
  if (sourceLength < 3) {
    throwLzo(LzoErrorCode.inputOverrun, inputOffset: sourceLength);
  }

  var ip = 0;
  var version = 0;
  if (sourceLength >= 5 && source[0] == 0x11) {
    version = source[1];
    ip = 2;
    if (version > 1) {
      throwLzo(
        LzoErrorCode.error,
        message: 'unsupported LZO-RLE bitstream version $version',
        inputOffset: 1,
      );
    }
  }

  var op = 0;
  var state = 0;

  final first = source[ip];
  if (first > 17) {
    ip++;
    final count = first - 17;
    if (count > sourceLength - ip) {
      throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
    }
    if (count > destinationLength) {
      throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
    }
    copyLiterals(source, ip, destination, 0, count);
    ip += count;
    op = count;
    state = count < 4 ? count : 4;
  }

  while (true) {
    if (ip >= sourceLength) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'missing end-of-stream marker',
        inputOffset: ip,
      );
    }
    var t = source[ip++];
    int distance;
    int length;
    int nextState;

    if (t < 16 && state == 0) {
      var literalLength = t;
      if (literalLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
          }
          final next = source[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        literalLength = 15 + extra;
      }
      literalLength += 3;
      if (literalLength > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      if (literalLength > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, literalLength);
      ip += literalLength;
      op += literalLength;
      state = 4;
      continue;
    }

    if (t < 16) {
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      if (state == 4) {
        distance = 2049 + (t >> 2) + (source[ip] << 2);
        length = 3;
      } else {
        distance = 1 + (t >> 2) + (source[ip] << 2);
        length = 2;
      }
      ip++;
      nextState = t & 3;
    } else if (t >= 64) {
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      distance = 1 + ((t >> 2) & 7) + (source[ip] << 3);
      length = (t >> 5) + 1;
      ip++;
      nextState = t & 3;
    } else if (t >= 32) {
      var matchLength = t & 31;
      if (matchLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
          }
          final next = source[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        matchLength = 31 + extra;
      }
      length = matchLength + 2;
      if (ip + 2 > sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      final operand = source[ip] | (source[ip + 1] << 8);
      ip += 2;
      distance = 1 + (operand >> 2);
      nextState = operand & 3;
    } else {
      if (ip + 2 > sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      final probe = source[ip] | (source[ip + 1] << 8);
      final rleRun =
          version > 0 && (probe & 0xfffc) == 0xfffc && (t & 0xf8) == 0x18;
      if (rleRun) {
        if (ip + 3 > sourceLength) {
          throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
        }
        final run = ((t & 7) | (source[ip + 2] << 3)) + _minZeroRun;
        ip += 3;
        if (run > destinationLength - op) {
          throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
        }
        destination.setRange(op, op + run, _zeroRunBuffer);
        op += run;
        nextState = probe & 3;
        state = nextState;
        if (state > 0) {
          if (state > sourceLength - ip) {
            throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
          }
          if (state > destinationLength - op) {
            throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
          }
          copyLiterals(source, ip, destination, op, state);
          ip += state;
          op += state;
        }
        continue;
      }

      final highDistance = (t & 8) << 11;
      var matchLength = t & 7;
      final int operand;
      if (matchLength == 0) {
        // The length extension comes before the two distance bytes.
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
          }
          final next = source[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        matchLength = 7 + extra;
        if (ip + 2 > sourceLength) {
          throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
        }
        operand = source[ip] | (source[ip + 1] << 8);
        ip += 2;
      } else {
        operand = probe;
        ip += 2;
      }
      length = matchLength + 2;
      final lowDistance = operand >> 2;
      nextState = operand & 3;
      if (highDistance == 0 && lowDistance == 0) {
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
      distance = highDistance + lowDistance + 0x4000;
    }

    if (distance < 1 || distance > op) {
      throwLzo(
        LzoErrorCode.lookbehindOverrun,
        message: 'back-reference before the start of the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    if (length > destinationLength - op) {
      throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
    }
    copyMatch(destination, op, distance, length);
    op += length;

    state = nextState;
    if (state > 0) {
      if (state > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip);
      }
      if (state > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, state);
      ip += state;
      op += state;
    }
  }
}

void _require(Uint8List destination, int offset, int count) {
  if (count > destination.length - offset) {
    throwLzo(
      LzoErrorCode.outputOverrun,
      message: 'destination buffer too small',
      outputOffset: offset,
    );
  }
}
