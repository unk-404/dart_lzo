/// One entry point for every LZO algorithm family.
library;

import 'dart:typed_data';

import 'core/codec.dart';
import 'core/errors.dart';
import 'lzo1.dart';
import 'lzo1a.dart';
import 'lzo1b.dart';
import 'lzo1c.dart';
import 'lzo1f.dart';
import 'lzo1x.dart';
import 'lzo1y.dart';
import 'lzo1z.dart';
import 'lzo2a.dart';

/// The LZO algorithm families implemented by this package.
enum LzoAlgorithm {
  /// LZO1 (levels 1 and 99).
  lzo1,

  /// LZO1A (levels 1 and 99).
  lzo1a,

  /// LZO1B (levels 1..9, 99 and 999).
  lzo1b,

  /// LZO1C (levels 1..9, 99 and 999).
  lzo1c,

  /// LZO1F (levels 1 and 999).
  lzo1f,

  /// LZO1X (levels 1, 11, 12, 15 and 999).
  lzo1x,

  /// LZO1Y (levels 1 and 999).
  lzo1y,

  /// LZO1Z (level 999).
  lzo1z,

  /// LZO2A (level 999).
  lzo2a,
}

/// Creates a codec for [algorithm].
///
/// [level] is the liblzo2 level number (for example 1, 11 or 999); 0 selects
/// the family default. [quality] and [dictionary] apply to the 999 levels.
///
/// Throws [LzoException] with [LzoErrorCode.invalidArgument] when [level] is
/// not a level of [algorithm].
LzoCodec lzoCodec(
  LzoAlgorithm algorithm, {
  int level = 0,
  int quality = 9,
  Uint8List? dictionary,
}) {
  switch (algorithm) {
    case LzoAlgorithm.lzo1:
      return Lzo1(
        level: _pick(
          Lzo1Level.values,
          level,
          Lzo1Level.fast,
          (value) => value.number,
        ),
      );
    case LzoAlgorithm.lzo1a:
      return Lzo1a(
        level: _pick(
          Lzo1aLevel.values,
          level,
          Lzo1aLevel.fast,
          (value) => value.number,
        ),
      );
    case LzoAlgorithm.lzo1b:
      return Lzo1b(
        level: _pick(
          Lzo1bLevel.values,
          level,
          Lzo1bLevel.l9,
          (value) => value.number,
        ),
      );
    case LzoAlgorithm.lzo1c:
      return Lzo1c(
        level: _pick(
          Lzo1cLevel.values,
          level,
          Lzo1cLevel.l9,
          (value) => value.number,
        ),
      );
    case LzoAlgorithm.lzo1f:
      return Lzo1f(
        level: _pick(
          Lzo1fLevel.values,
          level,
          Lzo1fLevel.fast1,
          (value) => value.number,
        ),
      );
    case LzoAlgorithm.lzo1x:
      return Lzo1x(
        level: _pick(
          Lzo1xLevel.values,
          level,
          Lzo1xLevel.fast1,
          (value) => value.number,
        ),
        quality: quality,
        dictionary: dictionary,
      );
    case LzoAlgorithm.lzo1y:
      return Lzo1y(
        level: _pick(
          Lzo1yLevel.values,
          level,
          Lzo1yLevel.fast1,
          (value) => value.number,
        ),
        quality: quality,
        dictionary: dictionary,
      );
    case LzoAlgorithm.lzo1z:
      return Lzo1z(
        level: _pick(
          Lzo1zLevel.values,
          level,
          Lzo1zLevel.max,
          (value) => value.number,
        ),
        quality: quality,
        dictionary: dictionary,
      );
    case LzoAlgorithm.lzo2a:
      return Lzo2a(
        level: _pick(
          Lzo2aLevel.values,
          level,
          Lzo2aLevel.max,
          (value) => value.number,
        ),
      );
  }
}

T _pick<T>(
  List<T> values,
  int requested,
  T fallback,
  int Function(T value) number,
) {
  if (requested == 0) return fallback;
  for (final value in values) {
    if (number(value) == requested) return value;
  }
  throwLzo(
    LzoErrorCode.invalidArgument,
    message: 'unsupported level $requested',
  );
}
