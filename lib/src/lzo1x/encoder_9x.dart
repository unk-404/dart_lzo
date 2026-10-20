/// LZO "999" encoder and the shared LZO1X/LZO1Y/LZO1Z family decoder.
///
/// The encoder follows liblzo2 2.10's `lzo1x_999_compress` family: a sliding
/// window dictionary (`swd`) stores three-byte hash chains, a lazy match search
/// picks the most profitable token, and the found matches are coded with the
/// standard LZO1X/LZO1Y/LZO1Z instruction set. The nine quality levels select
/// the same search parameters as liblzo2's `lzo1x_999_compress_level` table.
///
/// This is deliberately the slow, memory-hungry LZO variant: one
/// [Lzo999Workspace] reserves 458 752 bytes, mirroring liblzo2's
/// `14 * 16384 * sizeof(short)` work memory.
///
/// The family decoder lives here as well because the v0.1.0 LZO1X decoder in
/// `src/lzo1x/decoder.dart` intentionally has no preset-dictionary support and
/// is outside this change's write scope. [lzoFamilyDecompress] covers the
/// documented LZO1X/LZO1Y/LZO1Z grammars, including dictionary look-behind.
library;

import 'dart:typed_data';

import '../core/codec.dart' show snapshotIfOverlapping;
import '../core/copy.dart';
import '../core/errors.dart';

/// Offset limits shared by every LZO1X derivative.
const int _m1MaxOffset = 0x0400;
const int _m2MinLen = 3;
const int _m3MaxOffset = 0x4000;
const int _m4MaxOffset = 0xbfff;
const int _m3MaxLen = 33;
const int _m4MaxLen = 9;

/// Sliding window dictionary geometry (`lzo_swd.ch`).
const int _swdN = _m4MaxOffset; // 49 151 positions
const int _swdF = 2048; // lookahead / maximum match length
const int _swdHsize = 16384; // HEAD3 buckets
const int _swdSize = _swdN + _swdF; // 51 199 ring slots
const int _swdBufferSize = _swdSize + _swdF; // 53 247 bytes, with wrap copy
const int _swdH2Size = 65536; // exact two-byte hash table
const int _swdNil = 0xffff;
const int _swdMaxChain = 2048;

/// Number of entries in `best_off`/`best_pos`: `max(M2,M3,M4 max len) + 1`.
///
/// Every LZO1X derivative reaches 34 because `M3_MAX_LEN` is 33.
const int _swdBestOff = _m3MaxLen + 1;

/// The three LZO1X-derived instruction encodings supported here.
///
/// The numeric parameters come from `config1x.h`, `config1y.h` and
/// `config1z.h`. LZO1X and LZO1Y differ in `M2_MAX_LEN`/`M2_MAX_OFFSET`;
/// LZO1Z changes the two-byte match offset layout and adds the
/// repeat-previous-distance rule.
enum LzoFamily {
  /// `lzo1x`: M2 lengths 3..8 and distances up to 2 KiB.
  lzo1x(m2MaxLen: 8, m2MaxOffset: 0x0800),

  /// `lzo1y`: M2 lengths 3..14 and distances up to 1 KiB.
  lzo1y(m2MaxLen: 14, m2MaxOffset: 0x0400),

  /// `lzo1z`: M2 lengths 3..8, reusable previous distance.
  lzo1z(m2MaxLen: 8, m2MaxOffset: 0x0700);

  const LzoFamily({required this.m2MaxLen, required this.m2MaxOffset});

  /// `M2_MAX_LEN`: longest match coded with the two-byte M2 instruction.
  final int m2MaxLen;

  /// `M2_MAX_OFFSET`: longest distance coded with the two-byte M2 layout.
  final int m2MaxOffset;

  /// Whether this is the LZO1Z encoding.
  bool get isZ => this == LzoFamily.lzo1z;

  /// `MX_MAX_OFFSET`: longest distance coded by the short M1 instruction.
  int get mxMaxOffset => _m1MaxOffset + m2MaxOffset;
}

/// Reusable work memory for the LZO "999" compressor.
///
/// liblzo2 documents `14 * 16384 * sizeof(short)` = 458 752 bytes for the
/// `lzo1x_999` family; this class owns the equivalent typed-data arrays. The
/// arrays are reused between calls: pass the same workspace to consecutive
/// [lzo1xCompress999], [lzo1yCompress999] or [lzo1zCompress999] calls to avoid
/// re-allocating them. A workspace is not reentrant.
final class Lzo999Workspace {
  /// Allocates the (large) work arrays.
  Lzo999Workspace();

  /// Work memory occupied by the reference implementation, in bytes.
  static const int memCompress = 14 * 16384 * 2;

  final Uint8List _buffer = Uint8List(_swdBufferSize);
  final Uint16List _head3 = Uint16List(_swdHsize);
  final Uint16List _llen3 = Uint16List(_swdHsize);
  final Uint16List _succ3 = Uint16List(_swdSize);
  final Uint16List _best3 = Uint16List(_swdSize);
  final Uint16List _head2 = Uint16List(_swdH2Size);
  final Uint32List _bestPos = Uint32List(_swdBestOff);
  final Uint32List _bestOff = Uint32List(_swdBestOff);

  void _reset() {
    // `head3`, `succ3` and `best3` are gated by `llen3`, so only the chain
    // lengths and the exact-match table need clearing between blocks.
    _llen3.setRange(0, _swdHsize, _clearH3);
    _head2.setRange(0, _swdH2Size, _nilH2);
  }
}

final Uint16List _clearH3 = Uint16List(_swdHsize);

final Uint16List _nilH2 = () {
  final table = Uint16List(_swdH2Size);
  table.fillRange(0, _swdH2Size, _swdNil);
  return table;
}();

/// Compresses an LZO1X block using the LZO1X-999 algorithm.
///
/// [quality] selects the search effort: 1 is the fastest and 9 tries hardest.
/// [dictionary] is an optional preset dictionary; the decoder needs the same
/// final 49 151 dictionary bytes to restore the block. [workspace] is reusable
/// work memory; when omitted a fresh one is allocated.
///
/// Throws [LzoException] with [LzoErrorCode.outputOverrun] when [destination]
/// is too small and with [LzoErrorCode.invalidArgument] for an invalid
/// quality.
int lzo1xCompress999(
  Uint8List source,
  Uint8List destination, {
  int quality = 9,
  Uint8List? dictionary,
  Lzo999Workspace? workspace,
}) => _compress999(
  source,
  destination,
  family: LzoFamily.lzo1x,
  quality: quality,
  dictionary: dictionary,
  workspace: workspace,
);

/// Compresses an LZO1Y block using the LZO1Y-999 algorithm.
///
/// See [lzo1xCompress999] for the meaning of the parameters.
int lzo1yCompress999(
  Uint8List source,
  Uint8List destination, {
  int quality = 9,
  Uint8List? dictionary,
  Lzo999Workspace? workspace,
}) => _compress999(
  source,
  destination,
  family: LzoFamily.lzo1y,
  quality: quality,
  dictionary: dictionary,
  workspace: workspace,
);

/// Compresses an LZO1Z block using the LZO1Z-999 algorithm.
///
/// See [lzo1xCompress999] for the meaning of the parameters.
int lzo1zCompress999(
  Uint8List source,
  Uint8List destination, {
  int quality = 9,
  Uint8List? dictionary,
  Lzo999Workspace? workspace,
}) => _compress999(
  source,
  destination,
  family: LzoFamily.lzo1z,
  quality: quality,
  dictionary: dictionary,
  workspace: workspace,
);

int _compress999(
  Uint8List source,
  Uint8List destination, {
  required LzoFamily family,
  required int quality,
  Uint8List? dictionary,
  Lzo999Workspace? workspace,
}) {
  if (quality < 1 || quality > 9) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'quality must be in 1..9 (got $quality)',
    );
  }
  final input = snapshotIfOverlapping(source, destination);
  final work = workspace ?? Lzo999Workspace();
  return _Encoder(input, destination, family, quality, work).encode(dictionary);
}

/// Decompresses one raw LZO1X/LZO1Y/LZO1Z block.
///
/// [family] selects the instruction encoding. [dictionary], when given, is the
/// preset dictionary used when the block was produced with one; only its final
/// 49 151 bytes are visible, matching liblzo2.
///
/// The block must end with the end-of-stream marker and must not contain
/// trailing bytes. Throws [LzoException] for truncated or malformed input and
/// for a destination that is too small.
int lzoFamilyDecompress(
  Uint8List source,
  Uint8List destination, {
  required LzoFamily family,
  Uint8List? dictionary,
}) {
  final sourceLength = source.length;
  final destinationLength = destination.length;

  if (sourceLength < 3) {
    throwLzo(
      LzoErrorCode.inputOverrun,
      message: 'compressed block shorter than 3 bytes',
      inputOffset: sourceLength,
    );
  }

  // liblzo2 crops an oversized dictionary to its final M4_MAX_OFFSET bytes.
  Uint8List? dict;
  var dictLength = 0;
  if (dictionary != null && dictionary.isNotEmpty) {
    if (dictionary.length > _m4MaxOffset) {
      dict = Uint8List.sublistView(
        dictionary,
        dictionary.length - _m4MaxOffset,
      );
    } else {
      dict = dictionary;
    }
    dictLength = dict.length;
  }

  final z = family.isZ;
  final m2MaxOffset = family.m2MaxOffset;

  final isX = family == LzoFamily.lzo1x;

  var ip = 0;
  var op = 0;
  var state = 0;
  var lastMOff = 0;

  // A leading literal run above 17 bytes encodes `first - 17` literals.
  final first = source[0];
  if (first > 17) {
    final count = first - 17;
    ip = 1;
    if (count > sourceLength - ip) {
      throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
    }
    if (count > destinationLength) {
      throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
    }
    destination.setRange(0, count, source, ip);
    ip += count;
    op = count;
    // Fewer than four leading literals leave the decoder in the short-match
    // state; four or more select the 3-byte "M1b" match variant.
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
      destination.setRange(op, op + literalLength, source, ip);
      ip += literalLength;
      op += literalLength;
      state = 4;
      continue;
    }

    int distance;
    int length;
    int nextState;

    if (t < 16) {
      // M1: two-byte match. With `state == 4` (after a literal run) the
      // three-byte variant with the `1 + M2_MAX_OFFSET` distance base is used.
      if (ip >= sourceLength) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      final base = state == 4 ? 1 + m2MaxOffset : 1;
      if (z) {
        distance = base + (t << 6) + (source[ip] >> 2);
        nextState = source[ip] & 3;
        lastMOff = distance;
      } else {
        distance = base + (t >> 2) + (source[ip] << 2);
        nextState = t & 3;
      }
      ip++;
      length = state == 4 ? 3 : 2;
    } else if (t >= 64) {
      // M2: short distance, length 3..M2_MAX_LEN.
      if (z) {
        final offBits = t & 0x1f;
        if (offBits >= 0x1c) {
          // Repeat the previous match distance; no operand byte is stored.
          distance = lastMOff;
          nextState = t & 3;
        } else {
          if (ip >= sourceLength) {
            throwLzo(
              LzoErrorCode.inputOverrun,
              inputOffset: ip,
              outputOffset: op,
            );
          }
          distance = 1 + (offBits << 6) + (source[ip] >> 2);
          nextState = source[ip] & 3;
          ip++;
          lastMOff = distance;
        }
        length = (t >> 5) + 1;
      } else if (isX) {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        distance = 1 + ((t >> 2) & 7) + (source[ip++] << 3);
        length = (t >> 5) + 1;
        nextState = t & 3;
      } else {
        if (ip >= sourceLength) {
          throwLzo(
            LzoErrorCode.inputOverrun,
            inputOffset: ip,
            outputOffset: op,
          );
        }
        distance = 1 + ((t >> 2) & 3) + (source[ip++] << 2);
        length = (t >> 4) - 1;
        nextState = t & 3;
      }
    } else if (t >= 32) {
      // M3: 14-bit distance (M2_MAX_OFFSET < distance <= M3_MAX_OFFSET).
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
      if (z) {
        distance = 1 + (source[ip] << 6) + (source[ip + 1] >> 2);
        nextState = source[ip + 1] & 3;
        lastMOff = distance;
      } else {
        distance = 1 + (operand >> 2);
        nextState = source[ip] & 3;
      }
      ip += 2;
    } else {
      // M4: long distance. Distance zero is the end-of-stream marker.
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
      final lowDistance = z
          ? (source[ip] << 6) + (source[ip + 1] >> 2)
          : operand >> 2;
      nextState = z ? source[ip + 1] & 3 : source[ip] & 3;
      ip += 2;

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
      if (z) lastMOff = distance;
    }

    if (distance < 1 || distance > op + dictLength) {
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

    if (distance <= op) {
      copyMatch(destination, op, distance, length);
    } else {
      // The match starts inside the preset dictionary.
      final fromDictionary = distance - op;
      final dictionaryStart = dictLength - fromDictionary;
      if (fromDictionary >= length) {
        destination.setRange(op, op + length, dict!, dictionaryStart);
      } else {
        destination.setRange(op, op + fromDictionary, dict!, dictionaryStart);
        copyMatch(
          destination,
          op + fromDictionary,
          distance,
          length - fromDictionary,
        );
      }
    }
    op += length;

    if (nextState > 0) {
      if (nextState > sourceLength - ip) {
        throwLzo(LzoErrorCode.inputOverrun, inputOffset: ip, outputOffset: op);
      }
      if (nextState > destinationLength - op) {
        throwLzo(LzoErrorCode.outputOverrun, inputOffset: ip, outputOffset: op);
      }
      destination.setRange(op, op + nextState, source, ip);
      ip += nextState;
      op += nextState;
    }
    state = nextState;
  }
}

/// Decompresses one raw LZO1X block that may reference a preset dictionary.
///
/// This is the dictionary-aware counterpart of the v0.1.0
/// `lzo1xDecompress`; it is exposed for the public `Lzo1x` wiring because the
/// existing decoder file has no dictionary support.
int lzo1xDecompressWithDictionary(
  Uint8List source,
  Uint8List destination, {
  Uint8List? dictionary,
}) => lzoFamilyDecompress(
  source,
  destination,
  family: LzoFamily.lzo1x,
  dictionary: dictionary,
);

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

const List<int> _tryLazyTable = [0, 0, 0, 1, 1, 1, 2, 2, 2];
const List<int> _goodLengthTable = [0, 0, 0, 4, 8, 8, 8, 32, 2048];
const List<int> _maxLazyTable = [0, 0, 0, 4, 16, 16, 32, 128, 2048];
const List<int> _maxChainTable = [4, 8, 16, 16, 32, 128, 256, 2048, 4096];
const List<bool> _bestOffTable = [
  false,
  false,
  false,
  false,
  false,
  false,
  false,
  true,
  true,
];

/// Sliding-window dictionary state (`lzo_swd.ch`).
final class _Swd {
  _Swd(this._workspace, this._source);

  final Lzo999Workspace _workspace;
  final Uint8List _source;

  /// Read position in the caller's input (`c->ip`).
  int sourceIp = 0;

  /// Ring indices (`s->ip`, `s->bp`, `s->rp`).
  int ip = 0;
  int bp = 0;
  int rp = 0;

  int look = 0;
  int mLen = 0;
  int mOff = 0;
  int mPos = 0;
  int bChar = 0;
  int maxChain = _swdMaxChain;
  int niceLength = _swdF;
  bool useBestOff = false;
  int nodeCount = 0;
  int firstRp = 0;

  void init({Uint8List? dictionary, required bool bestOff}) {
    final ws = _workspace;
    mLen = 0;
    mOff = 0;
    for (var i = 0; i < _swdBestOff; i++) {
      ws._bestOff[i] = 0;
      ws._bestPos[i] = 0;
    }
    maxChain = _swdMaxChain;
    niceLength = _swdF;
    useBestOff = bestOff;
    nodeCount = _swdN;
    firstRp = 0;
    ws._llen3.setRange(0, _swdHsize, _clearH3);
    ws._head2.setRange(0, _swdH2Size, _nilH2);

    ip = 0;
    var dictLength = 0;
    if (dictionary != null && dictionary.isNotEmpty) {
      var dictOffset = 0;
      dictLength = dictionary.length;
      if (dictLength > _swdN) {
        dictOffset = dictLength - _swdN;
        dictLength = _swdN;
      }
      ws._buffer.setRange(0, dictLength, dictionary, dictOffset);
      ip = dictLength;
    }
    bp = ip;
    firstRp = ip;

    look = _source.length;
    if (look > _swdF) look = _swdF;
    if (look > 0) {
      ws._buffer.setRange(ip, ip + look, _source, 0);
      sourceIp = look;
      ip += look;
    }
    if (ip == _swdSize) ip = 0;

    if (look >= 2 && dictLength > 0) _insertDict(0, dictLength);

    rp = firstRp;
    if (rp >= nodeCount) {
      rp -= nodeCount;
    } else {
      rp += _swdSize - nodeCount;
    }

    if (look < 3) {
      // The value does not matter; initialise the bytes HEAD3 may read.
      final base = bp + look;
      ws._buffer[base] = 0;
      ws._buffer[base + 1] = 0;
      ws._buffer[base + 2] = 0;
    }
    bChar = 0;
  }

  int _head3At(int position) {
    final b = _workspace._buffer;
    final value =
        (((b[position] << 5) ^ b[position + 1]) << 5) ^ b[position + 2];
    return ((value * 0x9f5f) >> 5) & (_swdHsize - 1);
  }

  int _head2At(int position) {
    final b = _workspace._buffer;
    return b[position] ^ (b[position + 1] << 8);
  }

  int _getHead3(int key) =>
      _workspace._llen3[key] == 0 ? _swdNil : _workspace._head3[key];

  int _getByte() => sourceIp < _source.length ? _source[sourceIp++] : -1;

  void _insertDict(int node, int length) {
    final ws = _workspace;
    nodeCount = _swdN - length;
    firstRp = node;
    var remaining = length;
    while (remaining > 0) {
      final key = _head3At(node);
      ws._succ3[node] = _getHead3(key);
      ws._head3[key] = node;
      ws._best3[node] = _swdF + 1;
      ws._llen3[key]++;
      ws._head2[_head2At(node)] = node;
      node++;
      remaining--;
    }
  }

  void getByte() {
    final ws = _workspace;
    final c = _getByte();
    if (c < 0) {
      if (look > 0) look--;
      ws._buffer[ip] = 0;
      if (ip < _swdF) ws._buffer[_swdSize + ip] = 0;
    } else {
      ws._buffer[ip] = c;
      if (ip < _swdF) ws._buffer[_swdSize + ip] = c;
    }
    if (++ip == _swdSize) ip = 0;
    if (++bp == _swdSize) bp = 0;
    if (++rp == _swdSize) rp = 0;
  }

  void _removeNode(int node) {
    final ws = _workspace;
    if (nodeCount == 0) {
      ws._llen3[_head3At(node)]--;
      final key2 = _head2At(node);
      if (ws._head2[key2] == node) ws._head2[key2] = _swdNil;
    } else {
      nodeCount--;
    }
  }

  void accept(int count) {
    final ws = _workspace;
    var remaining = count;
    while (remaining > 0) {
      _removeNode(rp);
      final key = _head3At(bp);
      ws._succ3[bp] = _getHead3(key);
      ws._head3[key] = bp;
      ws._best3[bp] = _swdF + 1;
      ws._llen3[key]++;
      ws._head2[_head2At(bp)] = bp;
      getByte();
      remaining--;
    }
  }

  bool _search2() {
    final ws = _workspace;
    final key = ws._head2[_head2At(bp)];
    if (key == _swdNil) return false;
    if (ws._bestPos[2] == 0) ws._bestPos[2] = key + 1;
    if (mLen < 2) {
      mLen = 2;
      mPos = key;
    }
    return true;
  }

  void _search(int node, int count) {
    final b = _workspace._buffer;
    final base = bp;
    final bx = bp + look;
    var scanEnd1 = b[base + mLen - 1];
    var current = node;
    var remaining = count;
    while (remaining > 0) {
      if (current >= _swdSize) break;
      final candidate = current;
      if (b[candidate + mLen - 1] == scanEnd1 &&
          b[candidate + mLen] == b[base + mLen] &&
          b[candidate] == b[base] &&
          b[candidate + 1] == b[base + 1]) {
        var p1 = base + 2;
        var p2 = candidate + 2;
        while (true) {
          p1++;
          p2++;
          if (!(p1 < bx && b[p1] == b[p2])) break;
        }
        final matchLength = p1 - base;
        if (matchLength < _swdBestOff) {
          if (_workspace._bestPos[matchLength] == 0) {
            _workspace._bestPos[matchLength] = candidate + 1;
          }
        }
        if (matchLength > mLen) {
          mLen = matchLength;
          mPos = candidate;
          if (mLen == look) return;
          if (mLen >= niceLength) return;
          if (mLen > _workspace._best3[candidate]) return;
          scanEnd1 = b[base + mLen - 1];
        }
      }
      current = _workspace._succ3[current];
      remaining--;
    }
  }

  int _posToOffset(int position) =>
      bp > position ? bp - position : _swdSize - (position - bp);

  void findBest() {
    final ws = _workspace;
    final key = _head3At(bp);
    final node = ws._succ3[bp] = _getHead3(key);
    var count = ws._llen3[key];
    ws._llen3[key] = count + 1;
    if (count > maxChain && maxChain > 0) count = maxChain;
    ws._head3[key] = bp;

    bChar = ws._buffer[bp];
    final previousLength = mLen;
    if (mLen >= look) {
      if (look == 0) bChar = -1;
      mOff = 0;
      ws._best3[bp] = _swdF + 1;
    } else {
      if (_search2() && look >= 3) _search(node, count);
      if (mLen > previousLength) mOff = _posToOffset(mPos);
      ws._best3[bp] = mLen;
      if (useBestOff) {
        for (var i = 2; i < _swdBestOff; i++) {
          final position = ws._bestPos[i];
          ws._bestOff[i] = position > 0 ? _posToOffset(position - 1) : 0;
        }
      }
    }

    _removeNode(rp);
    ws._head2[_head2At(bp)] = bp;
  }
}

final class _Encoder {
  _Encoder(
    this._source,
    this._destination,
    this._family,
    this._quality,
    this._workspace,
  ) : _swd = _Swd(_workspace, _source);

  final Uint8List _source;
  final Uint8List _destination;
  final LzoFamily _family;
  final int _quality;
  final Lzo999Workspace _workspace;
  final _Swd _swd;

  int _op = 0;
  int _ii = 0;
  int _lit = 0;
  int _look = 0;
  int _mLen = 0;
  int _mOff = 0;

  /// `c->bp`: input position of the current token.
  int _bp = 0;

  int _lastMOff = 0;
  int _r1Lit = 0;

  int _tryLazy = 0;
  int _goodLength = 32;
  int _maxLazy = 32;
  int _maxChain = _swdMaxChain;
  bool _useBestOff = false;

  int encode(Uint8List? dictionary) {
    _tryLazy = _tryLazyTable[_quality - 1];
    _goodLength = _goodLengthTable[_quality - 1];
    if (_goodLength == 0) _goodLength = 32;
    _maxLazy = _maxLazyTable[_quality - 1];
    if (_maxLazy == 0) _maxLazy = 32;
    _maxChain = _maxChainTable[_quality - 1];
    _useBestOff = _bestOffTable[_quality - 1];

    _workspace._reset();
    _swd.init(dictionary: dictionary, bestOff: _useBestOff);
    _swd.maxChain = _maxChain;

    _op = 0;
    _ii = 0;
    _lit = 0;

    _lastMOff = 0;
    _r1Lit = 0;

    _findMatch(0, 0);
    while (_look > 0) {
      var mLen = _mLen;
      var mOff = _mOff;

      if (_lit == 0) _ii = _bp;

      if (mLen < 2 ||
          (mLen == 2 && (mOff > _m1MaxOffset || _lit == 0 || _lit >= 4)) ||
          (mLen == 2 && _op == 0) ||
          (_op == 0 && _lit == 0)) {
        // Not worth coding as a match: emit a literal instead.
        mLen = 0;
      } else if (mLen == _m2MinLen) {
        // A three-byte match at short distance is coded as M1; doing so only
        // pays off when at least four literals precede it.
        if (mOff > _family.mxMaxOffset && _lit >= 4) mLen = 0;
      }

      if (mLen == 0) {
        _lit++;
        _swd.maxChain = _maxChain;
        _findMatch(1, 0);
        continue;
      }

      if (_useBestOff) {
        final (betterLength, betterOffset) = _betterMatch(mLen, mOff);
        mLen = betterLength;
        mOff = betterOffset;
      }

      // Lazy matching: look a few positions ahead for a cheaper token.
      var ahead = 0;
      var l1 = 0;
      var maxAhead = 0;
      if (_tryLazy == 0 || mLen >= _maxLazy) {
        l1 = 0;
        maxAhead = 0;
      } else {
        l1 = _lenOfCodedMatch(mLen, mOff, _lit);
        // liblzo2 computes `LZO_MIN(try_lazy, l1 - 1)` on unsigned values, so
        // an unencodable length (0) falls back to `try_lazy`.
        maxAhead = l1 <= 0 ? _tryLazy : (_tryLazy < l1 - 1 ? _tryLazy : l1 - 1);
      }

      var lazyMatch = false;
      while (ahead < maxAhead && _look > mLen) {
        if (mLen >= _goodLength) {
          _swd.maxChain = _maxChain >> 2;
        } else {
          _swd.maxChain = _maxChain;
        }
        _findMatch(1, 0);
        ahead++;

        if (_family.isZ) {
          // Coding a two-byte match with the previous distance is only worth
          // it when the new match does not rely on the same distance.
          if (mOff == _lastMOff && _mOff != _lastMOff) {
            if (mLen >= _m2MinLen && mLen <= _family.m2MaxLen) {
              _mLen = 0;
            }
          }
        }

        if (_mLen < mLen) continue;
        if (_mLen == mLen && _mOff >= mOff) continue;
        if (_useBestOff) {
          final (betterLength, betterOffset) = _betterMatch(_mLen, _mOff);
          _mLen = betterLength;
          _mOff = betterOffset;
        }
        final l2 = _lenOfCodedMatch(_mLen, _mOff, _lit + ahead);
        if (l2 == 0) continue;
        final l3 = _op == 0 ? 0 : _lenOfCodedMatch(ahead, mOff, _lit);
        final gain = _minGain(ahead, _lit, _lit + ahead, l1, l2, l3);
        if (_mLen >= mLen + gain) {
          lazyMatch = true;
          if (l3 != 0) {
            // Code the literals, then the shortened previous match.
            _codeRun(_ii, _lit, ahead);
            _lit = 0;
            _codeMatch(ahead, mOff);
          } else {
            _lit += ahead;
          }
          break;
        }
      }
      if (lazyMatch) continue;

      _codeRun(_ii, _lit, mLen);
      _lit = 0;
      _codeMatch(mLen, mOff);
      _swd.maxChain = _maxChain;
      _findMatch(mLen, 1 + ahead);
    }

    if (_lit > 0) _storeRun(_ii, _lit);

    _put(0x11);
    _put(0x00);
    _put(0x00);
    return _op;
  }

  void _findMatch(int thisLength, int skip) {
    if (skip > 0) _swd.accept(thisLength - skip);
    _swd.mLen = 1;
    _swd.mOff = 0;
    if (_swd.useBestOff) {
      _workspace._bestPos.fillRange(0, _swdBestOff, 0);
    }
    _swd.findBest();
    _mLen = _swd.mLen;
    _mOff = _swd.mOff;
    _swd.getByte();
    if (_swd.bChar < 0) {
      _look = 0;
      _mLen = 0;
    } else {
      _look = _swd.look + 1;
    }
    _bp = _swd.sourceIp - _look;
  }

  void _codeRun(int literalStart, int literalLength, int matchLength) {
    if (literalLength > 0) {
      _storeRun(literalStart, literalLength);
      _r1Lit = literalLength;
    } else {
      _r1Lit = 0;
    }
  }

  /// `len_of_coded_match`: number of bytes the match token occupies, or 0 when
  /// the match cannot be coded at this position.
  int _lenOfCodedMatch(int matchLength, int matchOffset, int literals) {
    var length = 4;
    if (matchLength < 2) return 0;
    if (matchLength == 2) {
      return (matchOffset <= _m1MaxOffset && literals > 0 && literals < 4)
          ? 2
          : 0;
    }
    if (matchLength <= _family.m2MaxLen && matchOffset <= _family.m2MaxOffset) {
      return 2;
    }
    if (matchLength == _m2MinLen &&
        matchOffset <= _family.mxMaxOffset &&
        literals >= 4) {
      return 2;
    }
    if (matchOffset <= _m3MaxOffset) {
      if (matchLength <= _m3MaxLen) return 3;
      var extra = matchLength - _m3MaxLen;
      while (extra > 255) {
        extra -= 255;
        length++;
      }
      return length;
    }
    if (matchOffset <= _m4MaxOffset) {
      if (matchLength <= _m4MaxLen) return 3;
      var extra = matchLength - _m4MaxLen;
      while (extra > 255) {
        extra -= 255;
        length++;
      }
      return length;
    }
    return 0;
  }

  /// `min_gain`: extra bytes a lazy match must save before it is preferred.
  int _minGain(
    int ahead,
    int literals1,
    int literals2,
    int length1,
    int length2,
    int length3,
  ) {
    var gain = ahead;
    if (literals1 <= 3) {
      gain += literals2 <= 3 ? 0 : 2;
    } else if (literals1 <= 18) {
      gain += literals2 <= 18 ? 0 : 1;
    }
    gain += (length2 - length1) * 2;
    if (length3 != 0) gain -= (ahead - length3) * 2;
    if (gain < 0) gain = 0;
    return gain;
  }

  /// `better_match`: prefer a shorter token found by the `best_off` table.
  (int, int) _betterMatch(int matchLength, int matchOffset) {
    var length = matchLength;
    var offset = matchOffset;
    if (length <= _m2MinLen) return (length, offset);

    if (_family.isZ) {
      if (offset == _lastMOff && length <= _family.m2MaxLen) {
        return (length, offset);
      }
      if (length >= _m2MinLen + 1 &&
          length <= _family.m2MaxLen + 1 &&
          _lastMOff != 0 &&
          _workspace._bestOff[length - 1] == _lastMOff) {
        length -= 1;
        offset = _workspace._bestOff[length];
        return (length, offset);
      }
    }

    if (offset <= _family.m2MaxOffset) return (length, offset);

    // M3/M4 -> M2.
    if (offset > _family.m2MaxOffset &&
        length >= _m2MinLen + 1 &&
        length <= _family.m2MaxLen + 1 &&
        _workspace._bestOff[length - 1] != 0 &&
        _workspace._bestOff[length - 1] <= _family.m2MaxOffset) {
      length -= 1;
      offset = _workspace._bestOff[length];
      return (length, offset);
    }

    // M4 -> M2.
    if (offset > _m3MaxOffset &&
        length >= _m4MaxLen + 1 &&
        length <= _family.m2MaxLen + 2 &&
        _workspace._bestOff[length - 2] != 0 &&
        _workspace._bestOff[length - 2] <= _family.m2MaxOffset) {
      length -= 2;
      offset = _workspace._bestOff[length];
      return (length, offset);
    }

    // M4 -> M3.
    if (offset > _m3MaxOffset &&
        length >= _m4MaxLen + 1 &&
        length <= _m3MaxLen + 1 &&
        _workspace._bestOff[length - 1] != 0 &&
        _workspace._bestOff[length - 1] <= _m3MaxOffset) {
      length -= 1;
      offset = _workspace._bestOff[length];
    }
    return (length, offset);
  }

  void _codeMatch(int matchLength, int matchOffset) {
    var length = matchLength;
    var offset = matchOffset;
    final startOffset = matchOffset;

    if (length == 2) {
      // M1: two-byte match, only after 1..3 literals.
      offset -= 1;
      if (_family.isZ) {
        _put(offset >> 6);
        _put((offset << 2) & 0xff);
      } else {
        _put(((offset & 3) << 2));
        _put(offset >> 2);
      }
    } else if (length <= _family.m2MaxLen &&
        (offset <= _family.m2MaxOffset ||
            (_family.isZ && offset == _lastMOff))) {
      // M2: short distance.
      if (_family.isZ && offset == _lastMOff) {
        _put(((length - 1) << 5) | 0x1c);
      } else {
        offset -= 1;
        if (_family == LzoFamily.lzo1x) {
          _put(((length - 1) << 5) | ((offset & 7) << 2));
          _put(offset >> 3);
        } else if (_family == LzoFamily.lzo1y) {
          _put(((length + 1) << 4) | ((offset & 3) << 2));
          _put(offset >> 2);
        } else {
          _put(((length - 1) << 5) | (offset >> 6));
          _put((offset << 2) & 0xff);
        }
      }
    } else if (length == _m2MinLen &&
        offset <= _family.mxMaxOffset &&
        _r1Lit >= 4) {
      // M1b: three-byte match, short distance, after a long literal run.
      offset -= 1 + _family.m2MaxOffset;
      if (_family.isZ) {
        _put(offset >> 6);
        _put((offset << 2) & 0xff);
      } else {
        _put((offset & 3) << 2);
        _put(offset >> 2);
      }
    } else if (offset <= _m3MaxOffset) {
      // M3: 14-bit distance.
      offset -= 1;
      if (length <= _m3MaxLen) {
        _put(0x20 | (length - 2));
      } else {
        length -= _m3MaxLen;
        _put(0x20);
        while (length > 255) {
          length -= 255;
          _put(0x00);
        }
        _put(length);
      }
      if (_family.isZ) {
        _put(offset >> 6);
        _put((offset << 2) & 0xff);
      } else {
        _put((offset << 2) & 0xff);
        _put(offset >> 6);
      }
    } else {
      // M4: long distance encoded relative to 0x4000.
      offset -= 0x4000;
      final high = (offset & 0x4000) >> 11;
      if (length <= _m4MaxLen) {
        _put(0x10 | high | (length - 2));
      } else {
        length -= _m4MaxLen;
        _put(0x10 | high);
        while (length > 255) {
          length -= 255;
          _put(0x00);
        }
        _put(length);
      }
      if (_family.isZ) {
        _put(offset >> 6);
        _put((offset << 2) & 0xff);
      } else {
        _put((offset << 2) & 0xff);
        _put(offset >> 6);
      }
    }

    _lastMOff = startOffset;
  }

  /// `STORE_RUN`: writes a literal run, folding 1..3 trailing literals into the
  /// two spare bits of the preceding match token.
  void _storeRun(int literalStart, int literalLength) {
    if (_op == 0 && literalLength <= 238) {
      _put(17 + literalLength);
    } else if (literalLength <= 3) {
      // The low two bits of the preceding token are free. LZO1Z folds into the
      // last byte, LZO1X/LZO1Y into the byte before it.
      if (_family.isZ) {
        _destination[_op - 1] |= literalLength;
      } else {
        _destination[_op - 2] |= literalLength;
      }
    } else if (literalLength <= 18) {
      _put(literalLength - 3);
    } else {
      var extra = literalLength - 18;
      _put(0x00);
      while (extra > 255) {
        extra -= 255;
        _put(0x00);
      }
      _put(extra);
    }

    _reserve(literalLength);
    _destination.setRange(_op, _op + literalLength, _source, literalStart);
    _op += literalLength;
  }

  void _reserve(int count) {
    if (count > _destination.length - _op) {
      throwLzo(
        LzoErrorCode.outputOverrun,
        message: 'destination buffer too small',
        outputOffset: _op,
      );
    }
  }

  void _put(int value) {
    _reserve(1);
    _destination[_op++] = value & 0xff;
  }
}
