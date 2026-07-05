//! exen.FX — native funcs_407AA2[] indices 103..108
//!
//! Hash 0xd8f81132. Per-pixel effects: rotozoom, mosaic, shutter
//! (the demoscene-style image transforms the platform shipped as a
//! "framework FX" pack). All six methods are `static native`.
//!
//! Per-class table (idx = funcs_407AA2 line − 3126 in emulator.c; the
//! old header's subs/names were positional guesses and were wrong):
//!   idx 103  sub_424B70  doRotozoomImage       kernel sub_415B6A  ✓
//!   idx 104  sub_424BFD  doMosaic              kernel sub_415FC6  ✓
//!   idx 105  sub_424C84  doShiftHorizontal     kernel sub_41688D  ✓
//!   idx 106  sub_424D62  doShiftVertical       kernel sub_416B75  ✓
//!   idx 107  sub_424E40  doVerticalShutter     kernel sub_4162D0  ✓
//!   idx 108  sub_424ED2  doHorizontalShutter   kernel sub_416715  ✓
//!
//! Kernel provenance: the natives dispatch through the per-depth FX
//! table at `desc[10]+64`. The 16-bit device table (off_457EF0) is ALL
//! EMPTY STUBS in canonical; only the 8-bit paletted table (off_456018)
//! has real kernels, which write palette bytes. We sample the source's
//! decoded ABGR (`inst.pixels`) and write ABGR into the Graphics
//! target — same visual result, and we run regardless of source depth
//! (our pipeline decodes everything to ABGR; the canonical 16-bit
//! no-op was a device limitation, not a semantic).

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;
const _h = @import("../_helpers.zig");

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "FX";
pub const first_index: u32 = 103;
pub const last_index: u32 = 108;

// ── [103] doRotozoomImage(image, graphics, x, y, angle, scale) — sub_424B70 ─
// Canonical body (ref:24813):
//   v2 = sub_426785(a1[1])                          // dest Graphics descriptor
//   v3 = sub_426785(*(DWORD*)(a1[0] + 24))          // src Image descriptor (via .bytes ptr)
//   if (!v3 || !v2) { sub_434771("FX.doRotaZoom: image pointer might be null"); sub_407A13(); return 0; }
//   ( *(v2[10] + 64) )(v2, v3, a1[2], a1[3], a1[4], a1[5])
//   return 0
//
// The vtable slot at `v2[10] + 64` is the device-specific rotozoom kernel —
// the reference simulator populates it from a fixed-point cos/sin table walker that, for
// each destination pixel within a (2*src_dim)-wide bounding box centred
// on (x,y), computes inverse-transformed source coords and samples src.
// We mirror that math directly with `std.math.sin/cos`; the canonical's
// per-device dispatch only differs by depth (8/16/24-bit kernel) and we
// always render into our 32-bit ABGR target.
//
// Args interpretation (consistent across J2ME rotozoom shipments):
//   image  : source Image handle (treated as static, no `this`)
//   gfx    : target Graphics handle
//   x, y   : destination CENTRE pixel
//   angle  : 0..256 mod 256 = full turn (8-bit angle)
//   scale  : 256 = 1.0 (fixed-point, source magnification)
// Wallbreaker invokes this for the ball trail + brick-burst FX (~32×/run).
fn doRotozoomImage(vm: *Vm, args: bridge.ArgFrame) i16 {
    const image = args.handle(0);
    const graphics = args.handle(1);
    const dest_cx = args.getI32(2);
    const dest_cy = args.getI32(3);
    const angle = args.getI32(4);
    const scale = args.getI32(5);
    if (image == 0 or graphics == 0) return 0;

    const target = _h.graphicsTarget(vm, graphics) orelse return 0;
    const inst = vm.heap.get(image) orelse return 0;
    if (inst.pixels == null) _h.doTransformToSystemPalette(vm, image);
    const src_px = inst.pixels orelse return 0;
    const src_w: i32 = @intCast(inst.pix_w);
    const src_h: i32 = @intCast(inst.pix_h);
    if (src_w <= 0 or src_h <= 0) return 0;

    const tw: i32 = @intCast(target.width);
    const th: i32 = @intCast(target.height);

    // Identity fast path — common case is angle=0, scale=256 (just a
    // centred blit). Skips trig and floating-point.
    if (angle == 0 and scale == 256) {
        const dx0 = dest_cx - @divTrunc(src_w, 2);
        const dy0 = dest_cy - @divTrunc(src_h, 2);
        var y: i32 = 0;
        while (y < src_h) : (y += 1) {
            var x: i32 = 0;
            while (x < src_w) : (x += 1) {
                const dx = dx0 + x;
                const dy = dy0 + y;
                if (dx < 0 or dy < 0 or dx >= tw or dy >= th) continue;
                const sp = src_px[@as(usize, @intCast(y)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(x))];
                if ((sp >> 24) == 0) continue;
                target.pixels[@as(usize, @intCast(dy)) * target.width + @as(usize, @intCast(dx))] = sp;
            }
        }
        return 0;
    }

    // General rotozoom — inverse-transform sample. Angle is 8-bit
    // (256 = full turn); scale is fixed-point with 256 = 1.0.
    const a_norm: i32 = @mod(angle, 256);
    const angle_rad: f32 = @as(f32, @floatFromInt(a_norm)) *
        (std.math.pi * 2.0 / 256.0);
    const cos_a = std.math.cos(angle_rad);
    const sin_a = std.math.sin(angle_rad);
    const safe_scale: i32 = if (scale <= 0) 256 else scale;
    const inv_scale: f32 = 256.0 / @as(f32, @floatFromInt(safe_scale));

    const src_cx: f32 = @floatFromInt(@divTrunc(src_w, 2));
    const src_cy: f32 = @floatFromInt(@divTrunc(src_h, 2));

    // Conservative bounding box: rotation+scale can extend source bounds
    // by sqrt(2)*scale at most. Round up to (max(w,h) * scale + a margin).
    const bb_radius_i: i32 = @intFromFloat(@ceil(
        @as(f32, @floatFromInt(@max(src_w, src_h))) *
            @as(f32, @floatFromInt(safe_scale)) / 256.0,
    ));
    const bb_x0 = @max(dest_cx - bb_radius_i, 0);
    const bb_x1 = @min(dest_cx + bb_radius_i, tw);
    const bb_y0 = @max(dest_cy - bb_radius_i, 0);
    const bb_y1 = @min(dest_cy + bb_radius_i, th);

    var dy = bb_y0;
    while (dy < bb_y1) : (dy += 1) {
        var dx = bb_x0;
        while (dx < bb_x1) : (dx += 1) {
            const ddx: f32 = @floatFromInt(dx - dest_cx);
            const ddy: f32 = @floatFromInt(dy - dest_cy);
            const sx_f = (ddx * cos_a + ddy * sin_a) * inv_scale + src_cx;
            const sy_f = (-ddx * sin_a + ddy * cos_a) * inv_scale + src_cy;
            const sx: i32 = @intFromFloat(sx_f);
            const sy: i32 = @intFromFloat(sy_f);
            if (sx < 0 or sy < 0 or sx >= src_w or sy >= src_h) continue;
            const sp = src_px[@as(usize, @intCast(sy)) * @as(usize, @intCast(src_w)) + @as(usize, @intCast(sx))];
            if ((sp >> 24) == 0) continue;
            target.pixels[@as(usize, @intCast(dy)) * target.width + @as(usize, @intCast(dx))] = sp;
        }
    }
    return 0;
}

/// Resolve the (source image, dest target) pair every FX kernel needs.
/// Mirrors canonical: `v2 = sub_426785(a1[1])` dest, source via slot 0;
/// null either way → the sub_434771 + sub_407A13 fault path.
const FxCtx = struct {
    target: _h.DrawTarget,
    src_px: []const u32,
    src_w: i32,
    src_h: i32,
};

fn fxResolve(vm: *Vm, args: bridge.ArgFrame, comptime what: []const u8) ?FxCtx {
    const image = args.handle(0);
    const graphics = args.handle(1);
    if (image == 0 or graphics == 0) {
        vm.signalFault(0xc23defde, "FX." ++ what ++ ": image pointer might be null");
        return null;
    }
    const target = _h.graphicsTarget(vm, graphics) orelse return null;
    const inst = vm.heap.get(image) orelse return null;
    if (inst.pixels == null) _h.doTransformToSystemPalette(vm, image);
    const src_px = inst.pixels orelse return null;
    const w: i32 = @intCast(inst.pix_w);
    const h: i32 = @intCast(inst.pix_h);
    if (w <= 0 or h <= 0) return null;
    return .{ .target = target, .src_px = src_px, .src_w = w, .src_h = h };
}

// ── [104] doMosaic(image, graphics, x, y, step) — sub_424BFD → sub_415FC6 ──
// Kernel: pixelation via downsample-then-replicate. `step` is a fixed
// factor where 16 == 1:1 (kernel gates `step >= 16`); block size grows
// with step (65536/step per-pixel source increment, index = accum>>12,
// so step=32 → 2-px blocks). Canonical adds a periodic extra source
// jump to spread rounding error across the span; we take the plain
// accumulator (sub-pixel-identical for power-of-two steps, ±1 source
// pixel elsewhere). Copies raw pixels (no transparency skip).
fn doMosaic(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = fxResolve(vm, args, "doMosaic") orelse return 0;
    const x = args.getI32(2);
    const y = args.getI32(3);
    const step = args.getI32(4);
    if (step < 16) return 0;

    const tw: i32 = @intCast(ctx.target.width);
    const th: i32 = @intCast(ctx.target.height);
    const dx0 = @max(x, 0);
    const dy0 = @max(y, 0);
    const w = @min(tw - dx0, ctx.src_w);
    const h = @min(th - dy0, ctx.src_h);
    if (w <= 0 or h <= 0) return 0;

    const incr: i64 = @divTrunc(@as(i64, 65536), step);
    var acc_y: i64 = 0;
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        const sy: i32 = @intCast(@min(acc_y >> 12, ctx.src_h - 1));
        const src_row = @as(usize, @intCast(sy)) * @as(usize, @intCast(ctx.src_w));
        const dst_row = @as(usize, @intCast(dy0 + j)) * ctx.target.width;
        var acc_x: i64 = 0;
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            const sx: i32 = @intCast(@min(acc_x >> 12, ctx.src_w - 1));
            ctx.target.pixels[dst_row + @as(usize, @intCast(dx0 + i))] =
                ctx.src_px[src_row + @as(usize, @intCast(sx))];
            acc_x += incr;
        }
        acc_y += incr;
    }
    return 0;
}

// Blind-open table — canonical sub_4165F5: per 8-wide band, open amount
// 0..8 = `(9 * clamp(cos(phase), 0)) >> 16` with phase stepping −64 per
// band (dir=1) or the windowed variant offset by +512/+1536 (dir=0 —
// ⚠ window shape approximated: same cos wave sampled half a period
// later, which matches the observed closing-vs-opening direction).
fn blindOpen(phase: i32, band: i32, dir: i32) u32 {
    const p = if (dir != 0) phase - 64 * band else phase + 512 - 64 * band;
    const c = cosQ16(p);
    const clamped: i64 = if (c > 0) c else 0;
    const v = (9 * clamped) >> 16;
    return @intCast(@min(v, 8));
}

/// Canonical sub_41C972 cos: 2048-step circle, Q16 result (float approx
/// of the word_4567F8 table — same approach as exen.Math).
fn cosQ16(angle: i32) i32 {
    const a: f64 = @floatFromInt(@mod(angle, 2048));
    return @intFromFloat(@cos(a * (std.math.tau / 2048.0)) * 65536.0);
}

// ── [107] doVerticalShutter(image, graphics, phase, dir) — sub_424E40 →
// kernel sub_4162D0: the image is copied through vertical venetian
// blinds — width/8 bands of 8 columns each; per band only the first
// `blindOpen(...)` columns are copied full-height. phase animates the
// wave; dir selects opening/closing.
fn doVerticalShutter(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = fxResolve(vm, args, "doVerticalShutter") orelse return 0;
    const phase = args.getI32(2);
    const dir = args.getI32(3);
    const w = @min(ctx.src_w, @as(i32, @intCast(ctx.target.width)));
    const h = @min(ctx.src_h, @as(i32, @intCast(ctx.target.height)));
    if (w <= 0 or h <= 0) return 0;

    var band: i32 = 0;
    while (band * 8 < w) : (band += 1) {
        const open: i32 = @intCast(blindOpen(phase, band, dir));
        const col0 = band * 8;
        const ncols = @min(open, w - col0);
        var c: i32 = 0;
        while (c < ncols) : (c += 1) {
            const col: usize = @intCast(col0 + c);
            var row: usize = 0;
            while (row < @as(usize, @intCast(h))) : (row += 1) {
                ctx.target.pixels[row * ctx.target.width + col] =
                    ctx.src_px[row * @as(usize, @intCast(ctx.src_w)) + col];
            }
        }
    }
    return 0;
}

// ── [108] doHorizontalShutter(image, graphics, phase, dir) — sub_424ED2 →
// kernel sub_416715: same blind table over height/8 bands of 8 ROWS;
// open rows are copied via full-row memcpy. (Canonical strings-region
// name is doHorizontalShutter — the old positional "doShutterHorizontal"
// was wrong.)
fn doHorizontalShutter(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = fxResolve(vm, args, "doHorizontalShutter") orelse return 0;
    const phase = args.getI32(2);
    const dir = args.getI32(3);
    const w = @min(ctx.src_w, @as(i32, @intCast(ctx.target.width)));
    const h = @min(ctx.src_h, @as(i32, @intCast(ctx.target.height)));
    if (w <= 0 or h <= 0) return 0;

    var band: i32 = 0;
    while (band * 8 < h) : (band += 1) {
        const open: i32 = @intCast(blindOpen(phase, band, dir));
        const row0 = band * 8;
        const nrows = @min(open, h - row0);
        var r: i32 = 0;
        while (r < nrows) : (r += 1) {
            const row: usize = @intCast(row0 + r);
            const src_off = row * @as(usize, @intCast(ctx.src_w));
            const dst_off = row * ctx.target.width;
            @memcpy(
                ctx.target.pixels[dst_off .. dst_off + @as(usize, @intCast(w))],
                ctx.src_px[src_off .. src_off + @as(usize, @intCast(w))],
            );
        }
    }
    return 0;
}

/// Shift-table accessor: canonical object carries count u16@+18 and the
/// entry array @+20 — in our model that's a byte-array Instance (length
/// in fields[0], payload in .bytes). The FX kernels read entries
/// BYTE-wise as signed offsets (⚠ an unrelated animation consumer reads
/// the same region dword-wise; byte-wise matches the kernel's `char*`).
fn shiftTable(vm: *Vm, handle_v: Handle) ?[]const u8 {
    const inst = vm.heap.get(handle_v) orelse return null;
    const bytes = inst.bytes orelse return null;
    if (bytes.len == 0) return null;
    return bytes;
}

// ── [105] doShiftHorizontal(image, graphics, x, y, table) — sub_424C84 →
// kernel sub_41688D: per-ROW horizontal displacement. Row i is blitted
// at x + table[i] (signed byte), clipped both sides; y offsets the
// source row window. Wavy/earthquake distortion.
fn doShiftHorizontal(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = fxResolve(vm, args, "doShiftHorizontal") orelse return 0;
    const x = args.getI32(2);
    const y = args.getI32(3);
    const table = shiftTable(vm, args.handle(4)) orelse {
        vm.signalFault(0xc23defde, "FX.doShiftHorizontal: shift table might be null");
        return 0;
    };
    const tw: i32 = @intCast(ctx.target.width);
    const th: i32 = @intCast(ctx.target.height);
    const h = @min(ctx.src_h - @max(y, 0), th);
    if (h <= 0) return 0;

    var row: i32 = 0;
    while (row < h) : (row += 1) {
        const disp_b: i8 = @bitCast(table[@as(usize, @intCast(row)) % table.len]);
        const disp = x + @as(i32, disp_b);
        const src_row = row + @max(y, 0);
        if (src_row >= ctx.src_h) break;
        const src_off = @as(usize, @intCast(src_row)) * @as(usize, @intCast(ctx.src_w));
        const dst_off = @as(usize, @intCast(row)) * ctx.target.width;
        const src_x0 = @max(-disp, 0);
        const dst_x0 = @max(disp, 0);
        const n = @min(ctx.src_w - src_x0, tw - dst_x0);
        if (n <= 0) continue;
        @memcpy(
            ctx.target.pixels[dst_off + @as(usize, @intCast(dst_x0)) ..][0..@as(usize, @intCast(n))],
            ctx.src_px[src_off + @as(usize, @intCast(src_x0)) ..][0..@as(usize, @intCast(n))],
        );
    }
    return 0;
}

// ── [106] doShiftVertical(image, graphics, x, y, table) — sub_424D62 →
// kernel sub_416B75: per-COLUMN vertical displacement. Column i is
// blitted at y + table[i] (signed byte), clipped; x offsets the source
// column window.
fn doShiftVertical(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = fxResolve(vm, args, "doShiftVertical") orelse return 0;
    const x = args.getI32(2);
    const y = args.getI32(3);
    const table = shiftTable(vm, args.handle(4)) orelse {
        vm.signalFault(0xc23defde, "FX.doShiftVertical: shift table might be null");
        return 0;
    };
    const tw: i32 = @intCast(ctx.target.width);
    const th: i32 = @intCast(ctx.target.height);
    const w = @min(ctx.src_w - @max(x, 0), tw);
    if (w <= 0) return 0;

    var col: i32 = 0;
    while (col < w) : (col += 1) {
        const disp_b: i8 = @bitCast(table[@as(usize, @intCast(col)) % table.len]);
        const disp = y + @as(i32, disp_b);
        const src_col = col + @max(x, 0);
        if (src_col >= ctx.src_w) break;
        const src_y0 = @max(-disp, 0);
        const dst_y0 = @max(disp, 0);
        const n = @min(ctx.src_h - src_y0, th - dst_y0);
        if (n <= 0) continue;
        var k: i32 = 0;
        while (k < n) : (k += 1) {
            const sy: usize = @intCast(src_y0 + k);
            const dy: usize = @intCast(dst_y0 + k);
            ctx.target.pixels[dy * ctx.target.width + @as(usize, @intCast(col))] =
                ctx.src_px[sy * @as(usize, @intCast(ctx.src_w)) + @as(usize, @intCast(src_col))];
        }
    }
    return 0;
}

pub const entries = .{
    .{ 103, "doRotozoomImage",     doRotozoomImage },
    .{ 104, "doMosaic",            doMosaic },
    .{ 105, "doShiftHorizontal",   doShiftHorizontal },
    .{ 106, "doShiftVertical",     doShiftVertical },
    .{ 107, "doVerticalShutter",   doVerticalShutter },
    .{ 108, "doHorizontalShutter", doHorizontalShutter },
};

pub const handle = bridge.canonical(entries);
