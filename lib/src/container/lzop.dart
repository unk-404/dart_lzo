/// Reader and writer for the lzop file container.
///
/// lzop is the command line frontend of LZO. Its file format wraps raw LZO1X
/// blocks in a header (magic, version, flags, checksum) and a sequence of
/// blocks that carry the uncompressed and compressed sizes plus optional
/// checksums.
///
/// This implementation is in-memory and has no `dart:io` dependency: callers
/// can use it on the VM, in Flutter, or on the web.
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../core/checksum.dart';
import '../core/errors.dart';
import '../lzo1x.dart';

/// lzop file magic.
const List<int> _magic = <int>[
  0x89,
  0x4c,
  0x5a,
  0x4f,
  0x00,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

/// Version written by lzop 1.04.
const int _lzopVersion = 0x1040;

/// `lzo_version()` of liblzo2 2.10.
const int _libVersion = 0x20a0;

/// Oldest version that understands the fields this writer emits.
const int _versionNeeded = 0x0940;

/// Header flag bits (lzop 1.04 `conf.h`).
const int _fAdler32D = 0x00000001;
const int _fAdler32C = 0x00000002;
const int _fCrc32D = 0x00000100;
const int _fCrc32C = 0x00000200;
const int _fMultipart = 0x00000400;
const int _fFilter = 0x00000800;
const int _fCrc32Header = 0x00001000;
const int _fExtraField = 0x00000040;
const int _fOsUnix = 0x03000000;
const int _fReserved = 0x000fc000;

/// Largest block lzop accepts (64 MiB).
const int _maxBlockSize = 64 * 1024 * 1024;

/// Options for [Lzop.compress].
final class LzopOptions {
  const LzopOptions({
    this.blockSize = 256 * 1024,
    this.level = Lzo1xLevel.fast1,
    this.fileName = '',
    this.mtime = 0,
    this.mode = 0,
    this.crc32 = false,
    this.compressedChecksums = false,
    this.quality = 9,
  });

  /// Uncompressed block size. lzop's default is 256 KiB.
  final int blockSize;

  /// Raw LZO1X encoder level used for each block.
  final Lzo1xLevel level;

  /// Optional file name stored in the header (at most 255 bytes).
  final String fileName;

  /// Modification time, seconds since the Unix epoch.
  final int mtime;

  /// Unix mode stored in the header.
  final int mode;

  /// Use CRC-32 instead of Adler-32 for block checksums.
  final bool crc32;

  /// Also checksum the compressed payload of compressed blocks.
  final bool compressedChecksums;

  /// LZO1X-999 search effort (1..9); ignored by the fast levels.
  final int quality;
}

/// In-memory lzop container codec.
final class Lzop {
  const Lzop();

  /// Compresses [source] into a complete `.lzo` file.
  Uint8List compress(
    Uint8List source, {
    LzopOptions options = const LzopOptions(),
  }) {
    if (options.blockSize <= 0 || options.blockSize > _maxBlockSize) {
      throwLzo(
        LzoErrorCode.invalidArgument,
        message: 'blockSize must be in 1..$_maxBlockSize',
      );
    }
    final nameBytes = Uint8List.fromList(options.fileName.codeUnits);
    if (nameBytes.length > 255) {
      throwLzo(
        LzoErrorCode.invalidArgument,
        message: 'fileName is longer than 255 bytes',
      );
    }

    var flags = _fOsUnix;
    if (options.crc32) {
      flags |= _fCrc32D;
      if (options.compressedChecksums) flags |= _fCrc32C;
    } else {
      flags |= _fAdler32D;
      if (options.compressedChecksums) flags |= _fAdler32C;
    }

    final header = BytesBuilder(copy: false);
    _putUint16(header, _lzopVersion);
    _putUint16(header, _libVersion);
    _putUint16(header, _versionNeeded);
    header.addByte(_methodForLevel(options.level));
    header.addByte(options.level == Lzo1xLevel.max ? options.quality : 1);
    _putUint32(header, flags);
    _putUint32(header, options.mode & 0xffffffff);
    _putUint32(header, options.mtime & 0xffffffff);
    _putUint32(header, (options.mtime >> 32) & 0xffffffff);
    header.addByte(nameBytes.length);
    header.add(nameBytes);

    final headerBytes = header.takeBytes();
    // The header checksum is Adler-32 unless F_H_CRC32 is set; crc32
    // selects the block checksum algorithm only.
    final headerChecksum = lzoAdler32(1, headerBytes);

    final out = BytesBuilder(copy: false);
    out.add(_magic);
    out.add(headerBytes);
    _putUint32(out, headerChecksum);

    final codec = Lzo1x(level: options.level, quality: options.quality);
    for (var start = 0; start < source.length; start += options.blockSize) {
      final end = start + options.blockSize < source.length
          ? start + options.blockSize
          : source.length;
      final raw = Uint8List.sublistView(source, start, end);
      final compressed = Uint8List(Lzo1x.compressBound(raw.length));
      final compressedLength = codec.compressInto(raw, compressed);
      final stored = compressedLength >= raw.length;
      final payloadLength = stored ? raw.length : compressedLength;

      _putUint32(out, raw.length);
      _putUint32(out, payloadLength);
      if (options.crc32) {
        _putUint32(out, lzoCrc32(0, raw));
      } else {
        _putUint32(out, lzoAdler32(1, raw));
      }
      if (!stored) {
        if (options.crc32) {
          if (options.compressedChecksums) {
            _putUint32(out, lzoCrc32(0, compressed, 0, compressedLength));
          }
        } else if (options.compressedChecksums) {
          _putUint32(out, lzoAdler32(1, compressed, 0, compressedLength));
        }
        out.add(Uint8List.sublistView(compressed, 0, compressedLength));
      } else {
        out.add(raw);
      }
    }
    _putUint32(out, 0);
    return out.takeBytes();
  }

  /// Decompresses a complete `.lzo` file.
  Uint8List decompress(Uint8List source) {
    final reader = _Reader(source);
    final headerStart = reader.offset;
    if (source.length < _magic.length || !_hasMagic(source)) {
      throwLzo(
        LzoErrorCode.error,
        message: 'not an lzop file (bad magic)',
        inputOffset: 0,
      );
    }
    reader.skipBytes(_magic.length);

    final version = reader.readUint16();
    if (version < 0x0900) {
      throwLzo(
        LzoErrorCode.error,
        message: 'unsupported lzop version 0x${version.toRadixString(16)}',
        inputOffset: headerStart,
      );
    }
    reader.readUint16(); // lib_version
    var versionNeeded = 0x0900;
    if (version >= 0x0940) {
      versionNeeded = reader.readUint16();
      if (versionNeeded > _lzopVersion) {
        throwLzo(
          LzoErrorCode.error,
          message:
              'file needs lzop version 0x${versionNeeded.toRadixString(16)}',
          inputOffset: headerStart,
        );
      }
    }
    final method = reader.readUint8();
    final compressedLevel = version >= 0x0940 ? reader.readUint8() : 0;
    _checkMethod(method, compressedLevel);

    final flags = reader.readUint32();
    if ((flags & _fReserved) != 0) {
      throwLzo(
        LzoErrorCode.error,
        message: 'reserved lzop header flags are set',
        inputOffset: headerStart,
      );
    }
    if ((flags & _fMultipart) != 0) {
      throwLzo(
        LzoErrorCode.error,
        message: 'multipart lzop files are not supported',
        inputOffset: headerStart,
      );
    }
    if ((flags & _fCrc32Header) != 0) {
      throwLzo(
        LzoErrorCode.error,
        message: 'CRC-32 header checksums are not supported',
        inputOffset: headerStart,
      );
    }
    var filter = 0;
    if ((flags & _fFilter) != 0) {
      filter = reader.readUint32();
      if (filter != 0) {
        throwLzo(
          LzoErrorCode.error,
          message: 'lzop filter $filter is not supported',
          inputOffset: headerStart,
        );
      }
    }
    reader.readUint32(); // mode
    reader.readUint32(); // mtime_low
    if (version >= 0x0940) reader.readUint32(); // mtime_high
    final nameLength = reader.readUint8();
    reader.skipBytes(nameLength);

    final checksum = reader.readUint32();
    final expected = lzoAdler32(
      1,
      source,
      _magic.length,
      reader.offset - 4 - _magic.length,
    );
    if (checksum != expected) {
      throwLzo(
        LzoErrorCode.error,
        message: 'lzop header checksum mismatch',
        inputOffset: reader.offset - 4,
      );
    }

    if ((flags & _fExtraField) != 0) {
      final extraLength = reader.readUint32();
      if (extraLength > source.length) {
        throwLzo(
          LzoErrorCode.inputOverrun,
          message: 'lzop extra field length out of range',
          inputOffset: reader.offset,
        );
      }
      final start = reader.offset;
      reader.skipBytes(extraLength);
      final extraChecksum = reader.readUint32();
      final extraExpected = lzoAdler32(1, source, start - 4, 4 + extraLength);
      if (extraChecksum != extraExpected) {
        throwLzo(
          LzoErrorCode.error,
          message: 'lzop extra field checksum mismatch',
          inputOffset: reader.offset - 4,
        );
      }
    }

    final output = BytesBuilder(copy: false);
    final codec = Lzo1x();
    while (true) {
      final uncompressedLength = reader.readUint32();
      if (uncompressedLength == 0) break;
      if (uncompressedLength == 0xffffffff) {
        throwLzo(
          LzoErrorCode.error,
          message: 'split lzop files are not supported',
          inputOffset: reader.offset - 4,
        );
      }
      if (uncompressedLength > _maxBlockSize) {
        throwLzo(
          LzoErrorCode.error,
          message: 'lzop block is larger than 64 MiB',
          inputOffset: reader.offset - 4,
        );
      }
      final compressedLength = reader.readUint32();
      if (compressedLength == 0 || compressedLength > uncompressedLength) {
        throwLzo(
          LzoErrorCode.error,
          message: 'invalid lzop block size',
          inputOffset: reader.offset - 4,
        );
      }

      var adlerD = 0;
      var crcD = 0;
      var adlerC = 0;
      var crcC = 0;
      if ((flags & _fAdler32D) != 0) adlerD = reader.readUint32();
      if ((flags & _fCrc32D) != 0) crcD = reader.readUint32();
      if (compressedLength < uncompressedLength) {
        if ((flags & _fAdler32C) != 0) adlerC = reader.readUint32();
        if ((flags & _fCrc32C) != 0) crcC = reader.readUint32();
      }

      final payload = reader.readView(compressedLength);
      final block = Uint8List(uncompressedLength);
      if (compressedLength < uncompressedLength) {
        final written = codec.decompressInto(payload, block);
        if (written != uncompressedLength) {
          throwLzo(
            LzoErrorCode.outputOverrun,
            message:
                'lzop block decoded to $written bytes, expected '
                '$uncompressedLength',
            inputOffset: reader.offset,
          );
        }
        if ((flags & _fAdler32C) != 0 && adlerC != lzoAdler32(1, payload)) {
          throwLzo(
            LzoErrorCode.error,
            message: 'lzop compressed block checksum mismatch',
            inputOffset: reader.offset,
          );
        }
        if ((flags & _fCrc32C) != 0 && crcC != lzoCrc32(0, payload)) {
          throwLzo(
            LzoErrorCode.error,
            message: 'lzop compressed block CRC mismatch',
            inputOffset: reader.offset,
          );
        }
      } else {
        block.setRange(0, uncompressedLength, payload);
      }

      if ((flags & _fAdler32D) != 0 && adlerD != lzoAdler32(1, block)) {
        throwLzo(
          LzoErrorCode.error,
          message: 'lzop block checksum mismatch',
          inputOffset: reader.offset,
        );
      }
      if ((flags & _fCrc32D) != 0 && crcD != lzoCrc32(0, block)) {
        throwLzo(
          LzoErrorCode.error,
          message: 'lzop block CRC mismatch',
          inputOffset: reader.offset,
        );
      }
      output.add(block);
    }
    if (!reader.atEnd) {
      throwLzo(
        LzoErrorCode.inputNotConsumed,
        message: '${reader.remaining} trailing byte(s) after the last block',
        inputOffset: reader.offset,
      );
    }
    return output.takeBytes();
  }

  /// Compresses a zero-copy [Bytes] view into a `.lzo` file.
  Bytes compressBytes(
    Bytes source, {
    LzopOptions options = const LzopOptions(),
  }) => Bytes.fromUint8List(compress(source.asUint8List(), options: options));

  /// Decompresses a [Bytes] view of a `.lzo` file.
  Bytes decompressBytes(Bytes source) =>
      Bytes.fromUint8List(decompress(source.asUint8List()));
}

int _methodForLevel(Lzo1xLevel level) => switch (level) {
  Lzo1xLevel.fast15 => 2,
  Lzo1xLevel.max => 3,
  _ => 1,
};

void _checkMethod(int method, int level) {
  if (method < 1 || method > 3) {
    throwLzo(LzoErrorCode.error, message: 'unsupported lzop method $method');
  }
  if (level != 0 && (level < 1 || level > 9)) {
    throwLzo(LzoErrorCode.error, message: 'unsupported lzop level $level');
  }
}

bool _hasMagic(Uint8List source) {
  for (var i = 0; i < _magic.length; i++) {
    if (source[i] != _magic[i]) return false;
  }
  return true;
}

void _putUint16(BytesBuilder builder, int value) {
  builder
    ..addByte((value >> 8) & 0xff)
    ..addByte(value & 0xff);
}

void _putUint32(BytesBuilder builder, int value) {
  builder
    ..addByte((value >> 24) & 0xff)
    ..addByte((value >> 16) & 0xff)
    ..addByte((value >> 8) & 0xff)
    ..addByte(value & 0xff);
}

final class _Reader {
  _Reader(this.data) : offset = 0;

  final Uint8List data;
  int offset;

  bool get atEnd => offset == data.length;

  int get remaining => data.length - offset;

  int readUint8() {
    _need(1);
    return data[offset++];
  }

  int readUint16() {
    _need(2);
    final value = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return value;
  }

  int readUint32() {
    _need(4);
    final value =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    return value & 0xffffffff;
  }

  void skipBytes(int count) {
    _need(count);
    offset += count;
  }

  Uint8List readView(int count) {
    _need(count);
    final view = Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return view;
  }

  void _need(int count) {
    if (count < 0 || offset + count > data.length) {
      throwLzo(
        LzoErrorCode.inputOverrun,
        message: 'truncated lzop file',
        inputOffset: offset,
      );
    }
  }
}
