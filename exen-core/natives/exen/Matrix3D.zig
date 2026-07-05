//! exen.Matrix3D — native funcs_407AA2[] indices 123..128
//!
//! Hash 0x8f9e8280. 4×4 fixed-point matrix ops for 3D transforms.
//!
//! Storage (verified from the builtin <init> bytecode: `BIPUSH 16;
//! NEWARRAY int[]; PUTFIELD_OWN → 0x1822f276`): the wrapper instance
//! holds an int[16] handle in field `element` (0x1822f276); the data is
//! a ROW-MAJOR 4×4 matrix in Q16.16 (identity element = 0x10000).
//! Family convention: every product pre-shifts both operands >>8 so
//! results land back in Q16.16 — `(a>>8)*(b>>8) == a*b/65536`.
//!
//! Angles use the canonical 2048-step circle (mask 0x7FF); canonical
//! sub_41C972 = cos (Q16 table lookup, full scale ≈65536) and
//! sub_41C956(a) = sub_41C972(a-512) = sin. We approximate the table
//! with float trig at the same scale (same approach as exen.Math).
//!
//! Method hashes (from the builtin 4CVP record @0x7b24):
//!   123 copyFrom  0x46ca2f89  sub_426B20
//!   124 rotX      0x305a66f1  sub_426B89
//!   125 rotY      0x305a7778  sub_426BE3
//!   126 rotZ      0x305a45e3  sub_426C3D
//!   127 multiply  0x6512b8f5  sub_426C97  (⚠ name inferred: 4×4 matmul)
//!   128 transform 0x2b45b8f5  sub_426D7B  (⚠ name inferred: mat × vec)

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "Matrix3D";
pub const first_index: u32 = 123;
pub const last_index: u32 = 128;

/// The int[16] handle field on the wrapper (canonical instance +24).
const FIELD_ELEMENT: u32 = 0x1822f276;

/// Vector3D component fields (shared layout — see Vector3D.zig).
const FIELD_VX: u32 = 0xd042f048;
const FIELD_VY: u32 = 0xd042e1c1;
const FIELD_VZ: u32 = 0xd042d35a;

/// Resolve a Matrix3D wrapper handle to its 16-int element slice.
/// Reads go through `.ints` (the storage IALOAD prefers), so native
/// writes stay coherent with bytecode reads.
fn elements(vm: *Vm, wrapper: Handle) ?[]u32 {
    const inst = vm.heap.get(wrapper) orelse return null;
    const data = inst.field_map.get(FIELD_ELEMENT) orelse 0;
    if (data == 0) return null;
    const arr = vm.heap.get(data) orelse return null;
    const ix = arr.ints orelse return null;
    if (ix.len < 16) return null;
    return ix[0..16];
}

/// Canonical sub_41C972: cos on the 2048-step circle, Q16 result.
fn cosQ16(angle: i32) i32 {
    const a: f64 = @floatFromInt(@mod(angle, 2048));
    const r = @cos(a * (std.math.tau / 2048.0));
    return @intFromFloat(r * 65536.0);
}

/// Canonical sub_41C956: sin(a) = cos(a - 512).
fn sinQ16(angle: i32) i32 {
    return cosQ16(angle - 512);
}

/// Q16.16 product with the family's pre-shift convention.
inline fn fxMul(a: i32, b: i32) i32 {
    return (a >> 8) *% (b >> 8);
}

/// Overwrite `m` with a rotation matrix. `kind`: 0=X, 1=Y, 2=Z —
/// canonical sub_41D25B / sub_41D2C4 / sub_41D32E respectively.
fn buildRotation(m: []u32, angle: i32, kind: u2) void {
    const c: u32 = @bitCast(cosQ16(angle));
    const s: u32 = @bitCast(sinQ16(angle));
    const ns: u32 = @bitCast(-sinQ16(angle));
    const one: u32 = 0x10000;
    @memset(m, 0);
    switch (kind) {
        0 => { // rotX: [5]=c [6]=s [9]=-s [10]=c, [0]=[15]=1
            m[0] = one;
            m[5] = c;
            m[6] = s;
            m[9] = ns;
            m[10] = c;
            m[15] = one;
        },
        1 => { // rotY: [0]=c [2]=-s [8]=s [10]=c, [5]=[15]=1
            m[0] = c;
            m[2] = ns;
            m[5] = one;
            m[8] = s;
            m[10] = c;
            m[15] = one;
        },
        else => { // rotZ: [0]=c [1]=s [4]=-s [5]=c, [10]=[15]=1
            m[0] = c;
            m[1] = s;
            m[4] = ns;
            m[5] = c;
            m[10] = one;
            m[15] = one;
        },
    }
}

// ── [123] copyFrom(src) — sub_426B20 ────────────────────────────────────────
// Canonical: sub_41D47C(this.elements, src.elements) — copy 16 ints;
// a null source zero-fills instead. Pushes nothing.
fn copyFrom(vm: *Vm, args: bridge.ArgFrame) i16 {
    const dst = elements(vm, args.this()) orelse return 0;
    if (elements(vm, args.handle(1))) |src| {
        @memcpy(dst, src);
    } else {
        @memset(dst, 0);
    }
    return 0;
}

// ── [124..126] rotX/rotY/rotZ(angle) — sub_426B89/sub_426BE3/sub_426C3D ────
// Canonical builds the rotation into a stack temp then copies it over
// this matrix (an OVERWRITE, not a compose). Pushes nothing.
fn rotX(vm: *Vm, args: bridge.ArgFrame) i16 {
    const m = elements(vm, args.this()) orelse return 0;
    buildRotation(m, args.getI32(1), 0);
    return 0;
}

fn rotY(vm: *Vm, args: bridge.ArgFrame) i16 {
    const m = elements(vm, args.this()) orelse return 0;
    buildRotation(m, args.getI32(1), 1);
    return 0;
}

fn rotZ(vm: *Vm, args: bridge.ArgFrame) i16 {
    const m = elements(vm, args.this()) orelse return 0;
    buildRotation(m, args.getI32(1), 2);
    return 0;
}

// ── [127] multiply(other) — sub_426C97 ──────────────────────────────────────
// ⚠ name inferred. Canonical: copies this and other into temps, runs the
// 4×4 multiply sub_41D396 (triple loop, `>>8` products) and writes the
// result back onto THIS. Pushes nothing.
fn multiply(vm: *Vm, args: bridge.ArgFrame) i16 {
    const a = elements(vm, args.this()) orelse return 0;
    const b = elements(vm, args.handle(1)) orelse return 0;
    var out: [16]i32 = undefined;
    for (0..4) |row| {
        for (0..4) |col| {
            var acc: i32 = 0;
            for (0..4) |k| {
                const av: i32 = @bitCast(a[row * 4 + k]);
                const bv: i32 = @bitCast(b[k * 4 + col]);
                acc +%= fxMul(av, bv);
            }
            out[row * 4 + col] = acc;
        }
    }
    for (0..16) |i| a[i] = @bitCast(out[i]);
    return 0;
}

// ── [128] transform(src, dst) — sub_426D7B ──────────────────────────────────
// ⚠ name inferred. Canonical: loads src Vector3D {x,y,z}, computes
// row·vector (sub_41D17B, `>>8` products) against THIS matrix, stores
// into dst Vector3D's components. Pushes nothing.
fn transform(vm: *Vm, args: bridge.ArgFrame) i16 {
    const m = elements(vm, args.this()) orelse return 0;
    const src = vm.heap.get(args.handle(1)) orelse return 0;
    const dst = vm.heap.get(args.handle(2)) orelse return 0;
    const x: i32 = @bitCast(src.field_map.get(FIELD_VX) orelse 0);
    const y: i32 = @bitCast(src.field_map.get(FIELD_VY) orelse 0);
    const z: i32 = @bitCast(src.field_map.get(FIELD_VZ) orelse 0);
    var out: [3]i32 = undefined;
    for (0..3) |row| {
        const r0: i32 = @bitCast(m[row * 4 + 0]);
        const r1: i32 = @bitCast(m[row * 4 + 1]);
        const r2: i32 = @bitCast(m[row * 4 + 2]);
        out[row] = fxMul(r0, x) +% fxMul(r1, y) +% fxMul(r2, z);
    }
    dst.field_map.put(FIELD_VX, @bitCast(out[0])) catch {};
    dst.field_map.put(FIELD_VY, @bitCast(out[1])) catch {};
    dst.field_map.put(FIELD_VZ, @bitCast(out[2])) catch {};
    return 0;
}

pub const entries = .{
    .{ 123, "copyFrom",  copyFrom },
    .{ 124, "rotX",      rotX },
    .{ 125, "rotY",      rotY },
    .{ 126, "rotZ",      rotZ },
    .{ 127, "multiply",  multiply },
    .{ 128, "transform", transform },
};

pub const handle = bridge.canonical(entries);
