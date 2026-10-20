/// Safe LZO1X decoder.
///
/// The instruction grammar follows liblzo2 2.10's `src/lzo1x_d.ch`, which is
/// also described by the Linux kernel's `Documentation/staging/lzo.rst`.
library;

import 'dart:typed_data';

import '../core/copy.dart';
import '../core/errors.dart';

/// Decompresses one raw LZO1X block from [source] into [destination].
///
/// Returns the number of bytes written to [destination]. The block must end
/// with the end-of-stream marker (`0x11 0x00 0x00`, or any M4 match with
/// distance zero) and must not contain trailing bytes.
///
/// Throws an [LzoException] when the input is truncated, malformed, or would
/// write past the end of [destination]. No memory beyond the two buffers is
/// allocated.
int lzo1xDecompress(Uint8List source, Uint8List destination) {
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
  var state = 0;

  // An initial byte above 17 encodes a leading literal run of `byte - 17`
  // bytes. Small runs leave `state` in 1..3, which changes how the next short
  // opcode is decoded.
  final first = source[0];
  if (first > 17) {
    ip = 1;
    final count = first - 17;
    if (count > sourceLength - ip) {
      throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
    }
    if (count > destinationLength) {
      throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
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
        outputOffset: op,
      );
    }

    var t = source[ip++];
    int distance;
    int length;
    int nextState;

    if (t < 16 && state == 0) {
      // A literal run. `t == 0` selects the zero-byte length extension.
      var literalLength = t;
      if (literalLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
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
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (literalLength > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, literalLength);
      ip += literalLength;
      op += literalLength;
      state = 4;
      continue;
    }

    if (t < 16) {
      // M1: a short match. `state == 4` means at least four literals were just
      // copied, which selects the 3-byte variant with a 2 KiB distance base.
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
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
      // M2: 3 or 4 bytes, distance up to 2 KiB.
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      distance = 1 + ((t >> 2) & 7) + (source[ip] << 3);
      length = (t >> 5) + 1;
      ip++;
      nextState = t & 3;
    } else if (t >= 32) {
      // M3: distance up to 16 KiB, length in the low five bits.
      var matchLength = t & 31;
      if (matchLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
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
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final operand = source[ip] | (source[ip + 1] << 8);
      ip += 2;
      distance = 1 + (operand >> 2);
      nextState = operand & 3;
    } else {
      // M4: distance 16 KiB..0xBFFF. Distance zero is end-of-stream,
      // independent of the length bits.
      final highDistance = (t & 8) << 11;
      var matchLength = t & 7;
      if (matchLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceLength) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          final next = source[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        matchLength = 7 + extra;
      }
      length = matchLength + 2;

      if (ip + 2 > sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final operand = source[ip] | (source[ip + 1] << 8);
      ip += 2;
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
      throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
    }

    copyMatch(destination, op, distance, length);
    op += length;

    state = nextState;
    if (state > 0) {
      if (state > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (state > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      copyLiterals(source, ip, destination, op, state);
      ip += state;
      op += state;
    }
  }
}
