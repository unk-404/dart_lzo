/// Checksums used by the lzop container, compatible with liblzo2.
library;

import 'dart:typed_data';

import 'errors.dart';

const int _adlerMod = 65521;
const int _adlerChunk = 5552;

/// Adler-32 with a caller-supplied initial value.
///
/// `lzo_adler32(LZO_ADLER32_INIT_VALUE, data, length)` uses an initial value of
/// `1`. Throws [LzoException] with [LzoErrorCode.invalidArgument] for an
/// out-of-range [offset] or [length].
int lzoAdler32(int initial, Uint8List data, [int offset = 0, int? length]) {
  final count = length ?? data.length - offset;
  if (offset < 0 || count < 0 || offset + count > data.length) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'checksum range out of bounds',
    );
  }

  var a = initial & 0xffff;
  var b = (initial >> 16) & 0xffff;
  var index = offset;
  var remaining = count;

  while (remaining > 0) {
    final chunk = remaining < _adlerChunk ? remaining : _adlerChunk;
    remaining -= chunk;
    for (var i = 0; i < chunk; i++) {
      a += data[index++];
      b += a;
    }
    a %= _adlerMod;
    b %= _adlerMod;
  }
  return ((b << 16) | a) & 0xffffffff;
}

/// CRC-32 (IEEE 802.3, reflected) with a caller-supplied initial value.
///
/// `lzo_crc32(0, data, length)` matches liblzo2's checksum. Throws
/// [LzoException] with [LzoErrorCode.invalidArgument] for an out-of-range
/// [offset] or [length].
int lzoCrc32(int initial, Uint8List data, [int offset = 0, int? length]) {
  final count = length ?? data.length - offset;
  if (offset < 0 || count < 0 || offset + count > data.length) {
    throwLzo(
      LzoErrorCode.invalidArgument,
      message: 'checksum range out of bounds',
    );
  }

  var crc = (initial ^ 0xffffffff) & 0xffffffff;
  final table = _crcTable;
  for (var i = 0; i < count; i++) {
    crc = table[(crc ^ data[offset + i]) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// The standard reflected CRC-32 table, built once per isolate.
final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var value = i;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[i] = value & 0xffffffff;
  }
  return table;
}
