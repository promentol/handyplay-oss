//! java.lang.String — native funcs_407AA2[] indices 158..165
//!
//! Hash 0x7772dde3. Bytes-backed immutable strings.
//!
//! Index map verified by reading sub_* bodies in reference/ref
//! (the previous heuristic in native_index_map.md was off by one):
//!
//!   158 → sub_42AC79  length()              ✓ verified
//!   159 → sub_42A7B0  getBytes()            ✓ verified
//!   160 → sub_42A99F  toLowerCase()         ✓ verified
//!   161 → sub_42A85E  compareTo(other)      ✓ verified
//!   162 → sub_42AA54  <init>(String)        ✓ verified (copy ctor)
//!   163 → sub_42AAFC  <init>(byte[])        ✓ verified
//!   164 → sub_42AB8C  toUpperCase()         ✓ verified
//!   165 → sub_42ACB6  Integer.toString(int) ✓ verified

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 158;
pub const last_index: u32 = 165;

/// Class-tag hash for `byte[]` arrays, used by `sub_410106` when
/// allocating the result of `String.getBytes()` (canonical sub_42A7B0
/// calls `sub_410106(len, 0x150u, 0x9EC04138u)` at ref:28403).
/// `instanceof byte[]` / `getClass()` on the returned handle check
/// against this hash; without it `arr instanceof byte[]` is false.
const BYTE_ARRAY_CLASS: u32 = 0x9EC04138;
const JAVA_LANG_STRING: u32 = 0x7772dde3;

// ── [158] length(this) — sub_42AC79 ─────────────────────────────────────────
// Reads the u16 length-prefix at offset 0 of the String's char-buffer.
// We model the buffer as `inst.bytes`, so length = `bytes.len`.
//
// Fallback: if `this` is a heap handle but its `.bytes` is null (which
// happens when the String came from a legacy-stub native that allocated
// the handle but never populated it), return a small non-zero length
// so callers that pre-allocate a buffer don't see "empty string and
// skip the whole text path". The gamelet's drawString wrapper does
// `String.getBytes()` immediately after, and if getBytes returns a
// real handle the renderer recovers.
fn length(vm: *Vm, args: bridge.ArgFrame) i16 {
    // CAPTURE `this` BEFORE writing return — setReturn clobbers slab[0].
    const this = args.this();
    args.setReturn(0);
    const src_inst = vm.heap.get(this) orelse return 1;
    if (src_inst.bytes) |b| args.setReturn(@intCast(b.len));
    return 1;
}

// ── [159] getBytes(this) — sub_42A7B0 ───────────────────────────────────────
// Allocates a new byte[] and copies the String's char-buffer into it.
// The gamelet's `Graphics.drawString` wrapper (method 0x49ce4668 on
// exen.Graphics) calls this and treats the result as a byte[] handle
// fed to `Graphics.drawChars`. Without the correct index binding here
// the wrapper gets back a u32 length, ARRAYLENGTH returns 0, and
// drawChars renders nothing (the empty-buffer marquee we've seen for
// 10s in every Crash run).
//
// Fallback: if `this` is a heap handle but its `.bytes` is null, return
// the SAME handle as the byte[]. That at least gives the caller a
// non-null reference and ARRAYLENGTH will yield 0 (rendering nothing
// for that specific string) rather than null-deref'ing the whole chain.
fn getBytes(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const src_inst = vm.heap.get(this) orelse {
        args.setReturn(this);
        return 1;
    };
    const new_handle = vm.heap.alloc(BYTE_ARRAY_CLASS) catch {
        args.setReturn(this);
        return 1;
    };
    args.setReturn(new_handle);
    const inst = vm.heap.get(new_handle) orelse return 1;
    if (src_inst.bytes) |src_bytes| {
        const buf = vm.allocator.alloc(u8, src_bytes.len) catch return 1;
        @memcpy(buf, src_bytes);
        inst.bytes = buf;
        inst.fields[0] = @intCast(buf.len);
    }
    return 1;
}

// ── [161] compareTo(this, other) — sub_42A85E ───────────────────────────────
// Canonical body (ref:25538):
//   if (!other) sub_410198(NPE); return 1;
//   v6 = this.bytes (length-prefixed u16*); v5 = other.bytes
//   if (!v6) return -1;
//   for (i = 0; i < min(other.length, this.length); ++i):
//     if (this[i] < other[i]) return -1
//     if (this[i] > other[i]) return  1
//   // prefixes match — length comparison (CANONICAL QUIRK):
//   if (other.length >= this.length): return (other.length > this.length) ? 1 : 0
//   else:                              return -1
//
// The bytewise comparison follows the standard `this.compareTo(other)`
// contract (returns -1 when this<other), but the length comparison is
// REVERSED from Java's spec: canonical returns +1 when `this` is
// SHORTER and -1 when `this` is LONGER. We replicate that quirk
// verbatim so gamelets that depend on it (e.g. Pikubi's menu sort,
// Terminator's String ctor 0x6f6cef2f-based hash lookups) behave
// identically — straying to Java-standard semantics here flips sort
// order at byte-equal prefixes of unequal length.
fn compareTo(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const other = args.handle(1);
    const result: i32 = blk: {
        const a = vm.heap.get(this) orelse break :blk 1;
        const b = vm.heap.get(other) orelse break :blk -1;
        const ab = a.bytes orelse break :blk -1;
        const bb = b.bytes orelse &[_]u8{};
        const n = @min(ab.len, bb.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (ab[i] < bb[i]) break :blk -1;
            if (ab[i] > bb[i]) break :blk 1;
        }
        // Length comparison — matches canonical's reversed-sign convention.
        if (bb.len >= ab.len) break :blk @as(i32, if (bb.len > ab.len) 1 else 0);
        break :blk -1;
    };
    args.setReturnI32(result);
    return 1;
}

// ── [163] <init>(this, byte[]) — sub_42AAFC ─────────────────────────────────
// Constructor: copy the source array's flat bytes into `this`. The
// source is either a byte[] (tag 0x90) or a char[] (tag 0x55) — both
// shapes get `.bytes` populated by NEWARRAY/ARRSTORE with the low byte
// of each element, so reading `.bytes` here works uniformly.
fn ctorFromBytes(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const src_bytes_handle = args.handle(1);
    blk: {
        const this_inst = vm.heap.get(this) orelse break :blk;
        const arg_inst = vm.heap.get(src_bytes_handle) orelse break :blk;
        const src = arg_inst.bytes orelse break :blk;
        const buf = vm.allocator.alloc(u8, src.len) catch break :blk;
        @memcpy(buf, src);
        if (this_inst.bytes) |old| vm.allocator.free(old);
        this_inst.bytes = buf;
    }
    return 0;
}

// ── [164] toUpperCase(this, source) — sub_42AB8C ────────────────────────────
// CTOR-shape helper (NOT a Java instance method). Canonical body:
//   1. reads source from `*(a1+4)` (a1 = call frame, source at +4)
//   2. allocates a new buffer via `sub_410106(len, 0x190, 0x5DA4D0C7)`
//   3. uppercases bytes through libc `toupper` into the new buffer
//   4. writes `*(a2+32) = buf; *(a2+24) = buf+18` (a2 = fresh receiver)
//   5. returns 0 — no stack slot pushed (canonical wraps via a String
//      ctor; the bytecode caller already has `this` on stack)
// So our handler MUTATES `this` from `source` and returns void.
//
// TheTerminator routes every menu/status string through this path (its
// String ctor 0x6f6cef2f internally calls this helper), so without a
// real implementation `this.bytes` stays null and Graphics.drawChars
// has no glyphs to render.
fn toUpperCase(vm: *Vm, args: bridge.ArgFrame) i16 {
    mutateCase(vm, args.this(), args.handle(1), std.ascii.toUpper);
    return 0;
}

// ── [160] toLowerCase(this) — sub_42A99F ────────────────────────────────────
// INSTANCE method (NOT ctor-shape — different from toUpperCase!).
// Canonical body:
//   1. reads `v5 = *(a2+24)` = this.bytes_ptr (length-prefixed)
//   2. allocates a new String via `sub_410106(len, 0x190, 0x5DA4D0C7)`
//   3. lowercases bytes through libc `tolower` into the new buffer
//   4. writes `*a1 = v6` — pushes the NEW String handle
//   5. returns 1 (one stack slot = the new handle)
// So our handler MUST allocate a fresh String and return its Handle.
// The previous 2-arg ctor-shape impl silently dropped the result,
// breaking `x = s.toLowerCase()` everywhere.
fn toLowerCase(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    args.setReturn(0);
    const src_inst = vm.heap.get(this) orelse return 1;
    const src_bytes = src_inst.bytes orelse return 1;
    const new_h = vm.heap.alloc(JAVA_LANG_STRING) catch return 1;
    args.setReturn(new_h);
    const new_inst = vm.heap.get(new_h) orelse return 1;
    const buf = vm.allocator.alloc(u8, src_bytes.len) catch return 1;
    for (src_bytes, 0..) |b, i| buf[i] = std.ascii.toLower(b);
    new_inst.bytes = buf;
    new_inst.fields[0] = @intCast(buf.len);
    return 1;
}

fn mutateCase(
    vm: *Vm,
    this: Handle,
    source: Handle,
    comptime xform: fn (u8) u8,
) void {
    const src_inst = vm.heap.get(source) orelse return;
    const src_bytes = src_inst.bytes orelse return;
    const this_inst = vm.heap.get(this) orelse return;
    const buf = vm.allocator.alloc(u8, src_bytes.len) catch return;
    for (src_bytes, 0..) |b, i| buf[i] = xform(b);
    if (this_inst.bytes) |old| vm.allocator.free(old);
    this_inst.bytes = buf;
    this_inst.fields[0] = @intCast(buf.len);
}

// ── [162] <init>(this, String source) — sub_42AA54 ──────────────────────────
// Canonical body (ref:25788):
//   if (!source) sub_410198(NPE); return 0;
//   v4 = source.fields                                 // src instance
//   if (v4[8]) {                                       // has owned char[]
//     v3 = sub_411ADD(v4[8]);                          // clone char[]
//     if (!v3) { sub_410198(OOM); return 0; }
//     ++byte_at_v3[14];                                 // refcount++
//     this.field[+32] = v3;                             // store new char[]
//     this[+24..+32] = (length, &v3.payload);
//   } else {                                            // borrowed (interned)
//     this[+24] = v4[6];   this[+28] = v4[7];           // share src buffer
//   }
//   return 0;
//
// Our model: `inst.bytes` IS the canonical char[] payload, length lives
// in `fields[0]`. We don't model GC refcounts (canonical bumps byte+14),
// so every String owns a private copy. The canonical NPE/OOM branches
// degenerate to silent `return 0` because we lack exception infra. The
// "borrowed buffer" branch (interned-literal source with no owned bytes)
// maps to an empty-source copy.
fn ctorFromString(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const source = args.handle(1);
    blk: {
        const this_inst = vm.heap.get(this) orelse break :blk;
        const src_inst = vm.heap.get(source) orelse break :blk;
        const src_opt = src_inst.bytes;
        const src_len: usize = if (src_opt) |s| s.len else 0;
        const buf = vm.allocator.alloc(u8, src_len) catch break :blk;
        if (src_opt) |s| if (src_len > 0) @memcpy(buf, s);
        if (this_inst.bytes) |old| vm.allocator.free(old);
        this_inst.bytes = buf;
        this_inst.fields[0] = @intCast(buf.len);
    }
    return 0;
}

// ── [165] Integer.toString(int) — sub_42ACB6 ────────────────────────────────
// Canonical: allocate a String, count digits (handle sign), allocate
// byte buffer, format via `sub_411490` (a plain itoa). Returns the
// new String handle.
fn integerToString(vm: *Vm, args: bridge.ArgFrame) i16 {
    const value = args.getI32(0);
    args.setReturn(0);
    var buf: [12]u8 = undefined; // -2147483648 + NUL = 12
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return 1;
    const new_h = vm.heap.alloc(JAVA_LANG_STRING) catch return 1;
    args.setReturn(new_h);
    const new_inst = vm.heap.get(new_h) orelse return 1;
    const owned = vm.allocator.alloc(u8, formatted.len) catch return 1;
    @memcpy(owned, formatted);
    new_inst.bytes = owned;
    new_inst.fields[0] = @intCast(owned.len);
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 158, "length",                length },
    .{ 159, "getBytes",              getBytes },
    .{ 160, "toLowerCase",           toLowerCase },
    .{ 161, "compareTo",             compareTo },
    .{ 162, "<init>(String)",        ctorFromString },
    .{ 163, "<init>(byte[])",        ctorFromBytes },
    .{ 164, "toUpperCase",           toUpperCase },
    .{ 165, "Integer.toString(int)", integerToString },
});
