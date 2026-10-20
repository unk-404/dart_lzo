/// A small, dependency-free SHA-256 implementation (FIPS 180-4).
///
/// The vector generator and the manifest test both need to hash committed
/// fixtures, and this package has no cryptographic dependency. The code is
/// deliberately limited to the one algorithm the tooling uses.
library;

import 'dart:typed_data';

/// The SHA-256 digest of [message] as 32 raw bytes.
Uint8List sha256(List<int> message) {
  // Initial hash values: the first 32 bits of the fractional parts of the
  // square roots of the first eight primes.
  final state = Uint32List.fromList(const [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);

  final paddedLength = ((message.length + 8) ~/ 64 + 1) * 64;
  final block = Uint8List(paddedLength)..setRange(0, message.length, message);
  block[message.length] = 0x80;
  final view = ByteData.sublistView(block)
    ..setUint64(paddedLength - 8, message.length * 8, Endian.big);

  final words = Uint32List(64);
  for (var offset = 0; offset < block.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      words[i] = view.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotr(words[i - 15], 7) ^
          _rotr(words[i - 15], 18) ^
          (words[i - 15] >> 3);
      final s1 =
          _rotr(words[i - 2], 17) ^
          _rotr(words[i - 2], 19) ^
          (words[i - 2] >> 10);
      words[i] = (words[i - 16] + s0 + words[i - 7] + s1) & 0xffffffff;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final choose = (e & f) ^ (~e & g);
      final temp1 =
          (h + s1 + choose + _roundConstants[i] + words[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + majority) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    state[0] = (state[0] + a) & 0xffffffff;
    state[1] = (state[1] + b) & 0xffffffff;
    state[2] = (state[2] + c) & 0xffffffff;
    state[3] = (state[3] + d) & 0xffffffff;
    state[4] = (state[4] + e) & 0xffffffff;
    state[5] = (state[5] + f) & 0xffffffff;
    state[6] = (state[6] + g) & 0xffffffff;
    state[7] = (state[7] + h) & 0xffffffff;
  }

  final digest = Uint8List(32);
  final digestView = ByteData.sublistView(digest);
  for (var i = 0; i < 8; i++) {
    digestView.setUint32(i * 4, state[i], Endian.big);
  }
  return digest;
}

/// The SHA-256 digest of [message] as a lowercase hexadecimal string.
String sha256Hex(List<int> message) {
  final digest = sha256(message);
  final builder = StringBuffer();
  for (final byte in digest) {
    builder.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return builder.toString();
}

int _rotr(int value, int count) =>
    ((value >> count) | (value << (32 - count))) & 0xffffffff;

const List<int> _roundConstants = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
