/// The LZO1Z codec.
///
/// LZO1Z is an LZO1X variant that can repeat the previous match distance
/// without storing it again: an M2 token whose offset field reaches `0x1c` or
/// more reuses the distance of the previous match. M3 and M4 store their
/// distance bytes in the opposite order compared with LZO1X, and the two
/// trailing-literal bits live in the token's last byte.
///
/// liblzo2 only ships the high-effort level for this family, so the codec
/// exposes [Lzo1zLevel.max] (LZO1Z-999, quality 1..9) with an optional preset
/// dictionary.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/errors.dart';
import 'lzo1x/encoder_9x.dart';

/// Compression levels of the LZO1Z family.
enum Lzo1zLevel {
  /// `lzo1z_999_compress`: lazy search with a 458 752 byte workspace.
  max(999, Lzo999Workspace.memCompress);

  const Lzo1zLevel(this.number, this.memCompress);

  /// The liblzo2 level number.
  final int number;

  /// Work memory required by this level, in bytes.
  final int memCompress;
}

/// A reusable LZO1Z compressor/decompressor.
///
/// Instances are not reentrant and must not be shared between isolates. Work
/// memory is allocated lazily on the first compression.
final class Lzo1z extends LzoCodecBase {
  /// Creates a codec using the LZO1Z-999 level.
  ///
  /// [quality] selects the search effort (1 = fastest, 9 = strongest) and must
  /// be in 1..9. [dictionary] is the optional preset dictionary.
  const Lzo1z({this.level = Lzo1zLevel.max, this.quality = 9, this.dictionary});

  /// The compression level used by [compressInto].
  final Lzo1zLevel level;

  /// The 999 search effort (1 = fastest, 9 = strongest).
  final int quality;

  /// The optional preset dictionary.
  final Uint8List? dictionary;

  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = snapshotIfOverlapping(source, destination);
    final workspace = _workspaces[this] ??= Lzo999Workspace();
    return lzo1zCompress999(
      input,
      destination,
      quality: quality,
      dictionary: dictionary,
      workspace: workspace,
    );
  }

  @override
  int decompressInto(Uint8List source, Uint8List destination) =>
      lzo1zDecompress(source, destination, dictionary: dictionary);
}

/// One workspace per codec instance, allocated lazily.
///
/// The codec has a `const` constructor, so the mutable work memory cannot be a
/// field; an [Expando] ties it to the instance lifetime. Canonicalized `const`
/// codecs share one workspace, which is safe because a codec is documented as
/// non-reentrant.
final Expando<Lzo999Workspace> _workspaces = Expando<Lzo999Workspace>(
  'lzo1z.workspace',
);

/// Decompresses one raw LZO1Z block from [source] into [destination].
///
/// [dictionary], when given, supplies the bytes before the output when the
/// block was produced with a preset dictionary. Only the final 49 151
/// dictionary bytes are visible.
///
/// Throws an [LzoException] when the input is truncated, malformed, or would
/// write past the end of [destination].
int lzo1zDecompress(
  Uint8List source,
  Uint8List destination, {
  Uint8List? dictionary,
}) => lzoFamilyDecompress(
  source,
  destination,
  family: LzoFamily.lzo1z,
  dictionary: dictionary,
);
