/// Size limits and buffer bounds for the LZO algorithms.
///
/// Values are taken from liblzo2 2.10 (`lzo/lzo1x.h`, `src/lzo_conf.h`).
library;

import '../core/errors.dart';

/// `sizeof(lzo_dict_t)` in liblzo2's default configuration (a 32-bit unsigned
/// integer).
const int lzoDictEntrySize = 4;

/// Work memory used by `lzo1x_1_compress`: 16 384 dictionary entries = 64 KiB.
const int lzo1x1MemCompress = 16384 * lzoDictEntrySize;

/// Work memory used by `lzo1x_1_11_compress`: 2 048 entries = 8 KiB.
const int lzo1x11MemCompress = 2048 * lzoDictEntrySize;

/// Work memory used by `lzo1x_1_12_compress`: 4 096 entries = 16 KiB.
const int lzo1x12MemCompress = 4096 * lzoDictEntrySize;

/// Work memory used by `lzo1x_1_15_compress`: 32 768 entries = 128 KiB.
const int lzo1x15MemCompress = 32768 * lzoDictEntrySize;

/// Worst-case size of an `lzo1x` compressed block.
///
/// This is the bound used by lzop and documented for the LZO library:
/// `n + n / 16 + 64 + 3`. The `n / 16` term is the "at most 64 extra bytes per
/// 1024 input bytes" expansion limit stated by the LZO documentation.
int lzo1xCompressBound(int sourceLength) {
  if (sourceLength < 0) {
    throwLzo(LzoErrorCode.invalidArgument, message: 'sourceLength < 0');
  }
  return sourceLength + (sourceLength >> 4) + 64 + 3;
}

/// Worst-case compressed size shared by every LZO algorithm family.
int lzoCompressBound(int sourceLength) => lzo1xCompressBound(sourceLength);

/// The maximum distance encodable by an LZO1X M4 match (`0xBFFF`).
const int lzo1xMaxDistance = 0xBFFF;
