//! exen.Vector3D — native funcs_407AA2[] indices 129..136
//!
//! Hash 0xe36f9667. 3D vector arithmetic, fixed-point (shifted-byte).
//!
//! Field hashes from docs/extracted/exen_Vector3D.md (instance fields,
//! all `int`, slots 0/1/2):
//!   x = 0xd042f048
//!   y = 0xd042e1c1
//!   z = 0xd042d35a
//!
//! Currently implements idx 129 (squareLength) and idx 130 (length).
//! Other natives (131..136 = normalise/sum/minus/dot/crossProduct/scale)
//! fall through to defaultNativeStub.

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 129;
pub const last_index: u32 = 136;

const FIELD_X: u32 = 0xd042f048;
const FIELD_Y: u32 = 0xd042e1c1;
const FIELD_Z: u32 = 0xd042d35a;

/// Canonical integer sqrt — port of sub_41CE03 (ref:20597).
/// Walks MSBs down, refines candidate digit-by-digit against squared
/// target. Faithful to canonical bit-pattern semantics.
fn isqrt(a1: i32) i32 {
    if (a1 < 2) return a1;
    var v7: u32 = @bitCast(a1);
    var i: u5 = 0;
    while (true) {
        v7 >>= 2;
        if (v7 == 0) break;
        i += 1;
    }
    var v8: u32 = @as(u32, 1) << i;
    var v6: u32 = @as(u32, 1) << i;
    var v4: u32 = v8 << i;
    while (i > 0) {
        i -= 1;
        v6 >>= 1;
        const v3 = v4 + ((v6 + 2 * v8) << i);
        if (v3 <= @as(u32, @bitCast(a1))) {
            v8 += v6;
            v4 = v3;
        }
    }
    return @bitCast(v8);
}

/// Squared-length helper — port of sub_41CEB4 (ref:20632).
/// Each coordinate is right-shifted by 8 (drop low fixed-point fraction)
/// before squaring, then summed.
fn squareLengthRaw(x: i32, y: i32, z: i32) i32 {
    const xs = x >> 8;
    const ys = y >> 8;
    const zs = z >> 8;
    return zs * zs + ys * ys + xs * xs;
}

/// Length helper — port of sub_41CEFA (ref:20638).
///   sub_41CE03(squareLength) << 8     // shift back into fixed-point space
fn lengthRaw(x: i32, y: i32, z: i32) i32 {
    return isqrt(squareLengthRaw(x, y, z)) << 8;
}

// ── [129] squareLength() → int — sub_42A020 ────────────────────────────────
fn squareLength(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this()) orelse {
        args.setReturnI32(0);
        return 1;
    };
    const x: i32 = @bitCast(inst.field_map.get(FIELD_X) orelse 0);
    const y: i32 = @bitCast(inst.field_map.get(FIELD_Y) orelse 0);
    const z: i32 = @bitCast(inst.field_map.get(FIELD_Z) orelse 0);
    args.setReturnI32(squareLengthRaw(x, y, z));
    return 1;
}

// ── [130] length() → int — sub_42A074 ──────────────────────────────────────
// Canonical body (ref:28108):
//   v3[3] = { this.x, this.y, this.z };
//   v4 = sub_41CEFA(v3);   // isqrt(x²+y²+z²) << 8
//   if (v4 == -5) v4 = -1;  // overflow clamp
//   return v4;
fn length(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this()) orelse {
        args.setReturnI32(0);
        return 1;
    };
    const x: i32 = @bitCast(inst.field_map.get(FIELD_X) orelse 0);
    const y: i32 = @bitCast(inst.field_map.get(FIELD_Y) orelse 0);
    const z: i32 = @bitCast(inst.field_map.get(FIELD_Z) orelse 0);
    var v4 = lengthRaw(x, y, z);
    if (v4 == -5) v4 = -1;
    args.setReturnI32(v4);
    return 1;
}

pub const handle = bridge.canonical(.{
    .{ 129, "Vector3D.squareLength", squareLength },
    .{ 130, "Vector3D.length",       length },
});
