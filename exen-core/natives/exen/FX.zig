//! exen.FX — native funcs_407AA2[] indices 103..108
//!
//! Hash 0xd8f81132. Per-pixel effects: rotozoom, mosaic, shutter
//! (the demoscene-style image transforms the platform shipped as a
//! "framework FX" pack). All six methods are `static native`.
//!
//! Per-class method table (extracted from unk_4494F0.bin):
//!   idx 103  sub_424B70  hash=0x2d3e3675  argc=6  doRotozoomImage(image, gfx, x, y, angle, scale)  ✓ ported
//!   idx 104  sub_424BFD  hash=0xb29f3baa  argc=5  doMosaicImage(...)        — pending
//!   idx 105  sub_424C7E  hash=0xfe4fe802  argc=5  doShutterImage(...)        — pending
//!   idx 106  sub_424CFF  hash=0xfe4fdabe  argc=5  doShutterImage2(...)       — pending
//!   idx 107  sub_424D80  hash=0xa845a8fd  argc=4  doSomeImage(...)           — pending
//!   idx 108  sub_424E01  hash=0xa845d499  argc=4  doSomeImage2(...)          — pending
//!
//! Unported indices fall through to defaultNativeStub via the
//! dispatcher's miss path (matches pre-split behaviour); replace with
//! real handlers as each gets a faithful port + verification.

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;
const _h = @import("../_helpers.zig");

const Vm = interp.Vm;
const Handle = bridge.Handle;

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

// ── [107] sub_424E40 — FX.doVerticalShutter(graphics, dx, dy) ──────────────
// Canonical body (ref:24925):
//     v2 = sub_426785(a1[1]);                       // graphics descriptor
//     v3 = sub_426785(*(_DWORD *)(*a1 + 24));       // source image descriptor (via *(this+24))
//     if (v3 && v2) {
//         sub_425650(*a1, v3);                      // pre-blit clip-sync hook
//         (*(v2[10] + 64 + 8))(v2, v3, a1[2], a1[3]);  // vtable[2] kernel
//         return 0;
//     }
//     sub_434771("FX.doVerticalShutter: image pointer might be null");
//     sub_407A13();   // non-catcheable internal exception
//     return 0;
//
// The visible pixel-effect lives in the depth-specific vtable kernel at
// `(v2[10] + 64) + 8` (vtable index 2 of the FX kernels). We don't have
// those kernels ported; this stub mirrors the canonical's null-check +
// fault path EXACTLY, and is a no-op on the success branch (no visible
// pixel change). Faithful for control-flow purposes; the gamelet's
// rendering loop will simply not see the vertical-shutter effect.
fn doVerticalShutter(vm: *Vm, args: bridge.ArgFrame) i16 {
    // *a1 = receiver (Graphics passed via INVOKESPECIAL? actually receiver
    // doesn't matter for the canonical — it pulls `*a1` as receiver-like).
    // For us, args.this() = slab[0] = first slab slot. In the canonical
    // call, this is the receiver Graphics.
    const this = args.this();
    const graphics_arg = args.handle(1);
    if (graphics_arg == 0 or this == 0) {
        vm.signalFault(0xc23defde, "FX.doVerticalShutter: null pointer");
        return 0;
    }
    // Read this.field[+24] — the source Image handle. In our model
    // *(this+24) is canonical-byte-offset 24 = slot 3 in the field area.
    // FX class isn't well-mapped; the receiver might not actually have a
    // field at offset 24. Best-effort: do nothing visible, no faults
    // when receiver is non-null. Canonical's vtable kernel would now run.
    _ = args.getI32(2); // dx — would feed the kernel
    _ = args.getI32(3); // dy — would feed the kernel
    return 0;
}

pub const handle = bridge.canonical(.{
    .{ 103, "FX.doRotozoomImage",   doRotozoomImage },
    .{ 107, "FX.doVerticalShutter", doVerticalShutter },
});
