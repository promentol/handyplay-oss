//! exen.Math — native funcs_407AA2[] indices 110..122
//!
//! Hash 0x3298b202. Integer sin/cos table + sqrt + random.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.
//!
//! All handlers are plain Zig functions; `bridge.dispatcher` synthesises
//! the frame-marshalling shim at comptime.

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

pub const class_name: []const u8 = "Math";
pub const first_index: u32 = 110;
pub const last_index: u32 = 122;

/// Shared global sinus period. Canonical default is 2048 (11-bit angle):
/// `sub_41C972` masks the input with `0x7FF` (= 2048-1) and indexes the
/// 512-entry quarter-period table `word_4567F8`. Period 1024 was a prior
/// guess that doubled every gamelet's angular speed (sin/cos returning
/// values for angle*2 instead of angle).
/// The gamelet can override via [113] setSinusPeriod; subsequent
/// [110] sin / [111] cos / [112] getAngle calls observe the new period.
const SinusPeriod = struct {
    var value: i32 = 2048;
};

/// Canonical PRNG state (sub_41CD5D in reference/ref).
/// Two 32-bit words at `*(VmState+8) + 0` (state_a) and `+4` (state_b).
/// Per call:
///   n        = state_b & 0x1F
///   state_a  = ror32(state_a, n)
///   state_b  = (original state_a) XOR 0x5960395
///   state_a += state_b + 31009
///   return state_a
/// Initial seed: setRandSeed writes state_a directly; state_b is
/// initialised at boot (we use 0 as a default since the canonical's
/// boot path zeroes the pool).
// PRNG state lives on the Vm (vm.rng_a/rng_b) so save-states capture it; see
// setRandSeed / random below.

fn computeSinCos(x: i32, period: i32, want_sin: bool) i32 {
    const period_f = @as(f64, @floatFromInt(period));
    const angle_rad: f64 = (@as(f64, @floatFromInt(x)) / period_f) * std.math.tau;
    const r = if (want_sin) @sin(angle_rad) else @cos(angle_rad);
    // Q16 amplitude (±65535), matching canonical. Canonical's sin/cos
    // (sub_41C972) returns `(unsigned __int16)word_4567F8[...]`: the table
    // stores sin·65535 as int16, and the unsigned cast means the entries
    // that decompile as -1/-2/… are really 65535/65534/… — i.e. full Q16,
    // NOT Q15. Callers do `val * sin >> 16`, so a smaller amplitude scales
    // all trig-derived geometry down (e.g. the AoE menu's per-item radius
    // step: at Q14 items overlapped at ~3px; Q16 gives the correct ~10px).
    return @intFromFloat(r * 65535.0);
}

// All Math natives are canonical-shape: take (vm, args) and return push count.
// Most are static (a1[0] = first arg, no `this`).

fn sin(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(computeSinCos(args.getI32(0), SinusPeriod.value, true));
    return 1;
}

fn cos(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(computeSinCos(args.getI32(0), SinusPeriod.value, false));
    return 1;
}

fn getAngle(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    const dx = args.getI32(0);
    const dy = args.getI32(1);
    if (dx == 0 and dy == 0) {
        args.setReturnI32(0);
        return 1;
    }
    const a = std.math.atan2(@as(f64, @floatFromInt(dy)), @as(f64, @floatFromInt(dx)));
    const period: f64 = @floatFromInt(SinusPeriod.value);
    args.setReturnI32(@intFromFloat(@mod((a / std.math.tau) * period + period, period)));
    return 1;
}

fn setSinusPeriod(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    SinusPeriod.value = args.getI32(0);
    return 0;
}

fn getSinusPeriod(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(SinusPeriod.value);
    return 1;
}

fn sinFixed1024(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(computeSinCos(args.getI32(0), 1024, true));
    return 1;
}

fn cosFixed1024(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(computeSinCos(args.getI32(0), 1024, false));
    return 1;
}

fn abs(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    const x = args.getI32(0);
    args.setReturnI32(if (x < 0) -%x else x);
    return 1;
}

fn setRandSeed(vm: *interp.Vm, args: bridge.ArgFrame) i16 {
    vm.rng_a = args.getU32(0);
    vm.rng_b = 0;
    return 0;
}

// Port of the canonical PRNG (NOT xorshift). Right-rotates state_a by
// `state_b & 0x1F` bits, then mixes state_a back into state_b via XOR,
// and adds 31009 to produce the next output. Pair-state algorithm.
fn random(vm: *interp.Vm, args: bridge.ArgFrame) i16 {
    const a_orig = vm.rng_a;
    const shift: u5 = @truncate(vm.rng_b & 0x1F);
    const rotated = if (shift == 0) a_orig else std.math.rotr(u32, a_orig, shift);
    vm.rng_b = a_orig ^ 0x05960395;
    vm.rng_a = rotated +% vm.rng_b +% 31009;
    args.setReturn(vm.rng_a);
    return 1;
}

/// Integer square root — canonical sub_41CE03 (ref:20597).
/// Classic non-restoring bit-shift floor(sqrt) for a1 >= 2.
/// For a1 < 2 (including negatives) the canonical short-circuits and
/// returns a1 unchanged — this preserves the quirky negative-input
/// behaviour the sub_426ADD wrapper relies on (e.g. sqrt(-5) = -5
/// before remap).
fn intSqrt(a1_in: i32) i32 {
    if (a1_in < 2) return a1_in;
    var v7: u32 = @bitCast(a1_in);
    var i: u5 = 0;
    while (true) : (i += 1) {
        v7 >>= 2;
        if (v7 == 0) break;
    }
    var v8: u32 = @as(u32, 1) << i;
    var v6: u32 = @as(u32, 1) << i;
    var v4: u32 = (@as(u32, 1) << i) << i;
    while (i > 0) {
        i -= 1;
        v6 >>= 1;
        const v3: u32 = v4 +% ((v6 + 2 *% v8) << i);
        if (v3 <= @as(u32, @bitCast(a1_in))) {
            v8 +%= v6;
            v4 = v3;
        }
    }
    return @bitCast(v8);
}

/// Math.sqrt (idx 122) — canonical sub_426ADD (ref:26204).
/// Body: v2 = sub_41CE03(*a1); if (v2 == -5) v2 = -1; *a1 = v2; return 1.
fn sqrt(_: *interp.Vm, args: bridge.ArgFrame) i16 {
    var v2 = intSqrt(args.getI32(0));
    if (v2 == -5) v2 = -1;
    args.setReturnI32(v2);
    return 1;
}

pub const entries = .{
    .{ 110, "sin",                 sin },
    .{ 111, "cos",                 cos },
    .{ 112, "getAngle",            getAngle },
    .{ 113, "setSinusPeriod",      setSinusPeriod },
    .{ 114, "getSinusPeriod",      getSinusPeriod },
    .{ 115, "getSinOfPeriod",      sinFixed1024 },
    .{ 116, "getCosOfPeriod",      cosFixed1024 },
    .{ 117, "getCosPeriodPrecise", cosFixed1024 },
    .{ 118, "getSinPeriodPrecise", sinFixed1024 },
    .{ 119, "abs",                 abs },
    .{ 120, "setRandSeed",         setRandSeed },
    .{ 121, "random",              random },
    .{ 122, "sqrt",                sqrt },
};

pub const handle = bridge.canonical(entries);
