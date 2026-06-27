//! java.lang.StringBuffer — native funcs_407AA2[] indices 166..174
//!
//! Hash 0x47cb31c2. Mutable string builder.
//! Bodies ported from `reference/ref` (funcs_407AA2 entries
//! at lines 3292..3300):
//!
//!   166 → sub_42AEEF  initStringBuffer(int capacity)
//!   167 → sub_42B17D  length()
//!   168 → sub_42AE20  capacity()
//!   169 → sub_42B056  append(String)
//!   170 → sub_42B0F2  append(StringBuffer)
//!   171 → sub_42B19F  append(char)
//!   172 → sub_42B1ED  append(int)
//!   173 → sub_42B244  append(long)
//!   174 → sub_42AE4E  toString()
//!
//! Canonical storage model (mirrored here):
//!   this.value (canonical *(this+32)) → char[] block.
//!     - First u16 = current LENGTH (chars present)
//!     - Bytes [2..2+capacity) = char data
//!     - Total allocation size = `capacity + 2`-aligned block header +
//!       prologue; canonical's `capacity()` reads the block-size word.
//!
//! Our mapping:
//!   - `inst.bytes` = the pre-allocated buffer (length = canonical
//!     CAPACITY). Allocated up-front in `initStringBuffer`; grown
//!     in-place by `append*` when length would exceed capacity.
//!   - `inst.fields[0]` = current LENGTH (chars present).
//!   - `length()`  → inst.fields[0]
//!   - `capacity()` → inst.bytes.len
//! This separation matches canonical's distinct length vs capacity
//! semantics (previously conflated as `inst.bytes.len` for both).

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 166;
pub const last_index: u32 = 174;

const JAVA_LANG_STRING: u32 = 0x7772dde3;
const MAX_CAPACITY: u32 = 0x4000;

/// Current chars-present count for `inst`.
inline fn sbLen(inst: *interp.Instance) u32 {
    return inst.fields[0];
}

/// Set chars-present count.
inline fn setSbLen(inst: *interp.Instance, n: u32) void {
    inst.fields[0] = n;
}

/// Current allocated capacity (size of inst.bytes).
inline fn sbCap(inst: *interp.Instance) u32 {
    return if (inst.bytes) |b| @intCast(b.len) else 0;
}

/// Mirrors canonical sub_42AF2F: ensure the buffer has room for
/// `needed_cap` total bytes. If current capacity is smaller, alloc a
/// larger buffer, copy existing chars [0..length], free old. Caps at
/// MAX_CAPACITY (canonical 0x4000). Returns true on success.
fn ensureCapacity(vm: *Vm, inst: *interp.Instance, needed_cap: u32) bool {
    const cur_cap = sbCap(inst);
    if (cur_cap >= needed_cap) return true;
    if (needed_cap > MAX_CAPACITY) return false;
    const new_buf = vm.allocator.alloc(u8, needed_cap) catch return false;
    if (inst.bytes) |old| {
        const len = sbLen(inst);
        @memcpy(new_buf[0..len], old[0..len]);
        vm.allocator.free(old);
    }
    inst.bytes = new_buf;
    return true;
}

// ── [166] initStringBuffer(int capacity) — sub_42AEEF ───────────────────────
// Canonical body (reference/ref near 27530):
//   if (arg[0] > 0) {
//     if (arg[0]) sub_42AF2F(this, (u16)arg[0]);   // alloc buffer of size cap
//   } else {
//     sub_410198(127202840);                         // throw error
//   }
//   return 0;                                        // void return
//
// Allocates an `initial_capacity`-byte buffer up-front (canonical
// pre-allocation, not grow-on-demand). Length starts at 0.
fn ctorInit(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const initial_capacity = args.getI32(1);
    if (initial_capacity <= 0) {
        // Canonical: sub_410198(127202840) throws an error.
        // We have no NPE-throw mechanism — silently no-op.
        return 0;
    }
    const cap: u32 = @intCast(initial_capacity);
    if (cap > MAX_CAPACITY) return 0;
    const inst = vm.heap.get(this) orelse return 0;
    const new_buf = vm.allocator.alloc(u8, cap) catch return 0;
    if (inst.bytes) |old| vm.allocator.free(old);
    inst.bytes = new_buf;
    setSbLen(inst, 0);
    return 0;
}

// ── [167] length(this) — sub_42B17D ─────────────────────────────────────────
// Canonical: `return *(WORD*)(*(this+32))` — reads first 2 bytes of
// this.value char[] = u16 length prefix. Our model stores length in
// inst.fields[0] for direct access without indirection.
fn length(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    args.setReturn(sbLen(inst));
    return 1;
}

// ── [168] capacity(this) — sub_42AE20 ───────────────────────────────────────
// Canonical body: `return *(*(this+32) + 8) - 20` — reads the char[]
// allocation header's block-size word, minus the 20-byte heap-object
// prologue. For us, capacity == inst.bytes.len (the allocated buffer
// size).
fn capacity(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    args.setReturn(sbCap(inst));
    return 1;
}

// ── [169] append(String) — sub_42B056 ───────────────────────────────────────
// Canonical body:
//   if (a2 == 0) { sub_410198(NPE); return 0; }
//   v4 = *(arg[0] + 24);                         // src.value (char[])
//   if (v4) {
//     if (sub_42AF2F(this, *(WORD*)v4)) {         // ensure cap += src.length
//       v3 = this.value;
//       sub_40FFAF(v3 + 2 + (u16)*v3, v4 + 2, *(WORD*)v4);  // memcpy
//       *v3 += *(WORD*)v4;                          // length += src.length
//     }
//   }
//   return 0;
//
// Canonical returns void. Our Zig returns Handle (this) so callers
// chaining `sb.append(a).append(b)` work — this is a non-canonical
// adaptation: canonical bytecode wrappers re-push `this` after the
// native, ours doesn't (the chained-this return papers over the gap).
//
// IMPORTANT: source's length is `src.bytes.len`, NOT `src.fields[0]`.
// Strings (immutable) use `inst.bytes.len` as their length; `fields[0]`
// is overloaded by opLdcString to hold the constant-pool OFFSET for
// LDC_STRING-loaded literals (see opcodes/consts.zig:61). Reading
// fields[0] for a literal String returns the offset (often hundreds
// of bytes) and our `src_len <= src.len` guard then SKIPS the append
// entirely — which manifested as missing-space bugs like "Level: 3NEO"
// where the " " literal got silently dropped.
fn appendString(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const other = args.handle(1);
    if (vm.heap.get(other)) |other_inst| {
        if (other_inst.bytes) |src| {
            if (src.len > 0) appendBytesRaw(vm, this, src);
        }
    }
    args.setReturn(this);
    return 1;
}

// ── [170] append(StringBuffer) — sub_42B0F2 ─────────────────────────────────
// Canonical reads `*(arg[0] + 32) + 24` (one extra indirection vs
// append(String)) to get the underlying char[]. For StringBuffer
// sources, fields[0] IS the length (set by initStringBuffer + append*),
// distinct from String sources. We can safely use sbLen() here.
fn appendStringBuffer(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const other = args.handle(1);
    if (vm.heap.get(other)) |other_inst| {
        if (other_inst.bytes) |src| {
            const src_len = sbLen(other_inst);
            if (src_len > 0 and src_len <= src.len) {
                appendBytesRaw(vm, this, src[0..src_len]);
            }
        }
    }
    args.setReturn(this);
    return 1;
}

// ── [171] append(char) — sub_42B19F ─────────────────────────────────────────
// Canonical: append a single char (truncated to u8 in our 8bpp model).
fn appendChar(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    appendBytesRaw(vm, this, &[_]u8{@truncate(args.getU32(1))});
    args.setReturn(this);
    return 1;
}

// ── [172] append(int) — sub_42B1ED ──────────────────────────────────────────
// Canonical: itoa the int (10-digit max + sign) and append the digits.
fn appendInt(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const value = args.getI32(1);
    var buf: [12]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{d}", .{value})) |s| {
        appendBytesRaw(vm, this, s);
    } else |_| {}
    args.setReturn(this);
    return 1;
}

// ── [173] append(long) — sub_42B244 ─────────────────────────────────────────
fn appendLong(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const value: i64 = @bitCast(args.getLong(1));
    var buf: [24]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{d}", .{value})) |s| {
        appendBytesRaw(vm, this, s);
    } else |_| {}
    args.setReturn(this);
    return 1;
}

/// Canonical helper sub_40FFAF + sub_42AF2F: ensure cap, memcpy src
/// onto this[len..], bump length.
fn appendBytesRaw(vm: *Vm, this: Handle, src: []const u8) void {
    if (src.len == 0) return;
    const inst = vm.heap.get(this) orelse return;
    const cur_len = sbLen(inst);
    const needed = cur_len + @as(u32, @intCast(src.len));
    if (!ensureCapacity(vm, inst, needed)) return;
    const buf = inst.bytes orelse return;
    @memcpy(buf[cur_len..needed], src);
    setSbLen(inst, needed);
}

// ── [174] toString() — sub_42AE4E ───────────────────────────────────────────
// Canonical body:
//   v4 = sub_410067(153, 0x7772DDE3u);             // alloc new String
//   if (v4) {
//     v3 = sub_411ADD(this.value);                  // duplicate this.value
//     if (v3) {
//       ++byte_at_v3[14];                            // bump char[] refcount
//       *(v4 + 32) = v3;                             // new_string.value = dup
//     } else {
//       sub_411B5E(v4);                              // free new String
//       v4 = 0;
//       sub_410198(-218584548);                      // OOM error
//     }
//   }
//   *a1 = v4;
//   return 1;
//
// Returns a new String containing exactly the LENGTH chars in this
// (NOT the full allocated capacity). Canonical's sub_411ADD duplicates
// only the populated portion of the char[].
fn toStringOp(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    args.setReturn(0);
    const inst = vm.heap.get(this) orelse return 1;
    const len = sbLen(inst);
    const new_h = vm.heap.alloc(JAVA_LANG_STRING) catch return 1;
    args.setReturn(new_h);
    const new_inst = vm.heap.get(new_h) orelse return 1;
    if (len == 0) {
        const empty = vm.allocator.alloc(u8, 0) catch return 1;
        new_inst.bytes = empty;
        new_inst.fields[0] = 0;
        return 1;
    }
    const src = inst.bytes orelse return 1;
    const buf = vm.allocator.alloc(u8, len) catch {
        args.setReturn(0);
        return 1;
    };
    @memcpy(buf, src[0..len]);
    new_inst.bytes = buf;
    new_inst.fields[0] = len;
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 166, "initStringBuffer",     ctorInit },
    .{ 167, "length",               length },
    .{ 168, "capacity",             capacity },
    .{ 169, "append(String)",       appendString },
    .{ 170, "append(StringBuffer)", appendStringBuffer },
    .{ 171, "append(char)",         appendChar },
    .{ 172, "append(int)",          appendInt },
    .{ 173, "append(long)",         appendLong },
    .{ 174, "toString",             toStringOp },
});
