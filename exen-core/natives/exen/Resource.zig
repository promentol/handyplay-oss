//! exen.Resource — native funcs_407AA2[] indices 30..42
//!
//! Hash 0xbab5c664. Reads typed values from .exn resource sections.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

const log = std.log.scoped(.natives);

pub const first_index: u32 = 30;
pub const last_index: u32 = 42;

/// Pull the resource cursor out of a Resource instance, advance it by
/// calling `op(state, raw_bytes)`, then write the new cursor back.
/// Centralises the load → mutate → store pattern that every read*
/// native repeats. Returns null when the resource isn't valid (e.g.
/// no .exn loaded yet) so the caller can return a sentinel.
fn withResource(
    vm: *Vm,
    this: Handle,
    comptime T: type,
    op: fn (st: *core.exn.ResourceState, raw: []const u8) ?T,
) ?T {
    const raw = vm.exn_raw orelse return null;
    var st = _h.loadResource(vm, this) orelse return null;
    const v = op(&st, raw);
    _h.storeResource(vm, this, st);
    return v;
}

fn readByteOp(st: *core.exn.ResourceState, raw: []const u8) ?u32 {
    return @as(u32, st.readByte(raw) orelse return null);
}
fn readShortOp(st: *core.exn.ResourceState, raw: []const u8) ?u32 {
    return @as(u32, st.readShort(raw) orelse return null);
}
fn readIntOp(st: *core.exn.ResourceState, raw: []const u8) ?u32 {
    return st.readInt(raw);
}

// ── [30] Resource.<init>(this, id) — sub_4286C5 ─────────────────────────────
// Canonical body (reference/ref:27307):
//
//   v3 = a1[1];                                       // arg[0] = id
//   a2[6] = 0;                                         // ALWAYS zero base
//   a2[7] = 0;                                         // ALWAYS zero length
//   a2[8] = 0;                                         // ALWAYS zero pos
//   if ( v3 < 0 || v3 >= resource_count ) {
//     sub_434771("non-catcheable I");                  // log trace
//     sub_407A13();                                    // HALT simulator
//   } else {
//     a2[6] = resource_table[v3];                      // base
//     a2[7] = resource_table[v3+1] - resource_table[v3]; // length
//   }
//   *a1 = 0;                                           // return 0 (void-equiv)
//   return 1;
//
// Canonical-exact port: always zero (base, length, pos) FIRST, then
// validate id, halting the VM on out-of-range. Halt mirrors the
// canonical's `sub_407A13` non-catcheable abort behaviour.
fn ctor(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const id = args.getU32(1);
    if (vm.heap.get(this)) |inst| {
        // Step 1: ALWAYS zero base/length/pos first (canonical order).
        inst.field_map.put(_h.FIELD_RES_BASE, 0) catch {};
        inst.field_map.put(_h.FIELD_RES_LENGTH, 0) catch {};
        inst.field_map.put(_h.FIELD_RES_POSITION, 0) catch {};
        inst.field_map.put(_h.FIELD_RES_ID, id) catch {};

        // Step 2: validate id range.
        if (core.resolveResource(id)) |r| {
            inst.field_map.put(_h.FIELD_RES_BASE, r.offset) catch {};
            inst.field_map.put(_h.FIELD_RES_LENGTH, r.length) catch {};
            // pos stays at the just-set 0.
        } else {
            // Canonical: sub_434771 logs + sub_407A13 halts the simulator.
            log.warn("Resource.<init>: id {d} out of range — halting VM (canonical sub_407A13)", .{id});
            vm.halted = true;
            vm.halt_reason = .host_aborted;
        }
    }
    // Canonical sub_4286C5: *a1 = 0; return 1 (void-equiv).
    args.setReturn(0);
    return 1;
}

// ── [31] readBoolean(this) — sub_428CF0 ─────────────────────────────────────
// Reads one byte, returns its low bit.
fn readBoolean(vm: *Vm, args: bridge.ArgFrame) i16 {
    const b = withResource(vm, args.this(), u32, readByteOp) orelse 0;
    args.setReturn(b & 1);
    return 1;
}

// ── [34] readByte(this) ─────────────────────────────────────────────────────
fn readByte(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(withResource(vm, args.this(), u32, readByteOp) orelse 0);
    return 1;
}

// ── [33] readShort(this) / [35] readChar(this) ──────────────────────────────
fn readShort(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(withResource(vm, args.this(), u32, readShortOp) orelse 0);
    return 1;
}

// ── [32] readInt(this) — sub_428E50 ─────────────────────────────────────────
fn readInt(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(withResource(vm, args.this(), u32, readIntOp) orelse 0);
    return 1;
}

// ── [39] readUTF(this) — sub_429265 ─────────────────────────────────────────
// Reads a length-prefixed Modified-UTF-8 string from the resource and
// returns a new heap-allocated String-shaped handle whose `.bytes` slice
// owns the freshly-copied data. Advances `pos` by length+2.
fn readUTF(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    args.setReturn(0);
    const raw = vm.exn_raw orelse return 1;
    var st = _h.loadResource(vm, this) orelse return 1;
    const bytes_opt = st.readUTF(raw, vm.allocator) catch null;
    _h.storeResource(vm, this, st);
    const bytes = bytes_opt orelse return 1;
    const new_handle = vm.heap.alloc(0x7772dde3) catch {
        vm.allocator.free(bytes);
        return 1;
    };
    if (vm.heap.get(new_handle)) |inst| {
        inst.bytes = bytes;
        inst.fields[0] = @intCast(bytes.len);
    } else {
        vm.allocator.free(bytes);
    }
    args.setReturn(new_handle);
    return 1;
}

// ── [40] readStringByIndex(this, n) — sub_4295DF ────────────────────────────
// Reads the N-th 0xFF-separated string from the resource starting at the
// current position. Position is NOT advanced — repeated calls with the
// same `n` return the same string. Canonical body at ref:27683.
//
//   Buffer := raw[base+pos .. base+length]
//   Walk Buffer counting 0xFF bytes; after counting `n` separators,
//   capture the cursor as `src`. Then walk until next 0xFF, capturing
//   `size`. Allocate a String + char[size]; copy [src..src+size] into
//   the char[]; return the String handle. Returns 0 on OOB or empty.
fn readStringByIndex(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const n = args.getU32(1);
    args.setReturn(0);
    const raw = vm.exn_raw orelse return 1;
    const st = _h.loadResource(vm, this) orelse return 1;
    if (st.length <= st.position) return 1;
    const start: usize = @as(usize, st.base) + @as(usize, st.position);
    const end: usize = @as(usize, st.base) + @as(usize, st.length);
    if (end > raw.len or start >= end) return 1;

    var cursor: usize = start;
    var skipped: u32 = 0;
    while (skipped != n) {
        if (cursor >= end) return 1;
        const b = raw[cursor];
        cursor += 1;
        if (b == 0xFF) skipped += 1;
    }
    const src_start = cursor;
    while (cursor < end and raw[cursor] != 0xFF) : (cursor += 1) {}
    const size = cursor - src_start;
    // Canonical (sub_4295DF) always allocates a String, even when Size==0
    // (an empty char[]). Returning 0 here makes the caller see a NULL where
    // they expect an empty String — Pikubi's menu input handler crashes on
    // that mismatch. Allocate-and-return the (possibly empty) char[] slice.

    const bytes = if (size == 0) (vm.allocator.alloc(u8, 0) catch return 1)
                  else (vm.allocator.alloc(u8, size) catch return 1);
    if (size > 0) @memcpy(bytes, raw[src_start..cursor]);
    const new_handle = vm.heap.alloc(0x7772dde3) catch {
        vm.allocator.free(bytes);
        return 1;
    };
    if (vm.heap.get(new_handle)) |inst| {
        inst.bytes = bytes;
        inst.fields[0] = @intCast(bytes.len);
    } else {
        vm.allocator.free(bytes);
    }
    args.setReturn(new_handle);
    return 1;
}

// ── [36] readBytes(this, count) — sub_429620 ────────────────────────────────
// Copy up to `n_raw` bytes into a freshly-allocated byte[] and return
// it as an array-shaped handle (`.bytes` slice owned + fields[0] = len).
fn readBytes(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const n_raw = args.getU32(1);
    args.setReturn(0);
    const raw = vm.exn_raw orelse return 1;
    var st = _h.loadResource(vm, this) orelse return 1;
    const n = @min(n_raw, st.remaining());
    const bytes = vm.allocator.alloc(u8, n) catch return 1;
    _ = st.readBytes(raw, bytes);
    _h.storeResource(vm, this, st);
    const new_handle = vm.heap.alloc(0) catch {
        vm.allocator.free(bytes);
        return 1;
    };
    if (vm.heap.get(new_handle)) |inst| {
        inst.bytes = bytes;
        inst.fields[0] = @intCast(bytes.len);
    } else {
        vm.allocator.free(bytes);
    }
    args.setReturn(new_handle);
    return 1;
}

// ── [37] readShorts(this, count) / [38] readInts(this, count) ───────────────
fn readShortsOrInts(vm: *Vm, this: Handle, n_raw: u32, comptime elem_bytes: u32) Handle {
    const raw = vm.exn_raw orelse return 0;
    var st = _h.loadResource(vm, this) orelse return 0;
    const n = @min(n_raw, st.remaining() / elem_bytes);
    const new_handle = vm.heap.alloc(0) catch return 0;
    if (vm.heap.get(new_handle)) |inst| {
        inst.fields[0] = n;
        const cap = @min(n, @as(u32, @intCast(inst.fields.len)) - 1);
        for (0..cap) |i| {
            inst.fields[1 + i] = if (elem_bytes == 2)
                @as(u32, st.readShort(raw) orelse 0)
            else
                st.readInt(raw) orelse 0;
        }
    }
    _h.storeResource(vm, this, st);
    return new_handle;
}

fn readShorts(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(readShortsOrInts(vm, args.this(), args.getU32(1), 2));
    return 1;
}

fn readInts(vm: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(readShortsOrInts(vm, args.this(), args.getU32(1), 4));
    return 1;
}

// ── [42] getResourceType(this) — sub_429813 ─────────────────────────────────
// Returns the per-resource-id `flag` byte that the simulator records
// in its classfile section. Tells the gamelet whether the resource is
// an image / text / raw bytes / etc.
fn getResourceType(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this());
    const id: u32 = if (inst) |i| (i.field_map.get(_h.FIELD_RES_ID) orelse 0) else 0;
    args.setReturn(core.resourceFlag(id) orelse 0);
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 30, "<init>",            ctor },
    .{ 31, "readBoolean",       readBoolean },
    .{ 32, "readInt",           readInt },
    .{ 33, "readShort",         readShort },
    .{ 34, "readByte",          readByte },
    .{ 35, "readChar",          readShort }, // same wire format as readShort
    .{ 36, "readBytes",         readBytes },
    .{ 37, "readShorts",        readShorts },
    .{ 38, "readInts",          readInts },
    .{ 39, "readUTF",           readUTF },
    .{ 40, "readStringByIndex", readStringByIndex },
    .{ 42, "getResourceType",   getResourceType },
});
