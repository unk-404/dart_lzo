/// Compression levels of the LZO1X family.
library;

import '../core/limits.dart';

/// The fast LZO1X compressor variants.
///
/// The numeric value is the liblzo2 compression level; the dictionary size is
/// the work memory divided by the size of one dictionary entry.
enum Lzo1xLevel {
  /// `lzo1x_1_compress`: 16 384 dictionary entries, 64 KiB of work memory.
  fast1(1, 14),

  /// `lzo1x_1_11_compress`: 2 048 entries, 8 KiB of work memory.
  fast11(11, 11),

  /// `lzo1x_1_12_compress`: 4 096 entries, 16 KiB of work memory.
  fast12(12, 12),

  /// `lzo1x_1_15_compress`: 32 768 entries, 128 KiB of work memory.
  fast15(15, 15);

  const Lzo1xLevel(this.number, this.dictionaryBits);

  /// The liblzo2 level number.
  final int number;

  /// `log2` of the dictionary entry count.
  final int dictionaryBits;

  /// Number of entries in the compression dictionary.
  int get dictionarySize => 1 << dictionaryBits;

  /// Work memory required by this level, in bytes.
  int get memCompress => dictionarySize * lzoDictEntrySize;
}
