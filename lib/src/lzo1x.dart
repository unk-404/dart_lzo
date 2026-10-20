/// The LZO1X codec.
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'core/codec.dart';
import 'core/errors.dart';
import 'core/limits.dart';
import 'lzo1x/decoder.dart';
import 'lzo1x/encoder.dart';
import 'lzo1x/encoder_9x.dart';
import 'lzo1x/level.dart';
import 'lzo1x/optimize.dart';

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
final class Lzo1x implements LzoCodec {
  /// Creates a codec using [level] for compression.
  ///
  /// [quality] only applies to [Lzo1xLevel.max] and must be in 1..9.
  /// [dictionary] is the preset dictionary used by the 999 level and by
  /// [decompressInto] for blocks that reference one.
  Lzo1x({this.level = Lzo1xLevel.fast1, this.quality = 9, this.dictionary});

  /// The compression level used by [compress] and [compressInto].
  final Lzo1xLevel level;

  /// The LZO1X-999 search effort (1 = fastest, 9 = strongest).
  final int quality;

  /// The optional preset dictionary (LZO1X-999 only).
  final Uint8List? dictionary;

  Uint32List? _dictionary;
  Lzo999Workspace? _workspace999;

  /// The worst-case compressed size for [sourceLength] input bytes.
  static int compressBound(int sourceLength) =>
      lzo1xCompressBound(sourceLength);

  /// Compresses [source] into [destination] and returns the number of bytes
  /// written.
  ///
  /// The two buffers may overlap. [destination] must have room for the
  /// produced block; otherwise an [LzoException] with
  /// [LzoErrorCode.outputOverrun] is thrown.
  @override
  int compressInto(Uint8List source, Uint8List destination) {
    final input = _overlaps(source, destination)
        ? Uint8List.fromList(source)
        : source;
    if (level == Lzo1xLevel.max) {
      final workspace = _workspace999 ??= Lzo999Workspace();
      return lzo1xCompress999(
        input,
        destination,
        quality: quality,
        dictionary: dictionary,
        workspace: workspace,
      );
    }
    if (dictionary != null) {
      throwLzo(
        LzoErrorCode.invalidArgument,
        message: 'a preset dictionary requires Lzo1xLevel.max',
      );
    }
    final work = _dictionary ??= Uint32List(level.dictionarySize);
    return lzo1xCompress(input, destination, level, work);
  }

  /// Compresses [source] into a newly allocated [Bytes].
  @override
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
  @override
  int decompressInto(Uint8List source, Uint8List destination) {
    if (dictionary != null) {
      return lzoFamilyDecompress(
        source,
        destination,
        family: LzoFamily.lzo1x,
        dictionary: dictionary,
      );
    }
    return lzo1xDecompress(source, destination);
  }

  /// Rewrites [block] in place so it can be decompressed in place, using
  /// [output] as the decompression target.
  ///
  /// [output] must be large enough for the whole decompressed block and must
  /// not overlap [block]. The compressed block keeps its length; only literal
  /// bytes are moved. Returns the number of bytes written to [output].
  ///
  /// This is the Dart equivalent of liblzo2's `lzo1x_optimize`; it is an
  /// optional optimisation, not a requirement for valid streams.
  int optimizeInto(Uint8List block, Uint8List output) =>
      lzo1xOptimize(block, output);

  /// Decompresses one LZO1X block in place.
  ///
  /// The output is written at offset 0 of [buffer]; the compressed block lives
  /// at [compressedOffset] and has [compressedLength] bytes. The two ranges may
  /// overlap when [buffer] is sized like lzop's block buffer
  /// (`outputLength + outputLength / 16 + 64 + 3`). Returns the number of bytes
  /// written.
  ///
  /// Throws an [LzoException] when the block is malformed or the layout would
  /// overwrite unread compressed data.
  int decompressInPlace(
    Uint8List buffer, {
    required int compressedOffset,
    required int compressedLength,
    required int outputLength,
  }) => lzo1xDecompressInPlace(
    buffer,
    compressedOffset: compressedOffset,
    compressedLength: compressedLength,
    outputLength: outputLength,
  );

  /// Decompresses one raw LZO1X block into a newly allocated [Bytes].
  ///
  /// [maxOutputLength] is the capacity of the destination buffer; raw LZO
  /// blocks do not store the decompressed length, so the caller must supply it.
  /// The returned view is truncated to the number of bytes actually decoded.
  /// Throws an [LzoException] when the block is malformed or would produce more
  /// than [maxOutputLength] bytes.
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

  /// Whether two byte views of the same backing buffer overlap.
  static bool _overlaps(Uint8List a, Uint8List b) {
    if (!identical(a.buffer, b.buffer)) return false;
    final aEnd = a.offsetInBytes + a.lengthInBytes;
    final bEnd = b.offsetInBytes + b.lengthInBytes;
    return a.offsetInBytes < bEnd && b.offsetInBytes < aEnd;
  }
}
