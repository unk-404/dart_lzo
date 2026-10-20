/// Compression levels of the LZO1X family.
library;

import '../core/limits.dart';

/// The LZO1X compressor variants.
///
/// The numeric value is the liblzo2 compression level. The fast levels use a
/// single hash dictionary; [max] is LZO1X-999, which uses the much larger
/// sliding-window workspace and the configurable quality 1..9 search effort.
enum Lzo1xLevel {
  /// `lzo1x_1_compress`: 16 384 dictionary entries, 64 KiB of work memory.
  fast1(1, 14),

  /// `lzo1x_1_11_compress`: 2 048 entries, 8 KiB of work memory.
  fast11(11, 11),

  /// `lzo1x_1_12_compress`: 4 096 entries, 16 KiB of work memory.
  fast12(12, 12),

  /// `lzo1x_1_15_compress`: 32 768 entries, 128 KiB of work memory.
  fast15(15, 15),

  /// `lzo1x_999_compress`: lazy search with a 458 752 byte workspace.
  max(999, 0);

  const Lzo1xLevel(this.number, this.dictionaryBits);

  /// The liblzo2 level number.
  final int number;

  /// `log2` of the fast dictionary entry count; 0 for [max].
  final int dictionaryBits;

  /// Whether this is the high-effort LZO1X-999 level.
  bool get isMax => this == max;

  /// Number of entries in the fast compression dictionary (0 for [max]).
  int get dictionarySize => isMax ? 0 : 1 << dictionaryBits;

  /// Work memory required by this level, in bytes.
  int get memCompress =>
      isMax ? 14 * 16384 * 2 : dictionarySize * lzoDictEntrySize;
}
