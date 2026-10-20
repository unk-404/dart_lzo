/// Shared public surface for every LZO algorithm family.
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'errors.dart';
import 'limits.dart';

/// A raw LZO block codec.
///
/// Raw LZO blocks carry no header and no original length, so decompression
/// needs a destination buffer that is large enough for the whole output.
abstract interface class LzoCodec {
  /// The worst-case compressed size for [sourceLength] input bytes.
  ///
  /// This is the buffer size a caller should allocate before [compressInto].
  /// [LzoCodecBase] codecs also expose it as `compressBound`; [Lzo1x] keeps
  /// that name as a static helper.
  int compressedSizeBound(int sourceLength);

  /// Compresses [source] into [destination] and returns the number of bytes
  /// written.
  ///
  /// The buffers may overlap. [destination] must have room for the produced
  /// block; otherwise an [LzoException] with [LzoErrorCode.outputOverrun] is
  /// thrown.
  int compressInto(Uint8List source, Uint8List destination);

  /// Compresses [source] into a newly allocated [Bytes].
  Bytes compress(Bytes source);

  /// Decompresses one raw block into [destination] and returns the number of
  /// bytes written.
  int decompressInto(Uint8List source, Uint8List destination);

  /// Decompresses one raw block into a newly allocated [Bytes].
  ///
  /// [maxOutputLength] is the destination capacity; the returned view is
  /// truncated to the number of bytes actually decoded.
  Bytes decompress(Bytes source, int maxOutputLength);
}

/// Convenience implementations shared by the per-family codecs.
abstract base class LzoCodecBase implements LzoCodec {
  const LzoCodecBase();

  /// The worst-case compressed size for [sourceLength] input bytes.
  int compressBound(int sourceLength) => lzoCompressBound(sourceLength);

  @override
  int compressedSizeBound(int sourceLength) => compressBound(sourceLength);

  @override
  Bytes compress(Bytes source) {
    final capacity = compressBound(source.length);
    final buffer = BytesMut(capacity);
    final view = buffer.spareView(capacity);
    final written = compressInto(source.asUint8List(), view);
    buffer.advance(written);
    return buffer.freeze();
  }

  @override
  Bytes decompress(Bytes source, int maxOutputLength) {
    if (maxOutputLength < 0) {
      throwLzo(LzoErrorCode.invalidArgument, message: 'maxOutputLength < 0');
    }
    final buffer = BytesMut(maxOutputLength);
    final view = buffer.spareView(maxOutputLength);
    final written = decompressInto(source.asUint8List(), view);
    buffer.advance(written);
    return buffer.freeze();
  }
}

/// Returns [source], or a copy of it when it overlaps [destination].
///
/// Compressors read the input while writing the output; a caller may legally
/// pass overlapping buffers, in which case the input has to be snapshotted
/// before the first write.
Uint8List snapshotIfOverlapping(Uint8List source, Uint8List destination) {
  if (!identical(source.buffer, destination.buffer)) return source;
  final sourceEnd = source.offsetInBytes + source.lengthInBytes;
  final destinationEnd = destination.offsetInBytes + destination.lengthInBytes;
  final overlaps =
      source.offsetInBytes < destinationEnd &&
      destination.offsetInBytes < sourceEnd;
  return overlaps ? Uint8List.fromList(source) : source;
}
