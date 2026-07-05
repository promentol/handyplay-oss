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
//! Full class: 129 squareLength, 130 length, 131 normalise, 132 sum,
//! 133 minus, 134 dot, 135 crossProduct, 136 multiply (scalar, ⚠ name
//! inferred). Q16.16 components; products pre-shift both operands >>8.

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "Vector3D";
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

const Xyz = struct { x: i32, y: i32, z: i32 };

fn getXyz(vm: *Vm, handle_v: Handle) ?Xyz {
    const inst = vm.heap.get(handle_v) orelse return null;
    return .{
        .x = @bitCast(inst.field_map.get(FIELD_X) orelse 0),
        .y = @bitCast(inst.field_map.get(FIELD_Y) orelse 0),
        .z = @bitCast(inst.field_map.get(FIELD_Z) orelse 0),
    };
}

fn setXyz(vm: *Vm, handle_v: Handle, v: Xyz) void {
    const inst = vm.heap.get(handle_v) orelse return;
    inst.field_map.put(FIELD_X, @bitCast(v.x)) catch {};
    inst.field_map.put(FIELD_Y, @bitCast(v.y)) catch {};
    inst.field_map.put(FIELD_Z, @bitCast(v.z)) catch {};
}

// ── [131] normalise() → int — sub_42A0C8 ───────────────────────────────────
// Canonical loads {x,y,z}, calls sub_41CF17 (normalize-in-place helper:
// length via isqrt chain; components scaled to unit length), maps the
// isqrt overflow marker -5 → -1, writes the components back and pushes
// the status int. ⚠ sub_41CF17's exact rounding not byte-verified; we
// scale each component by 1.0/len in Q16.16 with i64 intermediates
// (comp * 0x10000 / len) which matches the helper's fixed-point family.
// Zero-length vectors: skip the writeback, push 0.
fn normalise(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const v = getXyz(vm, this) orelse {
        args.setReturnI32(0);
        return 1;
    };
    var len = lengthRaw(v.x, v.y, v.z);
    if (len == -5) len = -1;
    if (len > 0) {
        setXyz(vm, this, .{
            .x = @intCast(@divTrunc(@as(i64, v.x) * 0x10000, len)),
            .y = @intCast(@divTrunc(@as(i64, v.y) * 0x10000, len)),
            .z = @intCast(@divTrunc(@as(i64, v.z) * 0x10000, len)),
        });
    }
    args.setReturnI32(len);
    return 1;
}

// ── [132] sum(other) — sub_42A132 ───────────────────────────────────────────
// Canonical sub_41CFC7: plain componentwise add (no shifting for adds),
// result written back to THIS. Pushes nothing.
fn sum(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const a = getXyz(vm, this) orelse return 0;
    const b = getXyz(vm, args.handle(1)) orelse return 0;
    setXyz(vm, this, .{ .x = a.x +% b.x, .y = a.y +% b.y, .z = a.z +% b.z });
    return 0;
}

// ── [133] minus(other) — sub_42A1AD ─────────────────────────────────────────
// Canonical sub_41D004: this − other, written back to THIS. Pushes nothing.
fn minus(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const a = getXyz(vm, this) orelse return 0;
    const b = getXyz(vm, args.handle(1)) orelse return 0;
    setXyz(vm, this, .{ .x = a.x -% b.x, .y = a.y -% b.y, .z = a.z -% b.z });
    return 0;
}

// ── [134] dot(other) → int — sub_42A228 ─────────────────────────────────────
// Canonical sub_41D041: Σ (a>>8)*(b>>8) per component — Q16.16 dot with
// the family's pre-shift convention. Pushes 1 int.
fn dot(vm: *Vm, args: bridge.ArgFrame) i16 {
    const a = getXyz(vm, args.this()) orelse {
        args.setReturnI32(0);
        return 1;
    };
    const b = getXyz(vm, args.handle(1)) orelse {
        args.setReturnI32(0);
        return 1;
    };
    args.setReturnI32((a.x >> 8) *% (b.x >> 8) +%
        (a.y >> 8) *% (b.y >> 8) +%
        (a.z >> 8) *% (b.z >> 8));
    return 1;
}

// ── [135] crossProduct(other) — sub_42A28A ──────────────────────────────────
// Canonical sub_41D090: 3-term cross product, each product pre-shifted
// (a>>8)*(b>>8) to stay in Q16.16, written back to THIS. Pushes nothing.
fn crossProduct(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const a = getXyz(vm, this) orelse return 0;
    const b = getXyz(vm, args.handle(1)) orelse return 0;
    setXyz(vm, this, .{
        .x = (a.y >> 8) *% (b.z >> 8) -% (a.z >> 8) *% (b.y >> 8),
        .y = (a.z >> 8) *% (b.x >> 8) -% (a.x >> 8) *% (b.z >> 8),
        .z = (a.x >> 8) *% (b.y >> 8) -% (a.y >> 8) *% (b.x >> 8),
    });
    return 0;
}

// ── [136] multiply(scalar) — sub_42A305 ─────────────────────────────────────
// ⚠ name inferred (scalar multiply; no strings-region name). Canonical
// sub_41D12B: each component = (comp>>8) * (scalar>>8), written back to
// THIS. Pushes nothing.
fn multiplyScalar(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const a = getXyz(vm, this) orelse return 0;
    const s = args.getI32(1);
    setXyz(vm, this, .{
        .x = (a.x >> 8) *% (s >> 8),
        .y = (a.y >> 8) *% (s >> 8),
        .z = (a.z >> 8) *% (s >> 8),
    });
    return 0;
}

pub const entries = .{
    .{ 129, "squareLength", squareLength },
    .{ 130, "length",       length },
    .{ 131, "normalise",    normalise },
    .{ 132, "sum",          sum },
    .{ 133, "minus",        minus },
    .{ 134, "dot",          dot },
    .{ 135, "crossProduct", crossProduct },
    .{ 136, "multiply",     multiplyScalar },
};

pub const handle = bridge.canonical(entries);
