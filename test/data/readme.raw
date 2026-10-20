# lzo

[![Crates.io](https://img.shields.io/crates/v/lzo.svg)](https://crates.io/crates/lzo)
[![Docs.rs](https://docs.rs/lzo/badge.svg)](https://docs.rs/lzo)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/SecurityRonin/lzo/actions/workflows/ci.yml/badge.svg)](https://github.com/SecurityRonin/lzo/actions/workflows/ci.yml)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2.svg)](https://github.com/sponsors/h4x0r)

**The GPL-free, safe, `no_std` pure-Rust LZO1X decompressor.** Decode `lzo1x` data — from `lzop` files, the Linux kernel/initramfs, btrfs, or any tool built on liblzo2 — with zero C, zero dependencies, and `#![forbid(unsafe_code)]`.

```rust
// "hello, lzo world!" as a raw LZO1X block (from liblzo2's lzo1x_1).
let block = [34, 104,101,108,108,111,44,32,108,122,111,32,119,111,114,108,100,33, 17,0,0];
let mut out = [0u8; 17];                 // you supply the output capacity
let n = lzo::decompress_into(&block, &mut out).unwrap();
assert_eq!(&out[..n], b"hello, lzo world!");
```

That's it: hand it a raw block and a big-enough buffer, get the bytes back.

## Why this crate

Pure-Rust LZO ports already exist — but the mature ones (`rust-lzo`, `lzo1x`) are **GPL-2.0**, which can't be linked into an MIT/Apache project, and the MIT alternatives wrap C or are early-stage. `lzo` fills that gap:

| | C `liblzo2` | other Rust ports | **`lzo`** |
|---|---|---|---|
| Language / linkage | C | mixed | pure Rust, no C |
| `unsafe` | — | varies | **`#![forbid(unsafe_code)]`** |
| License | GPL/commercial | mostly GPL | **MIT** |
| `no_std` | — | varies | ✅ (`decompress_into`) |
| Dependencies | — | varies | **zero** |
| Validated against liblzo2 | — | varies | ✅ round-trip vectors |

It decodes streams from every `lzo1x` compressor variant (`lzo1x_1`, `lzo1x_1_15`, `lzo1x_999`) — they share one decompressor. Hardened against malformed input: bounds-checked, never panics, returns a typed [`Error`].

## Scope

- **Decompression only** (v1). Like `ruzstd`/`bzip2-rs`, this is a decoder; raw LZO1X has no container, so you supply the output capacity (mirroring C `lzo1x_decompress_safe`).
- Standard `lzo1x` streams. The kernel's bitstream-version (RLE) extension is out of scope.

## Correctness

Every release is round-trip tested against vectors produced by the **reference C `liblzo2` `lzo1x_1_compress`** (covering literals, the zero-byte length extension, M1–M4 matches, overlapping copies, and the end-of-stream marker), plus malformed-input tests asserting no panic on arbitrary bytes.

[Privacy Policy](https://securityronin.github.io/lzo/privacy/) · [Terms of Service](https://securityronin.github.io/lzo/terms/) · © 2026 Security Ronin Ltd
