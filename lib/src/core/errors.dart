/// Error codes used by the LZO reference implementation (liblzo2 2.10).
///
/// The numeric values match `lzo/lzoconf.h` so that error handling can be
/// translated directly from C code and compared in differential tests.
library;

/// A failure code returned by an LZO operation.
///
/// The order and numeric values mirror liblzo2's `LZO_E_*` constants.
enum LzoErrorCode {
  /// Generic error.
  error(-1, 'error'),

  /// Out of memory.
  outOfMemory(-2, 'out of memory'),

  /// Not compressible.
  notCompressible(-3, 'not compressible'),

  /// Compressed data violation: input overrun.
  inputOverrun(-4, 'input overrun'),

  /// Compressed data violation: output overrun.
  outputOverrun(-5, 'output overrun'),

  /// Compressed data violation: lookbehind overrun.
  lookbehindOverrun(-6, 'lookbehind overrun'),

  /// End of file not found, or an incomplete stream.
  eofNotFound(-7, 'end of file not found'),

  /// Compressed data violation: trailing bytes after the end of a stream.
  inputNotConsumed(-8, 'input not consumed'),

  /// The requested feature is not implemented.
  ///
  /// This implementation never reports this code: every entry point of the
  /// supported algorithm matrix is implemented. It exists for compatibility
  /// with liblzo2's error enumeration.
  notYetImplemented(-9, 'not yet implemented'),

  /// Invalid argument.
  invalidArgument(-10, 'invalid argument'),

  /// Invalid alignment.
  invalidAlignment(-11, 'invalid alignment'),

  /// Compressed data violation: trailing bytes in the output buffer.
  outputNotConsumed(-12, 'output not consumed');

  const LzoErrorCode(this.code, this.description);

  /// The liblzo2 numeric error code.
  final int code;

  /// A short human-readable description.
  final String description;

  /// Returns the code with [code], or [error] when the value is unknown.
  static LzoErrorCode fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return error;
  }
}

/// An exception thrown when an LZO operation fails.
///
/// The [code] carries the liblzo2-compatible error number, [inputOffset] and
/// [outputOffset] point at the failing position in the source and destination
/// buffers when available.
final class LzoException implements Exception {
  const LzoException(
    this.code, {
    this.message = '',
    this.inputOffset,
    this.outputOffset,
  });

  /// The failure code.
  final LzoErrorCode code;

  /// Additional context, empty for the default description.
  final String message;

  /// Byte offset in the compressed input where decoding stopped.
  final int? inputOffset;

  /// Byte offset in the destination buffer where decoding stopped.
  final int? outputOffset;

  /// The description of [code], or [message] when it is non-empty.
  String get description => message.isEmpty ? code.description : message;

  @override
  String toString() {
    final buffer = StringBuffer('LzoException(${code.name}: $description');
    if (inputOffset != null) buffer.write(', input: $inputOffset');
    if (outputOffset != null) buffer.write(', output: $outputOffset');
    buffer.write(')');
    return buffer.toString();
  }
}

/// Throws an [LzoException] for [code].
Never throwLzo(
  LzoErrorCode code, {
  String message = '',
  int? inputOffset,
  int? outputOffset,
}) {
  throw LzoException(
    code,
    message: message,
    inputOffset: inputOffset,
    outputOffset: outputOffset,
  );
}
