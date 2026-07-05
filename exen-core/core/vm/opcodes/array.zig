//! Array creation + element access (NEWARRAY, [BIA]LOAD, ARRSTORE, ARRAYLENGTH)
//!
//! Auto-grouped from `core/vm/opcodes.zig` by `op*` family. Each
//! handler keeps its original 1-for-1 port of the `sub_*` body in
//! `reference/ref`.

const std = @import("std");
const err_mod = @import("../error.zig");
const frame_mod = @import("../frame.zig");
const vm_mod = @import("../vm.zig");
const cr = @import("../../classfile/registry.zig");
const log_fmt = @import("../log_fmt.zig");

const log = std.log.scoped(.interp);
const Error = err_mod.Error;
const Frame = frame_mod.Frame;
const Vm = vm_mod.Vm;
const classStr = log_fmt.classStr;
const methodStr = log_fmt.methodStr;

const EXEN_GAMELET = vm_mod.EXEN_GAMELET;
const JAVA_LANG_OBJECT = vm_mod.JAVA_LANG_OBJECT;

// opcode 0xC5 (MULTIANEWARRAY) — canonical sub_40E90A (ref:12423):
//   v4 = *(u8*)(PC++);                  // dim count (single byte)
//   PC = align(PC, 2);                   // align to 2 for the u16 operand
//   v5 = (u16*)PC;                       // read u16 type_tag at PC
//   PC += 4;                              // tentatively advance 4 bytes (allowing for class operand)
//   if ((u8)*v5 == 0x99) v7 = class_operand_lookup(v5[1]);
//   else                  { PC -= 2; v7 = -1; }   // no class operand
//   *(stack_top) = sub_40EBCD(v7, v4, v4, *v5, stack_top);
//   stack += 4;
//
// The simulator's sub_40EBCD pops `v4` sizes from the stack and
// allocates a recursive multi-dim array. For our simpler model:
// allocate the outermost array with size = first popped value, fill
// each entry with a recursive NEWARRAY of the remaining sizes.
// Element type tag for sub-arrays is derived from `type_tag` by
// shifting one byte left (e.g. 0x0259 int[] → 0x59 int).
pub fn opMultianewarray(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const dim: u32 = frame.readU8();
    frame.alignPc();
    const type_tag = frame.readU16();
    // If element type is ref (low byte 0x99) the bytecode includes a
    // u16 class operand right after the type_tag. Consume it; ignore
    // the class for our untyped heap (frame-level recovery handles
    // mistyped lookups). For non-ref, no extra operand.
    if ((type_tag & 0xFF) == 0x99) {
        _ = frame.readU16();
    }
    if (dim == 0) {
        try frame.push(0);
        return;
    }
    // Pop `dim` sizes. JVM convention: stack ..., size1, size2, ..., sizeN
    // (sizeN = innermost). Pop top → innermost dim, last pop → outermost.
    var sizes: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    if (dim > sizes.len) return Error.StackUnderflow;
    var i: u32 = dim;
    while (i > 0) : (i -= 1) {
        sizes[i - 1] = try frame.pop();
    }
    // Recursive allocation: build innermost first, then wrap outward.
    // Inner element-type tag = type_tag with top byte dropped one level.
    // sub-array tag at depth N has top-byte for "is_array" marker; we
    // approximate by shifting the array bits down for each level so the
    // innermost gets the primitive tag (e.g. 0x0259 int[] → at innermost
    // we should allocate `int` storage; at depth=2 each outer slot is a
    // 0x0259 array).
    const outer = try allocMultiDim(vm, sizes[0..dim], type_tag);
    log.debug("  MULTIANEWARRAY dim={d} tag=0x{x:0>4} sizes={any} → handle=0x{x:0>8}", .{
        dim, type_tag, sizes[0..dim], outer,
    });
    try frame.push(outer);
}

// Recursively allocate a multi-dimensional array. Each level allocates
// an outer array and fills each slot with a recursively-allocated sub.
// Returns the outermost handle. When sizes.len == 1, allocates a flat
// array of the appropriate primitive width (delegating storage to the
// same shape as opNewarray does for 1-D arrays).
fn allocMultiDim(vm: *Vm, sizes: []const u32, type_tag: u16) Error!u32 {
    const len = sizes[0];
    const handle = try vm.heap.alloc(0);
    const inst = vm.heap.get(handle) orelse return Error.NullPointer;
    inst.fields[0] = len;
    if (sizes.len == 1) {
        // Innermost: allocate primitive backing storage just like
        // 1-D NEWARRAY. Element width per `1 << ((tag>>2) & 3)`.
        const elem_shift: u32 = (type_tag >> 2) & 3;
        if (elem_shift <= 1 and len > 0) {
            if (vm.heap.allocator.alloc(u8, len)) |buf| {
                @memset(buf, 0);
                inst.bytes = buf;
            } else |_| {}
        } else if (elem_shift >= 2 and len > 0) {
            const stride: u32 = if (elem_shift == 3) 2 else 1;
            if (vm.heap.allocator.alloc(u32, len * stride)) |buf| {
                @memset(buf, 0);
                inst.ints = buf;
            } else |_| {}
        }
        return handle;
    }
    // Outer level: allocate an inst array, then for each slot create
    // a recursive sub-array of the remaining dimensions. Store sub
    // handles in `ints` so AALOAD finds them.
    if (len > 0) {
        if (vm.heap.allocator.alloc(u32, len)) |buf| {
            @memset(buf, 0);
            inst.ints = buf;
            for (0..len) |idx| {
                const sub = try allocMultiDim(vm, sizes[1..], type_tag);
                buf[idx] = sub;
            }
        } else |_| {}
    }
    return handle;
}

pub fn opNewarray(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const type_tag = frame.readU16();
    // Object-array operand: when the low byte of `type_tag` is 0x99
    // (the simulator's `OBJ_ARRAY` tag), NEWARRAY consumes a SECOND
    // u16 from the bytecode — the element class's hash index — and
    // stores it at the new array's `+10` slot (see sub_40EE4D:12643
    // in ref, the `v0 == 153` branch). Without this read the
    // PC drifts by 2 bytes and every subsequent op misaligns, which
    // is what bricked Wallbreaker on `new int[N]` chains within
    // `<init>`. We track the element-class hint on `Instance` only
    // for diagnostics; the array storage itself doesn't depend on it.
    if ((type_tag & 0xFF) == 0x99) {
        _ = frame.readU16();
    }
    const len_u: u32 = try frame.pop();
    const len: i32 = @bitCast(len_u);
    // Some bytecode paths reach NEWARRAY with a negative length when
    // earlier reads returned bogus values from missing natives. Clamp
    // to 0 and allocate an empty array — lets the program continue
    // past the bug to surface the next missing piece.
    const safe_len: u32 = if (len < 0) 0 else len_u;
    const handle = try vm.heap.alloc(0);
    const inst = vm.heap.get(handle) orelse return Error.NullPointer;
    inst.fields[0] = safe_len;
    // Mirror low-byte storage into `.bytes` for byte/char/short arrays: 1 byte
    // per element (`elem_shift <= 1`). SALOAD/CALOAD/BALOAD and ARRSTORE all
    // read/write at this 1-byte stride, so byte/char/short arrays stay in sync.
    // (A 2-byte short-stride was tried for canonical exactness but reverted —
    // it desynced arrays that AoE etc. also touch at 1-byte stride, garbling
    // layouts. Corpus short values fit in a byte.)
    const elem_shift: u32 = (type_tag >> 2) & 3;
    if (elem_shift <= 1 and safe_len > 0) {
        const buf = vm.heap.allocator.alloc(u8, safe_len) catch null;
        if (buf) |b| {
            @memset(b, 0);
            inst.bytes = b;
        }
    }
    // For int[] (elem_shift == 2, tag 0x59) and larger element types,
    // allocate a u32-backed slice. Without this, arrays larger than
    // `inst.fields.len - 1 = 63` lose data past index 62 — fatal for
    // Wallbreaker's ball-X→cell-X lookup tables that are ~screen-width
    // (132 entries) and collapse cell_x to 0 for ball positions past
    // pixel 62. Tag 0x59 (int[]) is the most common case; we also catch
    // any larger stride (elem_shift == 3 = long/double, also 8 bytes
    // logically but ExEn rarely uses long arrays).
    if (elem_shift >= 2 and safe_len > 0) {
        const stride: u32 = if (elem_shift == 3) 2 else 1; // long = 2 u32 slots
        const buf = vm.heap.allocator.alloc(u32, safe_len * stride) catch null;
        if (buf) |b| {
            @memset(b, 0);
            inst.ints = b;
        }
    }
    log.debug("  NEWARRAY tag=0x{x:0>4} len={d}{s} → handle=0x{x:0>8}", .{
        type_tag, len, if (len < 0) " (clamped to 0)" else "", handle,
    });
    try frame.push(handle);
}

pub fn opBaload(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  BALOAD on null array — pushing 0", .{});
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  BALOAD on invalid handle 0x{x:0>8} — pushing 0", .{ref});
        try frame.push(0);
        return;
    };
    // Byte-array path: prefer .bytes when populated (codec decodes
    // and Resource.readBytes write there). Fall back to fields[].
    if (inst.bytes) |b| {
        if (idx < b.len) {
            const bv: i8 = @bitCast(b[idx]);
            const sx: i32 = bv;
            try frame.push(@bitCast(sx));
            return;
        }
    }
    const slot = 1 + idx;
    const v: u32 = if (slot < inst.fields.len) inst.fields[slot] else 0;
    const b2: i8 = @bitCast(@as(u8, @truncate(v)));
    const sx: i32 = b2;
    try frame.push(@bitCast(sx));
}

pub fn opIaload(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  IALOAD on null array — pushing 0", .{});
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  IALOAD on invalid handle 0x{x:0>8} — pushing 0", .{ref});
        try frame.push(0);
        return;
    };
    // Prefer dynamic int[] storage when allocated (NEWARRAY tag 0x59).
    // Fields-backed storage is a 64-slot fallback that silently loses
    // data past index 62 — see Wallbreaker ball-X lookup-table bug.
    if (inst.ints) |ix| {
        if (idx < ix.len) {
            try frame.push(ix[idx]);
            return;
        }
    }
    const slot = 1 + idx;
    const v: u32 = if (slot < inst.fields.len) inst.fields[slot] else 0;
    try frame.push(v);
}

/// CALOAD / TALOAD4 (opcode 0x34, sub_4090F0 @ ref:8765) —
/// loads ONE BYTE from a char[] / byte[] (tag-0x50 family) and
/// zero-extends to u32. Distinct from BALOAD (0x33) which
/// sign-extends, and distinct from IALOAD (0x2E/0x32) which reads
/// 4 bytes. Must prefer `inst.bytes` over `inst.fields`: gamelet
/// arrays often exceed `inst.fields.len` (e.g. Crash's 156-byte
/// menu-text packed array; items past byte 63 would read 0 from
/// fields and produce empty Strings).
pub fn opCaload(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  CALOAD on null array — pushing 0", .{});
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  CALOAD on invalid handle 0x{x:0>8} — pushing 0", .{ref});
        try frame.push(0);
        return;
    };
    if (inst.bytes) |b| {
        if (idx < b.len) {
            try frame.push(@as(u32, b[idx]));
            return;
        }
    }
    const slot = 1 + idx;
    const v: u32 = if (slot < inst.fields.len) inst.fields[slot] & 0xFF else 0;
    try frame.push(v);
}

/// SALOAD (opcode 0x35, canonical sub_40FA40) — load one short element,
/// sign-extended 16→32. Canonical reads `*(__int16 *)(v1 + 20 + 2*v2)`, i.e.
/// a signed 2-byte little-endian value at element offset `2*idx`.
///
/// Storage: 1 byte per element in `.bytes` (byte/char/short share this;
/// so we read 2 bytes LE from `.bytes[2*idx]` and sign-extend. Char-compatible
/// a 2-byte-stride model was reverted — see the note in the body).
/// they never legitimately reach SALOAD, but if they do we read the packed
/// byte rather than mis-striding. `.ints`/`fields` remain as last-resort
/// fallbacks for arrays that were populated through another path.
///
/// (This opcode was originally bound to opIaload, whose `fields[1+idx]`
/// fallback returns 0 past index 62 — the "BanjoKazooie enemies draw as 0×0"
/// bug. It then read `.bytes` 1-byte unsigned, which truncated true shorts.)
pub fn opSaload(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  SALOAD on null array — pushing 0", .{});
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  SALOAD on invalid handle 0x{x:0>8} — pushing 0", .{ref});
        try frame.push(0);
        return;
    };
    // 1 byte per element (byte/char/short share this). A 2-byte-stride model
    // was reverted: AoE & others read the same short arrays at 1-byte stride
    // via CALOAD/ARRSTORE, so widening only SALOAD/SASTORE garbled layouts.
    if (inst.bytes) |b| {
        if (idx < b.len) {
            try frame.push(@as(u32, b[idx]));
            return;
        }
    }
    if (inst.ints) |ix| {
        if (idx < ix.len) {
            try frame.push(ix[idx]);
            return;
        }
    }
    const slot = 1 + idx;
    const v: u32 = if (slot < inst.fields.len) inst.fields[slot] else 0;
    try frame.push(v);
}

/// SASTORE (opcode 0x56, canonical sub_40FB44) — store the low 16 bits of the
/// value into a short element: `*(_WORD *)(v1 + 20 + 2*v3) = (u16)value`.
/// Distinct from opArrStore (byte/int width): a short array carries
/// 1 byte per element at `idx` (matches SALOAD/CALOAD/ARRSTORE; a 2-byte
/// stride was tried and reverted because it desynced arrays other opcodes
/// the ASCII text path is untouched.
pub fn opSastore(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  SASTORE on null array — ignored", .{});
        return;
    }
    const inst = vm.heap.get(ref) orelse return;
    if (inst.bytes) |b| {
        if (idx < b.len) b[idx] = @truncate(v);
    }
    if (inst.ints) |ix| {
        if (idx < ix.len) ix[idx] = v;
    }
    const slot = 1 + idx;
    if (slot < inst.fields.len) inst.fields[slot] = v;
}

/// LALOAD (opcode 0x2f, canonical sub_40CA2F) — load one long element.
/// Long arrays are allocated by NEWARRAY into `.ints` with stride 2
/// (see opNewarray: elem_shift == 3 → len*2 u32s), so element k occupies
/// ints[2k] (lo) and ints[2k+1] (hi). Pushes lo then hi (2 slots).
pub fn opLaload(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  LALOAD on null array — pushing 0L", .{});
        try frame.push(0);
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  LALOAD on invalid handle 0x{x:0>8} — pushing 0L", .{ref});
        try frame.push(0);
        try frame.push(0);
        return;
    };
    var lo: u32 = 0;
    var hi: u32 = 0;
    if (inst.ints) |ix| {
        const base = 2 * idx;
        if (base + 1 < ix.len) {
            lo = ix[base];
            hi = ix[base + 1];
        }
    }
    try frame.push(lo);
    try frame.push(hi);
}

/// LASTORE (opcode 0x50, canonical sub_40CB8F) — store one long element.
/// Pops ref, idx, and a 2-slot long value (4 slots total). Distinct from
/// opArrStore, which pops only 3: binding LASTORE to opArrStore left the
/// stack one slot high AND truncated the value to its low word.
pub fn opLastore(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const hi = try frame.pop();
    const lo = try frame.pop();
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  LASTORE on null array — ignored", .{});
        return;
    }
    const inst = vm.heap.get(ref) orelse return;
    if (inst.ints) |ix| {
        const base = 2 * idx;
        if (base + 1 < ix.len) {
            ix[base] = lo;
            ix[base + 1] = hi;
        }
    }
}

pub fn opArrStore(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const v = try frame.pop();
    const idx = try frame.pop();
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  ARRSTORE on null array — ignored", .{});
        return;
    }
    const inst = vm.heap.get(ref) orelse return;
    if (inst.bytes) |b| {
        if (idx < b.len) b[idx] = @truncate(v);
    }
    // Dynamic int[] storage (allocated by NEWARRAY tag 0x59 for arrays
    // larger than 63 slots — see opIaload note).
    if (inst.ints) |ix| {
        if (idx < ix.len) ix[idx] = v;
    }
    const slot = 1 + idx;
    if (slot < inst.fields.len) inst.fields[slot] = v;
}

pub fn opArraylength(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const ref = try frame.pop();
    if (ref == 0) {
        log.warn("  ARRAYLENGTH on null array — pushing 0", .{});
        try frame.push(0);
        return;
    }
    const inst = vm.heap.get(ref) orelse {
        log.warn("  ARRAYLENGTH on invalid handle — pushing 0", .{});
        try frame.push(0);
        return;
    };
    try frame.push(inst.fields[0]);
}
