//! exen.Sms — native funcs_407AA2[] indices 89..100
//!
//! Hash 0x6bddc5b7. SMS message composer (bit-stream API). The canonical
//! SMS state lives in a 148-byte heap buffer (`sub_42989D` returns it).
//! Layout per `sub_4215FA` (ref:23042):
//!
//!   bytes[0..4]   = signature "EXEN" (0x4558454E)
//!   bytes[4..139] = bit-stream payload (~135 bytes = 1080 bits)
//!   bytes[139]    = checksum (sum of payload bytes, low byte)
//!   bytes[144..]  = bit-position cursor (u32 little-endian) — number of
//!                   bits written / read so far. `(buf+4)` is the data
//!                   region; `(buf+144)` is the cursor pointer.
//!
//! Block state lives on the Sms instance itself (canonical `a2[9..12]`):
//!   slot 9  = block_start_bit_pos
//!   slot 10 = block_id (first byte written into the block)
//!   slot 11 = (reserved)
//!   slot 12 = (reserved)
//!
//! We use synthetic field hashes for both the buffer handle and the
//! 4 block-state slots since the canonical instance is offset-keyed
//! and we don't have authoritative name→hash pairing for the Sms class.
//!
//! Currently ported: idx 89, 90, 92, 95 (the four Pikubi exercises at
//! startup). idx 91/93/94/96..100 still delegate to `defaultNativeStub`.

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 89;
pub const last_index: u32 = 100;

// Synthetic hashes for SMS state — the gamelet never reads/writes these
// via PUTFIELD/GETFIELD, so a private namespace is safe.
const FIELD_SMS_BUF:        u32 = 0xC0FFEE20; // byte[] handle (the 148-byte buffer)
const FIELD_BLOCK_START:    u32 = 0xC0FFEE21; // a2[9]  — block_start_bit_pos
const FIELD_BLOCK_ID:       u32 = 0xC0FFEE22; // a2[10] — block ID byte
const FIELD_BLOCK_RES1:     u32 = 0xC0FFEE23; // a2[11]
const FIELD_BLOCK_RES2:     u32 = 0xC0FFEE24; // a2[12]

const SMS_BUF_LEN: usize = 0x94;   // 148 bytes
const SMS_PAYLOAD_OFF: usize = 4;  // bit-stream data starts here
const SMS_CURSOR_OFF: usize = 144; // u32 bit-cursor at +144

/// Port of sub_42989D (ref:27785) — fetch the SMS buffer slice
/// on this instance, allocating it on first access. Returns null when
/// the heap is exhausted or the instance is missing.
fn smsBuffer(vm: *Vm, this: Handle) ?[]u8 {
    const inst = vm.heap.get(this) orelse return null;
    // First call: allocate the buffer + register on instance.
    if (inst.bytes == null) {
        const buf = vm.allocator.alloc(u8, SMS_BUF_LEN) catch return null;
        @memset(buf, 0);
        inst.bytes = buf;
        // Also write the synthetic-hash field so other lookups (if we
        // add any) see a non-zero handle.
        inst.field_map.put(FIELD_SMS_BUF, this) catch {};
    }
    return inst.bytes;
}

fn cursorAt(buf: []u8) u32 {
    if (SMS_CURSOR_OFF + 4 > buf.len) return 0;
    return std.mem.readInt(u32, buf[SMS_CURSOR_OFF..][0..4], .little);
}

fn setCursor(buf: []u8, v: u32) void {
    if (SMS_CURSOR_OFF + 4 > buf.len) return;
    std.mem.writeInt(u32, buf[SMS_CURSOR_OFF..][0..4], v, .little);
}

/// Port of sub_413071 (ref:15004) — write `n_bits` of `value` to
/// `buf` at `*cursor`, then advance `*cursor` by `n_bits`. Canonical
/// uses MSB-first packing inside each byte (the `(8 - bit_off - n)`
/// shift). Returns 1 on success (canonical signature).
fn writeBits(buf: []u8, cursor: *u32, value: u32, n_bits: u5) i32 {
    const start_bit = cursor.*;
    cursor.* = start_bit + @as(u32, n_bits);
    if (n_bits == 0) return 1;
    var i: u5 = 0;
    while (i < n_bits) : (i += 1) {
        const bit_idx = start_bit + (n_bits - 1 - i); // MSB first
        const byte_idx: usize = bit_idx / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_idx & 7));
        if (byte_idx >= buf.len) return -1;
        const bit_val: u8 = @truncate((value >> i) & 1);
        const mask: u8 = @as(u8, 1) << bit_in_byte;
        if (bit_val != 0) buf[byte_idx] |= mask else buf[byte_idx] &= ~mask;
    }
    return 1;
}

/// Port of sub_412EA0 (ref:14983) — read `n_bits` from `buf` at
/// `*cursor`, advance `*cursor` by `n_bits`, return the value (unsigned
/// zero-extended). MSB-first packing matches `writeBits`.
fn readBits(buf: []const u8, cursor: *u32, n_bits: u5) u32 {
    const start_bit = cursor.*;
    cursor.* = start_bit + @as(u32, n_bits);
    if (n_bits == 0) return 0;
    var v: u32 = 0;
    var i: u5 = 0;
    while (i < n_bits) : (i += 1) {
        const bit_idx = start_bit + i;
        const byte_idx: usize = bit_idx / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_idx & 7));
        if (byte_idx >= buf.len) return v;
        const bit_val: u32 = (@as(u32, buf[byte_idx]) >> bit_in_byte) & 1;
        v = (v << 1) | bit_val;
    }
    return v;
}

/// Port of sub_421982 (ref:23115) — write 8 bits of `v` at the
/// SMS buffer's cursor and advance the cursor. Used by every SMS header
/// builder routine.
fn writeByteToSms(buf: []u8, v: u32) void {
    var cur = cursorAt(buf);
    _ = writeBits(buf, &cur, v, 8);
    setCursor(buf, cur);
}

/// Port of sub_421B36 (ref:23172) — write an 11-bit count
/// (`v>>8` as 3 bits + `v` low byte as 8 bits). Used to write block-
/// length fields back into the header reservation area.
fn writeBlockCount(buf: []u8, v: u32) void {
    var cur = cursorAt(buf);
    _ = writeBits(buf, &cur, v >> 8, 3);
    _ = writeBits(buf, &cur, v, 8);
    setCursor(buf, cur);
}

// ── [89] sub_429A18 — Sms.deleteSms() → void ───────────────────────────────
// Canonical (ref:27848):
//   __int16 sub_429A18() { return 0; }
// Literally empty. The "delete" semantic is on the JVM side: ExEn just
// drops the GETFIELD-resolved Sms ref (refcount + GC); the native does
// nothing. Counter-intuitive vs `createSms` (idx 90) which is where the
// state-clearing work actually happens. Name resolved from extracted
// SMS class docs: method-table row 2 (argc=0, void) matches the strings
// region's row 31 `deleteSms` (argc=0, void).
fn deleteSms(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [90] sub_4298C8 — Sms.createSms() ─────────────────────────────────────
// Canonical (ref:27799):
//   v3 = sub_42989D(this);              // get the 148-byte buffer
//   if ( v3 ) {
//     v3[36] = 0;                        // cursor = 0
//     sub_4215FA(v3);                    // write canonical "EXEN" header
//                                        // + IMSI + date + dev info
//                                        // (~160 bits written)
//     sub_421982(v3, 0x60);              // write 0x60 as 8 bits
//     sub_421B36(v3, 0);                 // write 11-bit count = 0
//     sub_429870(this_instance);         // zero a2[9..12]
//   }
//   return 0;
//
// We can't fully reproduce sub_4215FA without porting IMSI lookup
// (sub_4375D3) + device-config (dword_45FE8C); for Pikubi the SMS
// payload is never read back, so we keep cursor advancement faithful
// (~20 bytes = 160 bits of header data, then 8 + 11 = 19 bits more)
// and zero a2[9..12] via the synthetic hashes.
fn ctorOrReset(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const buf = smsBuffer(vm, this) orelse return 0;
    // sub_4041B1(a1, 0, 0x94) — full buffer zero (called as first step
    // inside sub_4215FA).
    @memset(buf, 0);
    // v3[36] = 0 — cursor reset (no-op after memset, but explicit).
    setCursor(buf, 0);
    // sub_4215FA writes the canonical header bits (signature + IMSI
    // bytes + device config + date/time + manufacturer) and ends with
    // `*((_DWORD *)a1 + 36) += 20;`. With our buffer all-zeros and the
    // device-config inputs all zero, every writeBits call would be a
    // no-op (writing 0 bits into 0 bytes); only the signature bytes
    // and the cursor advance are observable. So we shortcut to:
    //   bytes[0..4] = "EXEN"
    //   cursor = 128   (= 108 content bits + 20 padding)
    buf[0] = 'E'; buf[1] = 'X'; buf[2] = 'E'; buf[3] = 'N';
    setCursor(buf, 128);
    // sub_421982(v3, 0x60): write 8 bits of 0x60 at cursor (→ 136).
    writeByteToSms(buf, 0x60);
    // sub_421B36(v3, 0): write 11 zero bits (→ 147).
    writeBlockCount(buf, 0);
    // sub_429870(a2): zero a2[9..12] on the Sms instance.
    if (vm.heap.get(this)) |inst| {
        inst.field_map.put(FIELD_BLOCK_START, 0) catch {};
        inst.field_map.put(FIELD_BLOCK_ID, 0) catch {};
        inst.field_map.put(FIELD_BLOCK_RES1, 0) catch {};
        inst.field_map.put(FIELD_BLOCK_RES2, 0) catch {};
    }
    return 0;
}

// ── [92] sub_429A20 — Sms.createBlock(block_id) ─────────────────────────────
// Canonical (ref:27854):
//   v3 = sub_42989D(this);
//   if ( !v3 || v3[36] > 0x42D ) return 0;        // buffer full
//   a2[9]  = v3[36];                              // remember block start
//   a2[10] = (char) a1[1];                        // block_id (low byte)
//   a2[11] = 0;
//   a2[12] = 0;
//   if ( sub_413071(v3+4, &v3[36], a1[1] as char, 8) != -1 )
//     v3[36] += 11;                               // reserve 3+8 bits for
//                                                 // block-length write-back
//   return 0;
//
// The `+= 11` after writing 8 bits leaves a 3-bit gap; the matching
// `endBlock` (idx 95) seeks to `block_start + 8` and writes 11 bits
// of length there. After the write+gap, cursor sits at start+19.
fn createBlock(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const block_id = args.getI32(1);
    const buf = smsBuffer(vm, this) orelse return 0;
    const cur = cursorAt(buf);
    if (cur > 0x42D) return 0; // buffer full
    // Truncate to signed byte (canonical `*(char *)(a1+4)`).
    const id_byte: u32 = @as(u32, @bitCast(@as(i32, @as(i8, @truncate(block_id)))));
    if (vm.heap.get(this)) |inst| {
        inst.field_map.put(FIELD_BLOCK_START, cur) catch {};
        inst.field_map.put(FIELD_BLOCK_ID, id_byte) catch {};
        inst.field_map.put(FIELD_BLOCK_RES1, 0) catch {};
        inst.field_map.put(FIELD_BLOCK_RES2, 0) catch {};
    }
    // Canonical: sub_413071(... 8) writes 8 bits AND advances cursor by 8,
    // then `*(_DWORD *)(v3 + 144) += 11;` adds another 11 → net +19.
    // Layout: [cur .. cur+7] = block_id, [cur+8 .. cur+18] = 11-bit count
    // slot (filled by endBlock), payload from cur+19 onward.
    var c = cur;
    if (writeBits(buf, &c, id_byte, 8) != -1) {
        setCursor(buf, cur + 19); // 8 bits written + 11 bits reserved
    } else {
        setCursor(buf, c);
    }
    return 0;
}

// ── [95] sub_429B8D — Sms.endBlock() → int ─────────────────────────────────
// Canonical (ref:27899):
//   v4 = sub_42989D(this);
//   if ( v4 && v4[36] <= 0x42D ) {
//     v5 = v4[36] - (a2[9] + 19);          // payload bit-length
//     v3 = v4[36];                          // save cursor
//     v4[36] = a2[9] + 8;                   // seek to block-count slot
//     sub_421B36(v4, v5);                   // write 11-bit count
//     v4[36] = v3;                          // restore cursor
//     *a1 = v5;
//     return 1;
//   }
//   *a1 = 0;
//   return 1;
//
// Returns the bit-length of the block's payload. Bytecode that builds
// SMS messages may branch on this (`if (len > 0) ...`); returning 0
// when the buffer is full lets the gamelet recover gracefully.
fn endBlock(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const buf = smsBuffer(vm, this) orelse {
        // canonical else-branch: *a1 = 0, return 1.
        args.setReturnI32(0);
        return 1;
    };
    const cur = cursorAt(buf);
    const inst = vm.heap.get(this) orelse {
        args.setReturnI32(0);
        return 1;
    };
    const block_start = inst.field_map.get(FIELD_BLOCK_START) orelse 0;
    if (cur > 0x42D) {
        args.setReturnI32(0);
        return 1;
    }
    // Canonical: `v5 = cursor - (block_start + 19);` typed __int16.
    // The signed truncation matters when blocks are > 32K bits (it
    // never is for real SMS payloads, but stays bit-exact).
    const v5_full: i32 = @as(i32, @bitCast(cur)) -% @as(i32, @bitCast(block_start +% 19));
    const v5: i16 = @truncate(v5_full);
    // Canonical: `v3 = *(_WORD *)(v4 + 144);` saves cursor as a u16
    // (the low 16 bits only). Restored later via DWORD write, which
    // sign-extends if the saved value's high bit is set — but since
    // cursors stay < 0x42D in practice, the truncation is a no-op.
    const v3: u32 = cur & 0xFFFF;
    // Seek to the 11-bit count slot (block_start + 8) and write v5.
    setCursor(buf, block_start +% 8);
    writeBlockCount(buf, @as(u32, @bitCast(@as(i32, v5))));
    setCursor(buf, v3);
    args.setReturnI32(v5);
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 89, "Sms.deleteSms",       deleteSms },
    .{ 90, "Sms.createSms",       ctorOrReset },
    .{ 92, "Sms.createBlock",     createBlock },
    .{ 95, "Sms.endBlock",        endBlock },
});
