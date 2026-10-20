//! Safe, dependency-free, pure-Rust **LZO1X decompressor**.
//!
//! Decodes raw LZO1X blocks as produced by `lzo1x_1`, `lzo1x_1_15`, and
//! `lzo1x_999` (the liblzo2 / `lzop` family) — a single compressed block with
//! no container header or stored output size. The output length must be known
//! (or upper-bounded) by the caller, exactly like the C `lzo1x_decompress_safe`.
//!
//! This is the GPL-free, MIT-licensed alternative to the existing GPL Rust LZO
//! ports, with `#![forbid(unsafe_code)]` and zero dependencies.
//!
//! ```
//! // "hello, lzo world!" compressed by liblzo2's lzo1x_1.
//! let block = [34, 104,101,108,108,111,44,32,108,122,111,32,119,111,114,108,100,33, 17,0,0];
//! let mut out = [0u8; 17];
//! let n = lzo::decompress_into(&block, &mut out).unwrap();
//! assert_eq!(&out[..n], b"hello, lzo world!");
//! ```
#![no_std]
#![forbid(unsafe_code)]

#[cfg(feature = "alloc")]
extern crate alloc;

use core::fmt;

/// An error returned while decompressing an LZO1X block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The compressed input ended before the block was fully decoded.
    InputOverrun,
    /// Decoding would write past the end of the output buffer.
    OutputOverrun,
    /// A back-reference points before the start of the output (corrupt block).
    LookbehindOverrun,
    /// The block decoded to a valid end but bytes remain in the input.
    InputNotConsumed,
    /// The block is malformed (bad instruction, run-length overflow, …).
    Malformed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Error::InputOverrun => "lzo: compressed input ended prematurely",
            Error::OutputOverrun => "lzo: output buffer too small",
            Error::LookbehindOverrun => "lzo: back-reference before output start",
            Error::InputNotConsumed => "lzo: trailing bytes after end-of-stream",
            Error::Malformed => "lzo: malformed compressed block",
        })
    }
}

impl core::error::Error for Error {}

/// Read one byte and advance.
fn rd(src: &[u8], ip: &mut usize) -> Result<u8, Error> {
    let b = *src.get(*ip).ok_or(Error::InputOverrun)?;
    *ip += 1;
    Ok(b)
}

/// Read a little-endian `u16` and advance.
fn rd_le16(src: &[u8], ip: &mut usize) -> Result<usize, Error> {
    let lo = rd(src, ip)? as usize;
    let hi = rd(src, ip)? as usize;
    Ok(lo | (hi << 8))
}

/// The zero-byte length extension: skip a run of `0x00` bytes (each worth 255)
/// then read the terminating non-zero byte; returns `255*zeros + terminator`
/// (the caller adds the per-command base). The run is bounded by the input
/// length (each zero consumes a byte); saturating arithmetic makes the value
/// overflow-safe even for an absurd input, so an over-long length simply fails
/// the later output-capacity check rather than wrapping.
fn length_ext(src: &[u8], ip: &mut usize) -> Result<usize, Error> {
    let mut zeros = 0usize;
    while *src.get(*ip).ok_or(Error::InputOverrun)? == 0 {
        *ip += 1;
        zeros += 1;
    }
    let term = rd(src, ip)? as usize;
    Ok(zeros.saturating_mul(255).saturating_add(term))
}

/// Copy `n` literal bytes from the input to the output.
fn copy_literals(
    src: &[u8],
    ip: &mut usize,
    dst: &mut [u8],
    op: &mut usize,
    n: usize,
) -> Result<(), Error> {
    if n > dst.len() - *op {
        return Err(Error::OutputOverrun);
    }
    if n > src.len() - *ip {
        return Err(Error::InputOverrun);
    }
    dst[*op..*op + n].copy_from_slice(&src[*ip..*ip + n]);
    *op += n;
    *ip += n;
    Ok(())
}

/// Copy a `length`-byte back-reference `distance` bytes behind the output
/// cursor — byte-by-byte, so an overlapping copy (distance < length) repeats
/// correctly, as LZ77 requires.
fn copy_match(dst: &mut [u8], op: &mut usize, distance: usize, length: usize) -> Result<(), Error> {
    if distance == 0 || distance > *op {
        return Err(Error::LookbehindOverrun);
    }
    if length > dst.len() - *op {
        return Err(Error::OutputOverrun);
    }
    // Forward byte-by-byte so an overlapping copy (distance < length) repeats
    // the just-written bytes, as LZ77 requires — `copy_within` (memmove) would
    // not. Indexed because the source and destination ranges overlap.
    let s = *op - distance;
    #[allow(clippy::needless_range_loop)]
    for i in 0..length {
        dst[*op + i] = dst[s + i];
    }
    *op += length;
    Ok(())
}

/// Decompress a raw LZO1X block into `dst`, returning the number of bytes
/// written. `dst` must be large enough to hold the entire decompressed output.
///
/// Decodes standard `lzo1x_*` streams (no kernel bitstream-version extension).
pub fn decompress_into(src: &[u8], dst: &mut [u8]) -> Result<usize, Error> {
    if src.len() < 3 {
        return Err(Error::InputOverrun);
    }
    let mut ip = 0usize;
    let mut op = 0usize;
    let mut state: usize;
    let mut t: usize;

    // First instruction: a first byte > 17 is an initial literal run of
    // `byte - 17` (1..3 of them behave like a prior op's trailing literals).
    let first = src[0];
    if first > 17 {
        ip = 1;
        t = first as usize - 17;
        copy_literals(src, &mut ip, dst, &mut op, t)?;
        state = if t < 4 { t } else { 4 };
    } else {
        state = 0; // first byte is read as an ordinary instruction below
    }

    loop {
        t = rd(src, &mut ip)? as usize;
        let (distance, length, next);
        if t < 16 {
            if state == 0 {
                // Literal run: length t+3, with the zero-byte extension (base 18).
                let len = if t == 0 {
                    length_ext(src, &mut ip)?.saturating_add(18)
                } else {
                    t + 3
                };
                copy_literals(src, &mut ip, dst, &mut op, len)?;
                state = 4;
                continue;
            }
            // state > 0: a short match from a near distance.
            next = t & 3;
            if state == 4 {
                distance = 1 + 2048 + (t >> 2) + ((rd(src, &mut ip)? as usize) << 2);
                length = 3;
            } else {
                distance = 1 + (t >> 2) + ((rd(src, &mut ip)? as usize) << 2);
                length = 2;
            }
        } else if t >= 64 {
            // M2: short match, 3 distance bits in `t` + one follow byte.
            next = t & 3;
            distance = 1 + ((t >> 2) & 7) + ((rd(src, &mut ip)? as usize) << 3);
            length = (t >> 5) + 1;
        } else if t >= 32 {
            // M3: length in low 5 bits (base 2 / extension base 33), le16 distance.
            length = if (t & 31) == 0 {
                length_ext(src, &mut ip)?.saturating_add(33)
            } else {
                (t & 31) + 2
            };
            let d = rd_le16(src, &mut ip)?;
            distance = 1 + (d >> 2);
            next = d & 3;
        } else {
            // M4 (16..=31): long match, or the end-of-stream marker.
            let hi = (t & 8) << 11;
            length = if (t & 7) == 0 {
                length_ext(src, &mut ip)?.saturating_add(9)
            } else {
                (t & 7) + 2
            };
            let d = rd_le16(src, &mut ip)?;
            let dist_part = d >> 2;
            next = d & 3;
            if hi == 0 && dist_part == 0 {
                // End of stream (canonical marker `0x11 0x00 0x00`).
                if length != 3 {
                    return Err(Error::Malformed);
                }
                if ip < src.len() {
                    return Err(Error::InputNotConsumed);
                }
                return Ok(op);
            }
            distance = hi + dist_part + 0x4000;
        }
        copy_match(dst, &mut op, distance, length)?;
        copy_literals(src, &mut ip, dst, &mut op, next)?;
        state = next;
    }
}

/// Decompress a raw LZO1X block, allocating an output of at most `max_len`
/// bytes. Returns the decompressed data.
#[cfg(feature = "alloc")]
pub fn decompress(src: &[u8], max_len: usize) -> Result<alloc::vec::Vec<u8>, Error> {
    let mut dst = alloc::vec![0u8; max_len];
    let n = decompress_into(src, &mut dst)?;
    dst.truncate(n);
    Ok(dst)
}
