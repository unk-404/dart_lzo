/// The LZO1X codec.
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'core/errors.dart';
import 'core/limits.dart';
import 'lzo1x/decoder.dart';
import 'lzo1x/encoder.dart';
import 'lzo1x/level.dart';

export 'lzo1x/level.dart' show Lzo1xLevel;

/// A reusable LZO1X compressor/decompressor.
///
/// One instance owns the compression work memory, so reusing an instance
/// avoids re-allocating it for every block. Instances are not reentrant and
/// must not be shared between isolates.
///
/// LZO1X is a raw block codec: compressed data carries no header and no
/// original length, so [decompressInto] needs a destination buffer that is
/// large enough for the whole output.
final class Lzo1x {
  /// Creates a codec using [level] for compression.
  Lzo1x({this.level = Lzo1xLevel.fast1});

  /// The compression level used by [compress] and [compressInto].
  final Lzo1xLevel level;

  Uint32List? _dictionary;

  /// The worst-case compressed size for [sourceLength] input bytes.
  static int compressBound(int sourceLength) =>
      lzo1xCompressBound(sourceLength);

  /// Compresses [source] into [destination] and returns the number of bytes
  /// written.
  ///
  /// The two buffers may overlap. [destination] must have room for the
  /// produced block; otherwise an [LzoException] with
  /// [LzoErrorCode.outputOverrun] is thrown.
  int compressInto(Uint8List source, Uint8List destination) {
    final input = _overlaps(source, destination)
        ? Uint8List.fromList(source)
        : source;
    final dictionary = _dictionary ??= Uint32List(level.dictionarySize);
    return lzo1xCompress(input, destination, level, dictionary);
  }

  /// Compresses [source] into a newly allocated [Bytes].
  Bytes compress(Bytes source) {
    final capacity = compressBound(source.length);
    final buffer = BytesMut(capacity);
    final view = buffer.spareView(capacity);
    final written = compressInto(source.asUint8List(), view);
    buffer.advance(written);
    return buffer.freeze();
  }

  /// Decompresses one raw LZO1X block into [destination] and returns the number
  /// of bytes written.
  ///
  /// Throws an [LzoException] when the block is malformed or [destination] is
  /// too small. No memory is allocated.
  int decompressInto(Uint8List source, Uint8List destination) =>
      lzo1xDecompress(source, destination);

  /// Decompresses one raw LZO1X block into a newly allocated [Bytes].
  ///
  /// [maxOutputLength] is the capacity of the destination buffer; raw LZO
  /// blocks do not store the decompressed length, so the caller must supply it.
  /// The returned view is truncated to the number of bytes actually decoded.
  /// Throws an [LzoException] when the block is malformed or would produce more
  /// than [maxOutputLength] bytes.
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

  /// Whether two byte views of the same backing buffer overlap.
  static bool _overlaps(Uint8List a, Uint8List b) {
    if (!identical(a.buffer, b.buffer)) return false;
    final aEnd = a.offsetInBytes + a.lengthInBytes;
    final bEnd = b.offsetInBytes + b.lengthInBytes;
    return a.offsetInBytes < bEnd && b.offsetInBytes < aEnd;
  }
}
