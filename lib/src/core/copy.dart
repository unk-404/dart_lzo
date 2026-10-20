/// Byte-copy primitives shared by the LZO decoders.
library;

import 'dart:typed_data';

/// Copies [length] literal bytes from [source] to [destination].
///
/// The caller is responsible for validating both ranges.
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
void copyMatch(
  Uint8List destination,
  int destinationOffset,
  int distance,
  int length,
) {
  final sourceOffset = destinationOffset - distance;
  if (distance >= length) {
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
