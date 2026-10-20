/// LZO1X compressed-block optimizer and in-place decoder.
///
/// `lzo1xOptimize` is a direct Dart port of liblzo2 2.10's `lzo1x_optimize`
/// (`src/lzo1x_oo.ch`). It decodes the block while rearranging bytes inside
/// it: short matches that sit between literal runs are folded into those runs,
/// so the block decodes with fewer tokens. The block length never changes and
/// the decoded bytes are identical; liblzo2 reports a 1-3% decompression
/// speed-up from the rewrite.
///
/// `lzo1xDecompressInPlace` decodes one raw block inside a single buffer: the
/// output is written at offset 0 and the compressed block lives at
/// [compressedOffset]. The two ranges may overlap, which is the layout used by
/// lzop (compressed block at the end of the output buffer). Every write is
/// checked against the compressed input cursor, so a layout that would
/// overwrite unread compressed data is rejected with an [LzoException] instead
/// of silently corrupting data.
library;

import 'dart:typed_data';

import '../core/copy.dart';
import '../core/errors.dart';

/// Step labels of the translated state machine.
///
/// liblzo2's optimizer is written with `goto` labels; each value of this enum
/// corresponds to one of them (`while` top, `copy_literal_run`,
/// `first_literal_run`, `match`, `match_done`, `match_next`).
enum _Step {
  loopTop,
  copyLiteralRun,
  firstLiteralRun,
  match,
  matchDone,
  copyStateLiterals,
}

/// Optimizes the raw LZO1X [block] in place and decodes it into [scratch].
///
/// [block] must contain one complete raw LZO1X block (the same format accepted
/// by [lzo1xDecompress]); it is rewritten in place. [scratch] is the
/// decompression target and must be large enough for the whole output - for a
/// valid block that means exactly the decompressed length. The two buffers
/// must be distinct and must not overlap.
///
/// Returns the number of bytes written to [scratch]. When [scratch] has the
/// exact decompressed length (the documented contract) the return value equals
/// `scratch.length`; if [scratch] is larger, the untouched tail is left alone
/// and the true decompressed length is returned.
///
/// The block length never changes: only compressed bytes move. Optimizing an
/// already optimized block is allowed and leaves it valid.
///
/// Throws an [LzoException] for malformed or truncated input. In particular:
///
/// * [LzoErrorCode.inputOverrun] - the block is truncated or shorter than
///   three bytes;
/// * [LzoErrorCode.outputOverrun] - the block decodes to more than
///   `scratch.length` bytes;
/// * [LzoErrorCode.lookbehindOverrun] - a match points before the decoded
///   data;
/// * [LzoErrorCode.eofNotFound] - no end-of-stream marker was found;
/// * [LzoErrorCode.inputNotConsumed] - bytes follow the end-of-stream marker;
/// * [LzoErrorCode.invalidArgument] - [block] and [scratch] overlap.
///
/// Nothing outside [block] and [scratch] is ever read or written.
int lzo1xOptimize(Uint8List block, Uint8List scratch) {
  final blockLength = block.length;
  final outputLength = scratch.length;

  if (blockLength < 3) {
    throwLzo(
      LzoErrorCode.inputOverrun,
      message: 'compressed block shorter than 3 bytes',
      inputOffset: blockLength,
    );
  }
  if (_overlaps(block, scratch)) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'the compressed block and the scratch buffer must not overlap',
    );
  }

  // Positions in the two buffers, mirroring `ip` and `op` in the C source.
  var ip = 0;
  var op = 0;

  // `litp` is the block offset of the byte holding the low two state bits of
  // the pending literal run (`litp == NULL` in C is -1 here); `lit` is that
  // run's length and `nextLit` the deferred literal count (`NO_LIT` is -1).
  var litp = -1;
  var lit = 0;
  var nextLit = -1;

  var t = 0;
  var mPos = 0;

  Never inputOverrun(String message) => throwLzo(
    LzoErrorCode.inputOverrun,
    message: message,
    inputOffset: ip,
    outputOffset: op,
  );

  Never outputOverrun() => throwLzo(
    LzoErrorCode.outputOverrun,
    message: 'optimized block does not fit in the scratch buffer',
    inputOffset: ip,
    outputOffset: op,
  );

  Never lookbehindOverrun() => throwLzo(
    LzoErrorCode.lookbehindOverrun,
    message: 'back-reference before the start of the decoded data',
    inputOffset: ip,
    outputOffset: op,
  );

  void requireInput(int count) {
    if (blockLength - ip < count) inputOverrun('truncated compressed block');
  }

  void requireOutput(int count) {
    if (outputLength - op < count) outputOverrun();
  }

  /// Decodes the zero-padded length extension used by literal runs and by
  /// matches, returning `base` plus 255 per zero byte plus the terminator.
  int readExtension(int base) {
    var value = base;
    while (true) {
      if (ip >= blockLength) inputOverrun('truncated length extension');
      final byte = block[ip];
      if (byte != 0) {
        ip++;
        return value + byte;
      }
      value += 255;
      ip++;
    }
  }

  /// Copies the next [count] literal bytes from the block to the output.
  void copyLiterals(int count) {
    if (count == 0) return;
    requireInput(count);
    requireOutput(count);
    scratch.setRange(op, op + count, block, ip);
    ip += count;
    op += count;
  }

  /// Emits a [length]-byte back-reference with distance `op - mPos` and
  /// advances `mPos`, exactly like `copy_match` in the C code.
  void emitMatch(int length) {
    requireOutput(length);
    copyMatch(scratch, op, op - mPos, length);
    op += length;
    mPos += length;
  }

  /// Overwrites [count] bytes of the block at [destination] with the bytes
  /// that the current match would produce. The block is being read from the
  /// output buffer, which may be self-referential, hence the `% distance`.
  void writeMatchBytes(int destination, int count) {
    final distance = op - mPos;
    for (var k = 0; k < count; k++) {
      block[destination + k] = scratch[mPos + (k % distance)];
    }
  }

  // ---------------------------------------------------------------------
  // Transliteration of `lzo1x_oo.ch`. `step` replaces the C `goto` labels.
  // ---------------------------------------------------------------------
  var step = _Step.loopTop;
  if (block[0] > 17) {
    // A leading literal run: `block[0] - 17` bytes follow the token byte.
    t = block[ip++] - 17;
    step = t < 4 ? _Step.copyStateLiterals : _Step.firstLiteralRun;
  }

  while (true) {
    switch (step) {
      case _Step.loopTop:
        // TEST_IP_AND_TEST_OP: a complete block must end before either
        // cursor runs out.
        if (ip >= blockLength || op > outputLength) {
          throwLzo(
            LzoErrorCode.eofNotFound,
            message: 'missing end-of-stream marker',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        t = block[ip++];
        if (t >= 16) {
          step = _Step.match;
          continue;
        }
        // A literal run. `litp` points at the token byte, whose low two bits
        // are rewritten when a following short match is folded into this run.
        litp = ip - 1;
        if (t == 0) {
          t = readExtension(15);
        }
        lit = t + 3;
        step = _Step.copyLiteralRun;
        continue;

      case _Step.copyLiteralRun:
        // The first three literals are copied before the state-machine label
        // that the leading-literal-run entry point jumps to.
        requireInput(3);
        requireOutput(3);
        scratch.setRange(op, op + 3, block, ip);
        ip += 3;
        op += 3;
        step = _Step.firstLiteralRun;
        continue;

      case _Step.firstLiteralRun:
        copyLiterals(t);
        requireInput(1);
        t = block[ip++];
        if (t >= 16) {
          step = _Step.match;
          continue;
        }
        // A literal run of at least four bytes forces the following short
        // match into the three-byte, 2 KiB-base variant.
        requireInput(1);
        final operand = block[ip++];
        final distance = 1 + 0x800 + (t >> 2) + (operand << 2);
        if (distance > op) lookbehindOverrun();
        mPos = op - distance;
        emitMatch(3);
        lit = 0;
        step = _Step.matchDone;
        continue;

      case _Step.match:
        if (t < 16) {
          // M1: a two-byte match.
          requireInput(1);
          final operand = block[ip++];
          final distance = 1 + (t >> 2) + (operand << 2);
          if (distance > op) lookbehindOverrun();
          mPos = op - distance;
          if (litp < 0) {
            // The block starts with a match: nothing can be folded.
            emitMatch(2);
            step = _Step.matchDone;
            continue;
          }
          final nl = block[ip - 2] & 3;
          final nextByte = ip < blockLength ? block[ip] : -1;
          if (nl == 0 && lit == 1 && nextByte >= 16) {
            // A match follows: turn this match into two literals so that the
            // previous run covers three bytes.
            nextLit = 0;
            lit += 2;
            block[litp] = (block[litp] & ~3) | lit;
            writeMatchBytes(ip - 2, 2);
            emitMatch(2);
            step = _Step.matchDone;
            continue;
          }
          if (nl == 0 &&
              nextByte > 0 &&
              nextByte < 16 &&
              lit + 2 + nextByte < 16) {
            // A literal run follows: fold this match and that run into one
            // long literal run.
            t = block[ip++];
            block[litp] &= ~3;
            writeMatchBytes(ip - 2, 2);
            litp += 2;
            if (lit > 0) {
              for (var i = lit - 1; i >= 0; i--) {
                block[litp + 1 + i] = block[litp + i];
              }
            }
            lit += 2 + t + 3;
            block[litp] = lit - 3;
            emitMatch(2);
            step = _Step.copyLiteralRun;
            continue;
          }
          emitMatch(2);
          step = _Step.matchDone;
          continue;
        }

        if (t >= 64) {
          // M2: three or four bytes.
          requireInput(1);
          final operand = block[ip++];
          final distance = 1 + ((t >> 2) & 7) + (operand << 3);
          if (distance > op) lookbehindOverrun();
          mPos = op - distance;
          t = (t >> 5) - 1;
          if (litp >= 0) {
            final nl = block[ip - 2] & 3;
            final nextByte = ip < blockLength ? block[ip] : -1;
            if (t == 1 &&
                lit > 3 &&
                nl == 0 &&
                nextByte > 0 &&
                nextByte < 16 &&
                lit + 3 + nextByte < 16) {
              // Two long literal runs separated by a three-byte match.
              t = block[ip++];
              writeMatchBytes(ip - 3, 3);
              lit += 3 + t + 3;
              block[litp] = lit - 3;
              emitMatch(3);
              step = _Step.copyLiteralRun;
              continue;
            }
          }
          emitMatch(t + 2);
          step = _Step.matchDone;
          continue;
        }

        // M3 (32..63) and M4 (16..31) matches.
        if (t >= 32) {
          t &= 31;
          if (t == 0) t = readExtension(31);
          requireInput(2);
          final operand0 = block[ip++];
          final operand1 = block[ip++];
          mPos = op - 1 - (operand0 >> 2) - (operand1 << 6);
        } else {
          final highDistance = (t & 8) << 11;
          t &= 7;
          if (t == 0) t = readExtension(7);
          requireInput(2);
          final operand0 = block[ip++];
          final operand1 = block[ip++];
          mPos = op - highDistance - (operand0 >> 2) - (operand1 << 6);
          if (mPos == op) {
            // Distance zero is the end-of-stream marker.
            if (ip != blockLength) {
              throwLzo(
                LzoErrorCode.inputNotConsumed,
                message:
                    '${blockLength - ip} trailing byte(s) after end of '
                    'stream',
                inputOffset: ip,
                outputOffset: op,
              );
            }
            return op;
          }
          mPos -= 0x4000;
        }
        // A non-zero distance means this is a real back-reference.
        if (mPos < 0) lookbehindOverrun();

        if (litp >= 0) {
          final nl = block[ip - 2] & 3;
          final nextByte = ip < blockLength ? block[ip] : -1;
          if (t == 1 && lit == 0 && nl == 0 && nextByte >= 16) {
            // A match follows: make the previous state a three-byte run.
            nextLit = 0;
            lit += 3;
            block[litp] = (block[litp] & ~3) | lit;
            writeMatchBytes(ip - 3, 3);
            emitMatch(3);
            step = _Step.matchDone;
            continue;
          }
          if (t == 1 &&
              lit <= 3 &&
              nl == 0 &&
              nextByte > 0 &&
              nextByte < 16 &&
              lit + 3 + nextByte < 16) {
            // A literal run follows: merge it with the three bytes this
            // match would have produced.
            t = block[ip++];
            block[litp] &= ~3;
            writeMatchBytes(ip - 3, 3);
            litp += 2;
            if (lit > 0) {
              for (var i = lit - 1; i >= 0; i--) {
                block[litp + 1 + i] = block[litp + i];
              }
            }
            lit += 3 + t + 3;
            block[litp] = lit - 3;
            emitMatch(3);
            step = _Step.copyLiteralRun;
            continue;
          }
        }
        emitMatch(t + 2);
        step = _Step.matchDone;
        continue;

      case _Step.matchDone:
        if (nextLit < 0) {
          t = block[ip - 2] & 3;
          lit = t;
          litp = ip - 2;
        } else {
          t = nextLit;
        }
        nextLit = -1;
        if (t == 0) {
          // The next token is a match: back to the outer loop.
          step = _Step.loopTop;
          continue;
        }
        step = _Step.copyStateLiterals;
        continue;

      case _Step.copyStateLiterals:
        // `t` in 1..3 literals stored after the previous match, or the
        // leading literal count at entry.
        copyLiterals(t);
        requireInput(1);
        t = block[ip++];
        step = _Step.match;
        continue;
    }
  }
}

/// Decompresses one raw LZO1X block in place in [buffer].
///
/// The decoded bytes are written at offset 0 and the compressed block lives at
/// [compressedOffset] for [compressedLength] bytes. The two ranges may
/// overlap, which is the layout used by lzop: the compressed block sits at the
/// end of a buffer whose start holds the output. The canonical buffer size is
/// `outputLength + outputLength ~/ 16 + 64 + 3`, with the compressed block
/// placed so that it ends exactly at the end of the buffer; that layout is
/// safe for every valid block.
///
/// The decoder copies literal runs forwards and checks every back-reference
/// against the compressed input cursor: a match must end at or before the next
/// unread compressed byte, and a literal run must start at or before it. If a
/// layout would cause a write to be read back as compressed data, an
/// [LzoException] with [LzoErrorCode.error] is thrown instead of returning
/// corrupted data. Optimizing the block with [lzo1xOptimize] is not required
/// for that; it removes redundant tokens and speeds decompression up.
///
/// Returns the number of output bytes written. For a valid block that is
/// `outputLength`; callers should check the return value, since raw LZO1X
/// blocks do not store their decompressed length.
///
/// Throws an [LzoException] when the arguments are invalid, when the block is
/// malformed or truncated, or when an in-place write would clobber unread
/// compressed data.
int lzo1xDecompressInPlace(
  Uint8List buffer, {
  required int compressedOffset,
  required int compressedLength,
  required int outputLength,
}) {
  if (compressedOffset < 0 ||
      compressedLength < 0 ||
      outputLength < 0 ||
      compressedOffset > buffer.length ||
      compressedLength > buffer.length - compressedOffset ||
      outputLength > buffer.length) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'compressed or output range does not fit in the buffer',
    );
  }
  if (compressedLength < 3) {
    throwLzo(
      LzoErrorCode.inputOverrun,
      message: 'compressed block shorter than 3 bytes',
      inputOffset: compressedLength,
    );
  }

  final sourceEnd = compressedOffset + compressedLength;
  var ip = compressedOffset;
  var op = 0;
  var state = 0;

  Never inPlaceViolation(String what) => throwLzo(
    LzoErrorCode.error,
    message:
        'in-place decode would overwrite unread compressed data '
        '($what); move the compressed block further away from the output '
        '(the lzop layout with outputLength ~/ 16 + 64 + 3 spare bytes is '
        'safe)',
    inputOffset: ip,
    outputOffset: op,
  );

  /// Copies [count] literal bytes from the compressed input to the output.
  ///
  /// The copy is done forwards, so the write cursor must not be past the read
  /// cursor: a read at `ip + k` then always happens at or after the write of
  /// `op + k`, and no unread byte is overwritten before it is read. The
  /// `setRange` fast path is only taken when the two ranges cannot overlap at
  /// all.
  void copyLiteralsInPlace(int count) {
    if (ip + count > sourceEnd) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'truncated literal run',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    if (op + count > outputLength) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'literal run does not fit in the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    // A forwards copy is only unsafe when the write range overlaps the source
    // range *and* the write cursor is ahead of the read cursor, so that a
    // later read would see a byte this copy already overwrote. A write range
    // that starts at or after the end of the source range cannot hurt.
    if (op > ip && op - ip < count) inPlaceViolation('literal run');
    if (op + count <= ip) {
      buffer.setRange(op, op + count, buffer, ip);
    } else {
      for (var i = 0; i < count; i++) {
        buffer[op + i] = buffer[ip + i];
      }
    }
    ip += count;
    op += count;
  }

  /// Copies one back-reference, checking that its output range does not
  /// overwrite unread compressed input.
  void copyMatchInPlace(int distance, int length) {
    if (distance < 1 || distance > op) {
      throwLzo(
        LzoErrorCode.lookbehindOverrun,
        message: 'back-reference before the start of the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    if (length > outputLength - op) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'match does not fit in the output',
        inputOffset: ip,
        outputOffset: op,
      );
    }
    // Writes [op, op + length); unread compressed data is [ip, sourceEnd).
    // Only an actual intersection of those ranges destroys input.
    final overlapStart = op > ip ? op : ip;
    final overlapEnd = op + length < sourceEnd ? op + length : sourceEnd;
    if (overlapStart < overlapEnd) inPlaceViolation('match');
    copyMatch(buffer, op, distance, length);
    op += length;
  }

  // An initial byte above 17 encodes a leading literal run of `first - 17`
  // bytes; small runs leave `state` in 1..3, which changes how the next short
  // opcode is decoded.
  final first = buffer[ip];
  if (first > 17) {
    ip++;
    final count = first - 17;
    copyLiteralsInPlace(count);
    state = count < 4 ? count : 4;
  }

  while (true) {
    if (ip >= sourceEnd) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'missing end-of-stream marker',
        inputOffset: ip,
        outputOffset: op,
      );
    }

    var t = buffer[ip++];
    int distance;
    int length;
    int nextState;

    if (t < 16 && state == 0) {
      // A literal run. `t == 0` selects the zero-byte length extension.
      var literalLength = t;
      if (literalLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceEnd) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          final next = buffer[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        literalLength = 15 + extra;
      }
      literalLength += 3;
      copyLiteralsInPlace(literalLength);
      state = 4;
      continue;
    }

    if (t < 16) {
      // M1: a short match. `state == 4` selects the 3-byte variant with a
      // 2 KiB distance base.
      if (ip >= sourceEnd) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (state == 4) {
        distance = 2049 + (t >> 2) + (buffer[ip] << 2);
        length = 3;
      } else {
        distance = 1 + (t >> 2) + (buffer[ip] << 2);
        length = 2;
      }
      ip++;
      nextState = t & 3;
    } else if (t >= 64) {
      // M2: 3 or 4 bytes, distance up to 2 KiB.
      if (ip >= sourceEnd) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      distance = 1 + ((t >> 2) & 7) + (buffer[ip] << 3);
      length = (t >> 5) + 1;
      ip++;
      nextState = t & 3;
    } else if (t >= 32) {
      // M3: distance up to 16 KiB, length in the low five bits.
      var matchLength = t & 31;
      if (matchLength == 0) {
        var extra = 0;
        while (true) {
          if (ip >= sourceEnd) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          final next = buffer[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        matchLength = 31 + extra;
      }
      length = matchLength + 2;
      if (ip + 2 > sourceEnd) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final operand = buffer[ip] | (buffer[ip + 1] << 8);
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
          if (ip >= sourceEnd) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          final next = buffer[ip++];
          if (next != 0) {
            extra += next;
            break;
          }
          extra += 255;
        }
        matchLength = 7 + extra;
      }
      length = matchLength + 2;
      if (ip + 2 > sourceEnd) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final operand = buffer[ip] | (buffer[ip + 1] << 8);
      ip += 2;
      final lowDistance = operand >> 2;
      nextState = operand & 3;

      if (highDistance == 0 && lowDistance == 0) {
        if (ip < sourceEnd) {
          throwLzo(
            LzoErrorCode.inputNotConsumed,
            message: '${sourceEnd - ip} trailing byte(s) after end of stream',
            inputOffset: ip,
            outputOffset: op,
          );
        }
        return op;
      }
      distance = highDistance + lowDistance + 0x4000;
    }

    copyMatchInPlace(distance, length);
    state = nextState;
    if (state > 0) {
      copyLiteralsInPlace(state);
    }
  }
}

/// Whether the two byte views cover overlapping ranges of one buffer.
///
/// Views of the same underlying storage compare equal through
/// `Uint8List.buffer`, while views of distinct allocations do not, so this
/// check works without relying on `identical` for the buffer wrapper.
bool _overlaps(Uint8List a, Uint8List b) {
  if (a.buffer != b.buffer) return false;
  final aStart = a.offsetInBytes;
  final aEnd = aStart + a.lengthInBytes;
  final bStart = b.offsetInBytes;
  final bEnd = bStart + b.lengthInBytes;
  return aStart < bEnd && bStart < aEnd;
}
