//! exen.Displayable — native funcs_407AA2[] indices 65..66
//!
//! Hash 0x02255f70. Parent of Gamelet; UI command handling.
//!
//! Index map verified by reading sub_* bodies in reference/ref:
//!   65 → sub_424A60  haveDisplayableCommand()    ✓ verified
//!   66 → sub_424A9D  (Graphics, char[], int)     ✓ canonical body
//!                    ported as `unnamed_sub_424A9D` — strings-region
//!                    `drawCommand` row is argc=1 (mismatch), so the
//!                    pretty name stays unbound until the (class,
//!                    method-hash) → name link is recovered.

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;
const _h = @import("../_helpers.zig");

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 65;
pub const last_index: u32 = 66;

const FIELD_PEN_COLOR: u32 = 0x3dd3c2e7;

// ── [65] Displayable.haveDisplayableCommand() → bool — sub_424A60 ──────────
// Canonical body (reference/ref:24764):
//     if (sub_403F56(0) || sub_403F56(1)) *a1 = 1; else *a1 = 0;
//     return 1;
//
// sub_403F56(a1): if (a1) return a1 == 1; else return 2;
//   → sub_403F56(0) = 2 (truthy), sub_403F56(1) = 1 (truthy).
//   OR short-circuits to true → *a1 = 1 always.
//
// So this always returns 1 on this device — the platform unconditionally
// supports displayable command bars (keypad + LCD phones in the the platform
// target hardware all have command-bar support).
//
// Strings region row 25: `haveDisplayableCommand: () → bool` matches by
// arg type (argc=0) AND return type (bool, since *a1 is always 0/1).
// Only argc=0 → bool candidate in the strings region.
fn haveDisplayableCommand(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(1);
    return 1;
}

// ── [66] unnamed_sub_424A9D(Graphics, char[], int_mode) — sub_424A9D ───────
// Canonical body (reference/ref:24779):
//     v5 = sub_426785(graphics.field[+24])     // device gfx descriptor
//     v7 = (uint16_t*)chars.field[+24]         // length-prefixed char buf
//     save v5[6..9]                            // current clip x/y/w/h
//     v5[6]=0; v5[7]=0; v5[8]=v5[1]; v5[9]=v5[2]   // clip → full screen
//     sub_4238F0(v7+1, *v7, v5, mode)          // text blit
//     restore v5[6..9]                         // restore clip
//     return 0
//
// sub_4238F0 (text helper) maps `mode` via sub_403F56(mode):
//     input 0 → CENTER (case 2 → x via slot 32)
//     input 1 → LEFT   (case 1 → x = 1)
//     input 2+ → DON'T_DRAW (case 0 → return 0)
// Y is positioned at bottom of clip: `clip_h - font_descender_height`.
//
// We mirror the alignment-based positioning. The save/restore is a no-op
// in our model (drawString doesn't enforce clip rects yet — tracked in
// task #140). For LEFT/CENTER we render via `core.text.drawString` into
// the Graphics target. For DON'T_DRAW we return without rendering.
fn unnamed_sub_424A9D(vm: *Vm, args: bridge.ArgFrame) i16 {
    // args.this() is the Displayable receiver (unused)
    const graphics = args.handle(1);
    const chars = args.handle(2);
    const mode = args.getU32(3);
    const target_dt = _h.graphicsTarget(vm, graphics) orelse return 0;
    const chars_inst = vm.heap.get(chars) orelse return 0;
    const text = chars_inst.bytes orelse return 0;
    if (text.len == 0) return 0;

    // Canonical sub_403F56 remap of `mode`:
    //   0 → 2 (CENTER), 1 → 1 (LEFT), 2 → 0 (DON'T_DRAW),
    //   n → 0 (DON'T_DRAW) for n >= 2.
    const draw_mode: u32 = if (mode == 0) 2 else if (mode == 1) 1 else 0;
    if (draw_mode == 0) return 0;

    // Pen colour: same FIELD_PEN_COLOR slot as drawChars (idx 5).
    const color_rgb = _h.instField(vm, graphics, FIELD_PEN_COLOR);
    const color: u32 = if ((color_rgb & 0x01000000) != 0)
        0xFF000000 | (color_rgb & 0x00FFFFFF)
    else
        0xFFFFFFFF;

    // Measure text width (glyph + 1px inter-glyph spacing per char,
    // matching core.text.drawString's advance — see core/text.zig:92).
    // Last glyph contributes only GLYPH_WIDTH, no trailing space.
    const glyph_w: i32 = 5; // core.text GLYPH_WIDTH
    const text_w: i32 = if (text.len == 0)
        0
    else
        @as(i32, @intCast(text.len)) * (glyph_w + 1) - 1;

    const tw: i32 = @intCast(target_dt.width);
    const th: i32 = @intCast(target_dt.height);
    const line_h = core.text.lineHeight();
    const y_top: i32 = th - line_h;

    const x: i32 = switch (draw_mode) {
        1 => 1, // LEFT
        2 => @divTrunc(tw - text_w, 2), // CENTER
        else => 0,
    };

    const target: core.text.Target = .{
        .pixels = target_dt.pixels,
        .width = target_dt.width,
        .height = target_dt.height,
    };
    _ = core.text.drawString(target, x, y_top, text, color);
    return 0;
}

pub const handle = bridge.canonical(.{
    .{ 65, "Displayable.haveDisplayableCommand", haveDisplayableCommand },
    .{ 66, "Displayable.drawCommand",            unnamed_sub_424A9D },
});
