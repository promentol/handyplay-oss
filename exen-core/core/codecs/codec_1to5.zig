//! ExEn IDAT decoders for codecs 1, 2, 3, 4 (codec 5 lives in png.zig).
//!
//! Faithful line-by-line ports of:
//!   sub_4318F6  (codec 1 step)   — ref:31471
//!   sub_42F724  (codec 2 step)   — ref:30908
//!   sub_42D960  (codec 3 step)   — ref:30293
//!   sub_432180+ (codec 4)        — ref:31644
//!
//! Common helpers:
//!   sub_412EA0  (read N bits)    — ref:14983
//!   sub_413071  (write N bits)   — ref:15003
//!   sub_432D20  (header unpack)  — ref:31893
//!   sub_432E03  (output bits)    — ref:31908
//!
//! The codecs are streaming: they're driven by a "step" function that
//! decodes some chunk of input bits into some chunk of output bits.
//! For our use we just call them once with the whole IDAT and a
//! pre-sized output buffer.

const std = @import("std");

pub const Error = error{
    Truncated,
    BadIdat,
    OutOfMemory,
    UnsupportedCodec,
};

// ── bit IO ────────────────────────────────────────────────────────────────

/// `sub_412EA0`: read `n` bits big-endian-within-byte starting at bit
/// `pos.*`, advancing `pos` by `n`. Mirrors the C exactly:
/// ```
/// v4 = *a2 & 7;
/// v6 = (a1 >> 3) + a2;
/// v5 = (1 << a3) - 1;
/// *a2 += a3;
/// if (v4 + a3 <= 8)   return v5 & (*v6 >> (8 - v4 - a3));
/// if (v4 + a3 <= 16)  return v5 & (((*v6 << 8) | v6[1]) >> (16 - v4 - a3));
/// if (v4 + a3 >  32)  return ~((1 << (v4+a3-32)) - 1)
///                          & (bswap32(v6[1]) >> (32 - (v4+a3-32)))
///                          | (4 * (v5 & (bswap32(v6[0]) << (v4+a3-32))));
///                    return v5 & (bswap32(v6[0]) >> (32 - v4 - a3));
/// ```
pub fn readBits(buf: []const u8, pos: *u32, n: u5) u32 {
    const bit_off: u32 = pos.* & 7;
    const byte_off: u32 = pos.* >> 3;
    const total = bit_off + @as(u32, n);
    const mask: u32 = (@as(u32, 1) << n) - 1;
    pos.* += n;
    const b0: u32 = if (byte_off < buf.len) buf[byte_off] else 0;
    if (total <= 8) return mask & (b0 >> @intCast(8 - bit_off - n));
    const b1: u32 = if (byte_off + 1 < buf.len) buf[byte_off + 1] else 0;
    if (total <= 16) {
        const word: u32 = (b0 << 8) | b1;
        return mask & (word >> @intCast(16 - bit_off - n));
    }
    const b2: u32 = if (byte_off + 2 < buf.len) buf[byte_off + 2] else 0;
    const b3: u32 = if (byte_off + 3 < buf.len) buf[byte_off + 3] else 0;
    const word4_be: u32 = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    if (total <= 32) return mask & (word4_be >> @intCast(32 - bit_off - n));
    // >32-bit span — read next u32 too. Simpler equivalent than the
    // bswap+shift dance in the C: concatenate 64 bits of input and
    // extract via shift+mask.
    const b4: u64 = if (byte_off + 4 < buf.len) buf[byte_off + 4] else 0;
    const b5: u64 = if (byte_off + 5 < buf.len) buf[byte_off + 5] else 0;
    const b6: u64 = if (byte_off + 6 < buf.len) buf[byte_off + 6] else 0;
    const b7: u64 = if (byte_off + 7 < buf.len) buf[byte_off + 7] else 0;
    const word8: u64 = (@as(u64, word4_be) << 32) | (b4 << 24) | (b5 << 16) | (b6 << 8) | b7;
    const shift: u6 = @intCast(64 - bit_off - n);
    return @intCast(mask & @as(u32, @truncate(word8 >> shift)));
}

/// `sub_413071`: write `n` bits of `value` into `buf` at bit `pos.*`,
/// advancing `pos`. The destination bits may or may not be clear;
/// the simulator overlays (OR-style mask).
pub fn writeBits(buf: []u8, pos: *u32, value: u32, n: u5) void {
    if (n == 0) return;
    const bit_off: u32 = pos.* & 7;
    const byte_off: u32 = pos.* >> 3;
    const total = bit_off + @as(u32, n);
    const mask: u32 = (@as(u32, 1) << n) - 1;
    pos.* += n;
    const v = value & mask;
    // End-of-buffer safety: each branch touches multiple bytes whose
    // indices may exceed `buf.len-1` when the final partial write lands
    // exactly at the buffer end. The trailing bytes carry only bits we
    // never actually modify (the OR-mask preserves them), so it's safe
    // to treat out-of-range reads as 0 and skip out-of-range writes —
    // matches `readBits`'s bounds handling at lines 65-68. Without this
    // guard, codec-2 decode panics when the IDAT's final code_width
    // straddles the last buffer byte.
    if (total <= 8) {
        const shift: u5 = @intCast(8 - bit_off - n);
        const cur: u32 = buf[byte_off];
        const new: u32 = (cur & ~(mask << shift)) | (v << shift);
        buf[byte_off] = @intCast(new & 0xFF);
        return;
    }
    if (total <= 16) {
        const shift: u5 = @intCast(16 - bit_off - n);
        const b1: u32 = if (byte_off + 1 < buf.len) buf[byte_off + 1] else 0;
        const cur: u32 = (@as(u32, buf[byte_off]) << 8) | b1;
        const new: u32 = (cur & ~(mask << shift)) | (v << shift);
        buf[byte_off] = @intCast((new >> 8) & 0xFF);
        if (byte_off + 1 < buf.len) buf[byte_off + 1] = @intCast(new & 0xFF);
        return;
    }
    if (total <= 32) {
        const shift: u5 = @intCast(32 - bit_off - n);
        var cur: u32 = 0;
        for (0..4) |i| {
            const idx = byte_off + i;
            const b: u32 = if (idx < buf.len) buf[idx] else 0;
            cur = (cur << 8) | b;
        }
        const new: u32 = (cur & ~(mask << shift)) | (v << shift);
        buf[byte_off] = @intCast((new >> 24) & 0xFF);
        if (byte_off + 1 < buf.len) buf[byte_off + 1] = @intCast((new >> 16) & 0xFF);
        if (byte_off + 2 < buf.len) buf[byte_off + 2] = @intCast((new >> 8) & 0xFF);
        if (byte_off + 3 < buf.len) buf[byte_off + 3] = @intCast(new & 0xFF);
        return;
    }
    // > 32-bit span — split.
    const top: u5 = @intCast(32 - bit_off);
    const bot: u5 = @intCast(n - top);
    var p = pos.* - n;
    writeBits(buf, &p, value >> bot, top);
    writeBits(buf, &p, value & ((@as(u32, 1) << bot) - 1), bot);
}

/// `sub_432D20`: bit-pack the 9-byte IDAT header bytes [0..9] into
/// two u32s, each holding 36 bits worth of data.
pub fn unpackHeader36(idat: []const u8) struct { a: u32, b: u32 } {
    if (idat.len < 9) return .{ .a = 0, .b = 0 };
    const a: u32 =
        ((@as(u32, idat[4]) & 0xF0) >> 4) |
        (@as(u32, idat[3]) << 4) |
        (@as(u32, idat[2]) << 12) |
        (@as(u32, idat[1]) << 20) |
        ((@as(u32, idat[0]) & 0xF) << 28);
    const b: u32 =
        ((@as(u32, idat[8]) & 0xF0) >> 4) |
        (@as(u32, idat[7]) << 4) |
        (@as(u32, idat[6]) << 12) |
        (@as(u32, idat[5]) << 20) |
        ((@as(u32, idat[4]) & 0xF) << 28);
    return .{ .a = a, .b = b };
}

/// `sub_432E03`: output-bits count for the codec. Round `a` up to
/// the next multiple of 8 bits, multiply by `b`.
pub fn outputBits(idat: []const u8) u32 {
    const h = unpackHeader36(idat);
    const rounded: u32 = (h.a + 7) & 0xFFFFFFF8;
    return rounded *% h.b;
}

// ── codec 1 — LRU-palette literal coding ─────────────────────────────────
//
// State layout (1052 bytes) — only the fields we read/write:
//   +0   u32  read_pos (bit cursor in source)
//   +4   u8   pending_bits left-over
//   +6   u16  pending_value
//   +8   u32  remaining_bits in stream
//   +12  ptr  source data pointer (set by host)
//   +16  u16  palette_count (5-bit field)
//   +18  u16  code_bits (5-bit field)
//   +20  ptr  palette table (2*palette_count u16 entries)
//   +24..1047  1024-byte ring buffer for overlapping I/O
//
// Algorithm: each symbol is 1 bit selector + (5-bit palette index OR
// code_bits literal). On literal, replace the LAST palette slot.
// After emit, the palette is LRU-rotated so the just-used slot moves
// to the front.

const Codec1 = struct {
    bit_pos: u32 = 68, // 9 IDAT header bytes = 72 bits; -4 to align after codec nibble
    pending_bits: u8 = 0,
    pending_value: u16 = 0,
    remaining_bits: u32 = 0,
    code_bits: u8 = 0,
    palette_count: u8 = 0,
    palette: [32]u16 = .{0} ** 32,
};

/// Init (sub_431750): allocate state, read palette_count, code_bits.
fn codec1Init(idat: []const u8) !Codec1 {
    if (idat.len < 12) return Error.Truncated;
    var st: Codec1 = .{};
    st.bit_pos = 68;
    st.remaining_bits = outputBits(idat);
    const pc = readBits(idat, &st.bit_pos, 5);
    const cb = readBits(idat, &st.bit_pos, 5);
    if (pc == 0 or pc > 32) return Error.BadIdat;
    if (cb == 0 or cb > 16) return Error.BadIdat;
    st.palette_count = @intCast(pc);
    st.code_bits = @intCast(cb);
    return st;
}

/// One-shot decode (drives sub_4318F6 to completion).
pub fn decodeCodec1(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    var st = try codec1Init(idat);
    const total_bytes = st.remaining_bits >> 3;
    if (total_bytes == 0) return error.BadIdat;
    const out = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    var w_pos: u32 = 0;
    var write_budget: u32 = total_bytes * 8;

    // Drain pending_bits — first call has none.
    while (st.remaining_bits >= st.code_bits and write_budget >= st.code_bits) {
        const flag = readBits(idat, &st.bit_pos, 1);
        var code: u32 = 0;
        var palette_slot: u32 = 0;
        if (flag == 1) {
            palette_slot = readBits(idat, &st.bit_pos, 5);
            if (palette_slot >= st.palette_count) return Error.BadIdat;
            code = st.palette[palette_slot];
        } else {
            // Literal — read code_bits bits as a multi-byte big-endian
            // value (matches the do-once `while (v8--)` loop in
            // sub_4318F6 lines 31537-31548 which does an 8-bit-then-
            // remainder split then rewinds and re-reads as a unit).
            const cb: u5 = @intCast(st.code_bits);
            code = readBits(idat, &st.bit_pos, cb);
            palette_slot = st.palette_count - 1;
        }
        // LRU rotate.
        var k: u32 = palette_slot;
        while (k > 0) : (k -= 1) st.palette[k] = st.palette[k - 1];
        st.palette[0] = @intCast(code);

        writeBits(out, &w_pos, code, @intCast(st.code_bits));
        st.remaining_bits -= st.code_bits;
        write_budget -= st.code_bits;
    }

    // Trailing partial bits.
    while (st.remaining_bits >= 8 and write_budget >= 8) {
        const v = readBits(idat, &st.bit_pos, 8);
        writeBits(out, &w_pos, v, 8);
        st.remaining_bits -= 8;
        write_budget -= 8;
    }
    if (st.remaining_bits != 0 and write_budget != 0) {
        const m: u5 = @intCast(@min(st.remaining_bits, write_budget));
        const v = readBits(idat, &st.bit_pos, m);
        writeBits(out, &w_pos, v, m);
    }

    return out;
}

// ── codec 2 — 1-bit run-length on a single code width ────────────────────
//
// Setup (sub_42F560 @ ref:30855):
//   code_width = readBits(4)
//   total_out_bits = outputBits(idat)
//   last_value = 0   (state+16)
//
// Step (sub_42F724 @ ref:30907): each iteration reads a 1-bit
// tag. tag==1 → read `code_width` bits, that's the new symbol. tag==0
// → reuse the previous symbol. Either way, emit `code_width` bits.
// Tail: copy remaining bits 8-at-a-time as raw bytes.
const Codec2 = struct {
    bit_pos: u32 = 0,
    pending_bits: u8 = 0,
    pending_value: u32 = 0,
    last_value: u32 = 0,
    code_width: u32 = 0,
    remaining_out_bits: u32 = 0,
};

fn codec2Init(idat: []const u8) !Codec2 {
    if (idat.len < 12) return Error.Truncated;
    var st: Codec2 = .{};
    st.bit_pos = 68; // skip 8-byte header + codec nibble
    st.remaining_out_bits = outputBits(idat);
    st.code_width = readBits(idat, &st.bit_pos, 4);
    if (st.code_width == 0 or st.code_width > 16) return Error.BadIdat;
    return st;
}

pub fn decodeCodec2(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    var st = try codec2Init(idat);
    const total_bytes = st.remaining_out_bits >> 3;
    if (total_bytes == 0) return Error.BadIdat;
    const out = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    var w_pos: u32 = 0;
    var write_budget: u32 = total_bytes * 8;

    while (st.remaining_out_bits >= st.code_width and write_budget >= st.code_width) {
        const tag = readBits(idat, &st.bit_pos, 1);
        if (tag == 1) {
            st.last_value = readBits(idat, &st.bit_pos, @intCast(st.code_width));
        }
        writeBits(out, &w_pos, st.last_value, @intCast(st.code_width));
        st.remaining_out_bits -= st.code_width;
        write_budget -= st.code_width;
    }

    // Trailing: emit remaining bits as raw 8-bit chunks (no tag).
    while (st.remaining_out_bits >= 8 and write_budget >= 8) {
        const v = readBits(idat, &st.bit_pos, 8);
        writeBits(out, &w_pos, v, 8);
        st.remaining_out_bits -= 8;
        write_budget -= 8;
    }
    if (st.remaining_out_bits != 0 and write_budget != 0) {
        const m: u5 = @intCast(@min(st.remaining_out_bits, write_budget));
        const v = readBits(idat, &st.bit_pos, m);
        writeBits(out, &w_pos, v, m);
    }
    return out;
}

// ── codec 3 — multi-pass row coding with 10-entry RLE table ─────────────
//
// Setup (sub_42D500 @ ref:30221):
//   block_w  = readBits(4)         // sample width in bits
//   field2   = readBits(4)         // passes per row (palette planes)
//   v37      = block_w * field2    // raw-mode bit count
//   total_out_bits = outputBits(idat)
//   row_w_bits = ((unpacked.a + 7) >> 3) * 8
//   total_bits = unpacked.b * row_w_bits
//   if (unpacked.b & 1) and field2==2: total_bits -= row_w_bits
//   table[10]: each entry is a (field2 * row_w_bits)-bit value read raw
//   bit_pos points just past the table
//
// Step (sub_42D960 @ ref:30293): decode each (block_w * field2)
// bits of input into block_w bits of output, interleaving field2 passes
// per row. For each sample: read 2-bit tag; tag in {0,1} → table[tag];
// tag==2 → 3 more bits → table[v+2]; tag==3 → v37 raw bits.
const Codec3 = struct {
    bit_pos: u32 = 68, // 9 IDAT header bytes
    pending_bits: u32 = 0,
    pending_value: u32 = 0,
    total_out_bits: u32 = 0,
    row_w_bits: u32 = 0,
    remaining_out_bits: u32 = 0,
    field2: u32 = 0, // passes per row
    block_w: u32 = 0, // bits per sample
    row_remaining: u32 = 0,
    row_pass: u32 = 0, // 1..field2
    saved_row_pos: u32 = 0,
    table: [10]u32 = .{0} ** 10,
    raw_bits: u32 = 0, // = block_w * field2
};

fn codec3Init(idat: []const u8) !Codec3 {
    if (idat.len < 12) return Error.Truncated;
    var st: Codec3 = .{};
    st.bit_pos = 68;

    const hdr = unpackHeader36(idat);
    st.total_out_bits = outputBits(idat);
    st.block_w = readBits(idat, &st.bit_pos, 4);
    st.field2 = readBits(idat, &st.bit_pos, 4);
    if (st.block_w == 0 or st.field2 == 0) return Error.BadIdat;
    if (st.block_w > 16 or st.field2 > 8) return Error.BadIdat;

    st.raw_bits = st.block_w * st.field2;
    st.row_w_bits = ((hdr.a + 7) >> 3) * 8;
    st.remaining_out_bits = hdr.b * st.row_w_bits;
    if ((hdr.b & 1) != 0 and st.field2 == 2) st.remaining_out_bits -= st.row_w_bits;

    // Read the 10-entry RLE table: each entry holds `raw_bits` bits
    // (= block_w * field2). The C in sub_42D500 reads it via an 8-bit
    // loop with weird rewind/restore — net equivalent to one
    // raw_bits-wide extract per entry.
    if (st.raw_bits > 16) return Error.BadIdat;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        st.table[i] = readBits(idat, &st.bit_pos, @intCast(st.raw_bits));
    }
    // After table init, the bit_pos becomes the saved "start of row" pos.
    st.saved_row_pos = st.bit_pos;
    st.row_remaining = st.row_w_bits;
    st.row_pass = 1;
    return st;
}

pub fn decodeCodec3(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    var st = try codec3Init(idat);
    const total_bytes = st.remaining_out_bits >> 3;
    if (total_bytes == 0) return Error.BadIdat;
    const out = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    var w_pos: u32 = 0;
    var write_budget: u32 = total_bytes * 8;

    while (st.remaining_out_bits != 0 and write_budget != 0) {
        var v32: u32 = 0;
        var emit_bits: u32 = st.block_w;

        if (st.row_remaining < st.block_w) {
            // Tail of a row pass: emit only `row_remaining` bits using
            // the same read formula, then advance.
            const read_bits = st.field2 * st.row_remaining;
            const raw = readBits(idat, &st.bit_pos, @intCast(read_bits));
            const shift_amount: u5 = @intCast((st.field2 -% st.row_pass) * st.row_remaining);
            v32 = ((@as(u32, 1) << @intCast(st.row_remaining)) - 1) & (raw >> shift_amount);
            emit_bits = st.row_remaining;
            st.remaining_out_bits -%= st.row_remaining;
            st.row_remaining = 0;
        } else {
            const tag = readBits(idat, &st.bit_pos, 2);
            var raw: u32 = 0;
            if (tag <= 1) {
                raw = st.table[tag];
            } else if (tag == 2) {
                const sub = readBits(idat, &st.bit_pos, 3);
                if (sub + 2 >= st.table.len) return Error.BadIdat;
                raw = st.table[sub + 2];
            } else {
                raw = readBits(idat, &st.bit_pos, @intCast(st.raw_bits));
            }
            const shift_amount: u5 = @intCast((st.field2 -% st.row_pass) * st.block_w);
            v32 = ((@as(u32, 1) << @intCast(st.block_w)) - 1) & (raw >> shift_amount);
            st.remaining_out_bits -%= st.block_w;
            st.row_remaining -%= st.block_w;
        }

        if (write_budget < emit_bits) {
            // Save partial.
            st.pending_bits = emit_bits - write_budget;
            if (write_budget != 0) {
                const shift: u5 = @intCast(st.pending_bits);
                writeBits(out, &w_pos, v32 >> shift, @intCast(write_budget));
            }
            st.pending_value = v32 & ((@as(u32, 1) << @intCast(st.pending_bits)) - 1);
            break;
        }
        writeBits(out, &w_pos, v32, @intCast(emit_bits));
        write_budget -= emit_bits;

        // End-of-row handling: cycle through `field2` passes per row,
        // rewinding the read cursor on all but the last pass.
        if (st.row_remaining == 0) {
            st.row_remaining = st.row_w_bits;
            st.row_pass += 1;
            if (st.row_pass <= st.field2) {
                st.bit_pos = st.saved_row_pos;
            } else {
                st.row_pass = 1;
                st.saved_row_pos = st.bit_pos;
            }
        }
    }

    return out;
}

// ── codec 4 — binary run-length encoding ─────────────────────────────────
//
// Setup (sub_432180 @ ref:31643): single 4-bit code_width field
// after the header.
// Step (sub_43228B @ ref:31673): each iteration reads
// `code_width` bits as a sign+count pair. Top bit = which byte to
// emit (0x00 or 0xFF); low (code_width-1) bits = number of OUTPUT
// bits to fill with that byte.
const Codec4 = struct {
    bit_pos: u32 = 0,
    pending_bits: u8 = 0,
    pending_value: u8 = 0,
    code_width: u32 = 0,
    remaining_out_bits: u32 = 0,
};

fn codec4Init(idat: []const u8) !Codec4 {
    if (idat.len < 12) return Error.Truncated;
    var st: Codec4 = .{};
    st.bit_pos = 68;
    st.remaining_out_bits = outputBits(idat);
    st.code_width = readBits(idat, &st.bit_pos, 4);
    if (st.code_width < 2 or st.code_width > 16) return Error.BadIdat;
    return st;
}

pub fn decodeCodec4(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    var st = try codec4Init(idat);
    const total_bytes = st.remaining_out_bits >> 3;
    if (total_bytes == 0) return Error.BadIdat;
    const out = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    var w_pos: u32 = 0;
    var write_budget: u32 = total_bytes * 8;
    const high_bit: u32 = @as(u32, 1) << @intCast(st.code_width - 1);
    const count_mask: u32 = high_bit - 1;

    while (st.remaining_out_bits != 0 and write_budget != 0) {
        const v = readBits(idat, &st.bit_pos, @intCast(st.code_width));
        const emit_byte: u32 = if (v >= high_bit) 0xFF else 0;
        var count: u32 = if (v >= high_bit) (v & count_mask) else v;
        if (count == 0) break;

        if (st.remaining_out_bits < count) count = st.remaining_out_bits;
        st.remaining_out_bits -= count;

        // Emit 8-at-a-time then remainder.
        while (count >= 8 and write_budget >= 8) {
            writeBits(out, &w_pos, emit_byte, 8);
            count -= 8;
            write_budget -= 8;
        }
        if (count != 0) {
            const n: u5 = @intCast(@min(count, write_budget));
            // Top `n` bits of the 8-bit byte.
            const top_n: u32 = emit_byte >> @intCast(8 - n);
            writeBits(out, &w_pos, top_n, n);
            count -= n;
            write_budget -= n;
            if (count != 0) {
                // Out of room — save the rest as pending.
                st.pending_value = @intCast(emit_byte);
                st.pending_bits = @intCast(count);
                break;
            }
        }
    }
    return out;
}

test "readBits round-trip" {
    var buf: [16]u8 = .{0} ** 16;
    var wp: u32 = 0;
    writeBits(&buf, &wp, 0x5, 3);
    writeBits(&buf, &wp, 0x2A, 6);
    writeBits(&buf, &wp, 0x123, 10);
    var rp: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0x5), readBits(&buf, &rp, 3));
    try std.testing.expectEqual(@as(u32, 0x2A), readBits(&buf, &rp, 6));
    try std.testing.expectEqual(@as(u32, 0x123), readBits(&buf, &rp, 10));
}
