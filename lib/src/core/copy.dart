/// Byte-copy primitives shared by the LZO decoders.
library;

import 'dart:typed_data';

/// 64-bit unaligned accessors are VM-only; dart2js throws on getUint64.
const bool _native64 = bool.fromEnvironment('dart.library.io');

/// Copies [length] literal bytes from [source] to [destination].
///
/// The caller is responsible for validating both ranges.
@pragma('vm:prefer-inline')
void copyLiterals(
  Uint8List source,
  int sourceOffset,
  Uint8List destination,
  int destinationOffset,
  int length,
) {
  destination.setRange(
    destinationOffset,
    destinationOffset + length,
    source,
    sourceOffset,
  );
}

/// Copies a back-reference of [length] bytes located [distance] bytes before
/// [destinationOffset] in [destination].
///
/// LZ77 match copies repeat the just-produced bytes when `distance < length`.
/// A single `setRange` would copy the *original* bytes instead, so short
/// distances are expanded geometrically: seed one period, then double it.
///
/// [data] is an optional `ByteData` view over [destination]. When supplied,
/// short non-overlapping matches are copied with 8-byte unaligned loads, which
/// is faster than a `setRange` call for the common LZO match lengths.
@pragma('vm:prefer-inline')
void copyMatch(
  Uint8List destination,
  int destinationOffset,
  int distance,
  int length, {
  ByteData? data,
}) {
  final sourceOffset = destinationOffset - distance;
  if (distance >= length) {
    if (_native64 && data != null && length <= 24) {
      if (length <= 4) {
        destination[destinationOffset] = destination[sourceOffset];
        if (length > 1) {
          destination[destinationOffset + 1] = destination[sourceOffset + 1];
          if (length > 2) {
            destination[destinationOffset + 2] = destination[sourceOffset + 2];
            if (length > 3) {
              destination[destinationOffset + 3] =
                  destination[sourceOffset + 3];
            }
          }
        }
      } else {
        var offset = 0;
        while (offset + 8 <= length) {
          data.setUint64(
            destinationOffset + offset,
            data.getUint64(sourceOffset + offset, Endian.little),
            Endian.little,
          );
          offset += 8;
        }
        while (offset < length) {
          destination[destinationOffset + offset] =
              destination[sourceOffset + offset];
          offset++;
        }
      }
      return;
    }
    destination.setRange(
      destinationOffset,
      destinationOffset + length,
      destination,
      sourceOffset,
    );
    return;
  }

  // Seed the first period; the ranges are adjacent, never overlapping.
  destination.setRange(
    destinationOffset,
    destinationOffset + distance,
    destination,
    sourceOffset,
  );

  // Grow the written prefix by copying from its own start. Each step copies at
  // most `written` bytes into a range that starts exactly at the end of the
  // written prefix, so source and destination never overlap.
  var written = distance;
  while (written < length) {
    final remaining = length - written;
    final chunk = written < remaining ? written : remaining;
    destination.setRange(
      destinationOffset + written,
      destinationOffset + written + chunk,
      destination,
      destinationOffset,
    );
    written += chunk;
  }
}
