//! exen.Graphics — native funcs_407AA2[] indices 0..14
//!
//! Hash 0xc6ed8e2a. 2D drawing primitives + image blitting.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 0;
pub const last_index: u32 = 14;

/// Field hash where Graphics.setColor stores the pen colour. The high
/// byte is a "set" marker (0x01) so we can distinguish explicit black
/// from "unset" (`field_map.get(...) == 0`). Reads strip the marker
/// before composing the final ABGR pixel.
// Canonical Graphics field hashes (extracted/exen_Graphics.md field_table).
// Previously we used synthetic hashes here (0x3dd3c2e7 / 0xC1C15078..B)
// which worked for gamelets that only touched color/clip through the
// setColor/setClip natives. Tomb Raider PUTFIELDs the canonical
// hashes directly from bytecode (e.g. inline clip-rect manipulation),
// so the two paths must share the same field_map slot — switching to
// canonical hashes unifies them.
const FIELD_PEN_COLOR: u32 = 0xd042cece;  // slot 1, int
const FIELD_PAINT_MODE: u32 = 0x6f998aea; // slot 2, short — see sub_41420D:15524
const FIELD_CLIP_X_CANON_CANON: u32 = 0xd042357d; // slot 3, int
const FIELD_CLIP_Y_CANON_CANON: u32 = 0xd04224f4; // slot 4, int
const FIELD_CLIP_W_CANON_CANON: u32 = 0xd0427a64; // slot 5, int
const FIELD_CLIP_H_CANON_CANON: u32 = 0xd042f98c; // slot 6, int

const FIELD_CLIP_X_CANON: u32 = 0xC1C1_5078;
const FIELD_CLIP_Y_CANON: u32 = 0xC1C1_5079;
const FIELD_CLIP_W_CANON: u32 = 0xC1C1_507A;
const FIELD_CLIP_H_CANON: u32 = 0xC1C1_507B;

/// Resolve the current pen colour for a Graphics handle. Defaults to
/// opaque black when the field hasn't been set yet.
fn penColor(vm: *Vm, this: Handle) u32 {
    const rgb = _h.instField(vm, this, FIELD_PEN_COLOR);
    return if ((rgb & 0x01000000) != 0)
        0xFF000000 | (rgb & 0x00FFFFFF)
    else
        0xFF000000;
}

// ── [0] clearRect(this, x, y, w, h) — sub_425C73 ───────────────────────────
// Canonical calls `sub_417D92(buf, x, y, w, h, 255, 1)` — palette[255] fill.
fn clearRect(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const w = args.getI32(3);
    const h = args.getI32(4);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    _h.fillRectIntoTarget(t, x, y, w, h, paletteColor255(vm, this));
    return 0;
}

fn paletteColor255(vm: *Vm, gfx_this: Handle) u32 {
    const target_img = _h.instField(vm, gfx_this, _h.FIELD_GFX_TARGET);
    if (target_img != 0) {
        if (Vm.palette_state.getPtr(target_img)) |ps| {
            if (ps.cursor > 255) return paletteDecode(ps.bytes[255]);
        }
    }
    return 0xFFFFFFFF;
}

fn paletteDecode(c: u8) u32 {
    const r3: u32 = (c >> 5) & 0x07;
    const g3: u32 = (c >> 2) & 0x07;
    const b2: u32 = c & 0x03;
    const r: u32 = (r3 * 255) / 7;
    const g: u32 = (g3 * 255) / 7;
    const b: u32 = (b2 * 255) / 3;
    return 0xFF000000 | (b << 16) | (g << 8) | r;
}

// ── [1] drawImage(this, image, dx, dy, dw, dh, anchor, sx, sy, sw, sh, mode) ─
// sub_425699 → sub_418008 → vtable[52]/[56]. argc=11.
fn drawImage(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const image = args.handle(1);
    const dx = args.getI32(2);
    const dy = args.getI32(3);
    const dw_in = args.getI32(4);
    const dh_in = args.getI32(5);
    // args[6] = anchor — canonical no-op
    const sx_in = args.getI32(7);
    const sy_in = args.getI32(8);
    const sw_in = args.getI32(9);
    const sh_in = args.getI32(10);
    const mode = args.getU32(11);

    var sx = sx_in;
    var sy = sy_in;
    var sw = sw_in;
    var sh = sh_in;
    var dw = dw_in;
    var dh = dh_in;

    const target = _h.graphicsTarget(vm, this) orelse return 0;
    const inst = vm.heap.get(image) orelse return 0;



    // Lazy palette decode (canonical sub_426785 + transformToSystemPalette).
    if (inst.pixels == null) _h.doTransformToSystemPalette(vm, image);
    const src_px = inst.pixels orelse return 0;

    // Canonical transparency: the source image's palette index that
    // should render as transparent is stored on the Image's tr_mode +
    // tr_color/pal_alpha fields, set by one of:
    //   * setTransparentColor(idx)  → tr_mode=48, tr_color=idx       (canonical sub_426419)
    //   * setPaletteAlpha(idx)      → tr_mode=32 or 80, pal_alpha=idx (canonical sub_4264A3 → sub_418EC3)
    // Both paths funnel into the same "skip pixels equal to palette[N]'s
    // decoded ABGR" rule. Pikubi2 uses the setPaletteAlpha path (mode 32);
    // earlier code only honoured mode 48 → text rendered as solid rectangles.
    //
    // Canonical also gates this on Graphics.paint_mode == 1 — see
    // sub_41420D:15524. Every gamelet in our corpus sets paint_mode=1, so
    // we'd be over-broad to drop the gate; check it explicitly.
    // Resolve the source palette index that should render as transparent.
    // Two canonical paths feed this:
    //   * setTransparentColor(idx) → tr_mode=48, FIELD_IMG_TR_COLOR
    //   * setPaletteAlpha(idx)     → tr_mode=32/80, FIELD_IMG_PAL_ALPHA
    // Gated on Graphics.paint_mode == 1 (canonical sub_41420D:15524).
    // We match by SOURCE PALETTE INDEX (via inst.pixel_indices) rather
    // than decoded ABGR equality — multiple palette entries can decode
    // to the same colour, so a colour check would skip too many pixels
    // (Pikubi2's 88-byte palette has many 0x00 entries → all black).
    const tr_skip_idx: ?u8 = blk: {
        const paint_mode = if (vm.heap.get(this)) |g|
            (g.field_map.get(FIELD_PAINT_MODE) orelse 0)
        else
            @as(u32, 0);
        if (paint_mode != 1) break :blk null;

        const tr_mode = inst.field_map.get(0xC0FFEE03) orelse 0;
        const tr_idx_raw: u32 = switch (tr_mode) {
            48 => inst.field_map.get(0xC0FFEE01) orelse 0,         // setTransparentColor path
            32, 80 => inst.field_map.get(0xC0FFEE02) orelse 0,     // setPaletteAlpha path
            else => break :blk null,
        };
        break :blk @truncate(tr_idx_raw);
    };
    const src_idx_buf: ?[]const u8 = inst.pixel_indices;

    const iw: i32 = @intCast(inst.pix_w);
    const ih: i32 = @intCast(inst.pix_h);
    if (sw <= 0) sw = iw;
    if (sh <= 0) sh = ih;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx + sw > iw) sw = iw - sx;
    if (sy + sh > ih) sh = ih - sy;
    if (sw <= 0 or sh <= 0) return 0;
    if (dw <= 0) dw = sw;
    if (dh <= 0) dh = sh;

    const tw: i32 = @intCast(target.width);
    const th: i32 = @intCast(target.height);

    // Honor Graphics.clip — canonical sub_418008 reads the clip rect
    // propagated from Graphics via sub_425650.
    var clip_x0: i32 = 0;
    var clip_y0: i32 = 0;
    var clip_x1: i32 = tw;
    var clip_y1: i32 = th;
    if (vm.heap.get(this)) |g| {
        const gcw_u: u32 = g.field_map.get(FIELD_CLIP_W_CANON) orelse 0;
        const gch_u: u32 = g.field_map.get(FIELD_CLIP_H_CANON) orelse 0;
        if (gcw_u != 0 and gch_u != 0) {
            const gcx: i32 = @bitCast(g.field_map.get(FIELD_CLIP_X_CANON) orelse 0);
            const gcy: i32 = @bitCast(g.field_map.get(FIELD_CLIP_Y_CANON) orelse 0);
            clip_x0 = @max(0, gcx);
            clip_y0 = @max(0, gcy);
            clip_x1 = @min(tw, gcx + @as(i32, @intCast(gcw_u)));
            clip_y1 = @min(th, gcy + @as(i32, @intCast(gch_u)));
            if (clip_x1 <= clip_x0 or clip_y1 <= clip_y0) return 0;
        }
    }

    var painted: u32 = 0;
    if (sw == dw and sh == dh) {
        // Unscaled — vtable[52], mode-aware
        const flip_x = (mode == 2 or mode == 1 or mode == 4 or mode == 7);
        const flip_y = (mode == 1 or mode == 3 or mode == 4 or mode == 7);
        const swap_xy = (mode >= 4);
        const out_w: i32 = if (swap_xy) sh else sw;
        const out_h: i32 = if (swap_xy) sw else sh;
        var j: i32 = 0;
        while (j < out_h) : (j += 1) {
            const py = dy + j;
            if (py < clip_y0 or py >= clip_y1) continue;
            var i: i32 = 0;
            while (i < out_w) : (i += 1) {
                const px_x = dx + i;
                if (px_x < clip_x0 or px_x >= clip_x1) continue;
                var u: i32 = if (swap_xy) j else i;
                var v: i32 = if (swap_xy) i else j;
                if (flip_x) u = sw - 1 - u;
                if (flip_y) v = sh - 1 - v;
                const src_col: usize = @intCast(sx + u);
                const src_row: usize = @intCast(sy + v);
                const src_idx = src_row * inst.pix_w + src_col;
                if (src_idx >= src_px.len) continue;
                const p = src_px[src_idx];
                if ((p >> 24) == 0) continue;
                // Transparency: only engage if BOTH the gamelet asked
                // for index-based transparency (tr_skip_idx set via
                // setPaletteAlpha / setTransparentColor with paint_mode==1)
                // AND we have source-index info (palette-decode path).
                // PNG-decoded images skip transparent pixels via the
                // alpha-0 check above; this path is for palette-decoded.
                if (tr_skip_idx) |tk| {
                    if (src_idx_buf) |idxbuf| {
                        if (src_idx < idxbuf.len and idxbuf[src_idx] == tk) continue;
                    }
                }
                const dst_idx = @as(usize, @intCast(py)) * target.width + @as(usize, @intCast(px_x));
                target.pixels[dst_idx] = p;
                painted += 1;
            }
        }
    } else {
        // Scaled — vtable[56], mode IGNORED
        var j: i32 = 0;
        while (j < dh) : (j += 1) {
            const py = dy + j;
            if (py < clip_y0 or py >= clip_y1) continue;
            const v_idx: i32 = @divFloor(j * sh, dh);
            const src_row: usize = @intCast(sy + v_idx);
            var i: i32 = 0;
            while (i < dw) : (i += 1) {
                const px_x = dx + i;
                if (px_x < clip_x0 or px_x >= clip_x1) continue;
                const u_idx: i32 = @divFloor(i * sw, dw);
                const src_col: usize = @intCast(sx + u_idx);
                const src_idx = src_row * inst.pix_w + src_col;
                if (src_idx >= src_px.len) continue;
                const p = src_px[src_idx];
                if ((p >> 24) == 0) continue;
                // Transparency: only engage if BOTH the gamelet asked
                // for index-based transparency (tr_skip_idx set via
                // setPaletteAlpha / setTransparentColor with paint_mode==1)
                // AND we have source-index info (palette-decode path).
                // PNG-decoded images skip transparent pixels via the
                // alpha-0 check above; this path is for palette-decoded.
                if (tr_skip_idx) |tk| {
                    if (src_idx_buf) |idxbuf| {
                        if (src_idx < idxbuf.len and idxbuf[src_idx] == tk) continue;
                    }
                }
                const dst_idx = @as(usize, @intCast(py)) * target.width + @as(usize, @intCast(px_x));
                target.pixels[dst_idx] = p;
                painted += 1;
            }
        }
    }
    // SPAWN-DEBUG: flag draws that land off-screen (likely an enemy stuck
    // at an off-track position) — INFO so it's grep-able. dx>=target.width
    // or fully clipped → painted 0 despite a non-empty source.
    if (painted == 0 and inst.pix_w > 0 and inst.pix_h > 0) {
        std.log.scoped(.drawdbg).info("OFFSCREEN img=0x{x:0>8} dst=({d},{d}) dsz=({d}x{d}) src=({d},{d},{d}x{d})", .{
            image, dx, dy, dw, dh, sx, sy, sw, sh,
        });
    }
    return 0;
}

// ── [2] drawLine(this, x0, y0, x1, y1) — sub_4257A1 ───────────────────────
fn drawLine(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x0 = args.getI32(1);
    const y0 = args.getI32(2);
    const x1 = args.getI32(3);
    const y1 = args.getI32(4);
    const color = penColor(vm, this);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    _h.drawLineInTarget(t, x0, y0, x1, y1, color);
    return 0;
}

// ── [4] drawRect(this, x, y, w, h) — outline only — sub_425940 ────────────
fn drawRect(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const w = args.getI32(3);
    const h = args.getI32(4);
    const color = penColor(vm, this);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    _h.drawLineInTarget(t, x,     y,     x + w, y,     color); // TL → TR
    _h.drawLineInTarget(t, x + w, y,     x + w, y + h, color); // TR → BR
    _h.drawLineInTarget(t, x + w, y + h, x,     y + h, color); // BR → BL
    _h.drawLineInTarget(t, x,     y + h, x,     y,     color); // BL → TL
    return 0;
}

// ── [5] drawChars(this, byte[] chars, offset, length, x, y) — sub_425A50 ──
fn drawChars(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const chars_handle = args.handle(1);
    const offset = args.getU32(2);
    const length = args.getU32(3);
    const x = args.getI32(4);
    const y = args.getI32(5);

    const color_rgb = _h.instField(vm, this, FIELD_PEN_COLOR);
    const color: u32 = if ((color_rgb & 0x01000000) != 0)
        0xFF000000 | (color_rgb & 0x00FFFFFF)
    else
        0xFFFFFFFF;
    const target_dt = _h.graphicsTarget(vm, this) orelse return 0;
    const chars_inst = vm.heap.get(chars_handle) orelse return 0;
    const chars_bytes = chars_inst.bytes orelse return 0;
    if (offset >= chars_bytes.len) return 0;
    const end = @min(offset + length, @as(u32, @intCast(chars_bytes.len)));
    const slice = chars_bytes[offset..end];
    const target: core.text.Target = .{
        .pixels = target_dt.pixels,
        .width = target_dt.width,
        .height = target_dt.height,
    };
    _ = core.text.drawString(target, x, y + core.text.ascent(), slice, color);
    return 0;
}

// ── [7] fillRect(this, x, y, w, h) — sub_425D20 ──────────────────────────
fn fillRect(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const w = args.getI32(3);
    const h = args.getI32(4);
    const color = penColor(vm, this);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    var rx = x;
    var ry = y;
    var rw = w;
    var rh = h;
    if (vm.heap.get(this)) |g| {
        const gcw_u: u32 = g.field_map.get(FIELD_CLIP_W_CANON) orelse 0;
        const gch_u: u32 = g.field_map.get(FIELD_CLIP_H_CANON) orelse 0;
        if (gcw_u != 0 and gch_u != 0) {
            const gcx: i32 = @bitCast(g.field_map.get(FIELD_CLIP_X_CANON) orelse 0);
            const gcy: i32 = @bitCast(g.field_map.get(FIELD_CLIP_Y_CANON) orelse 0);
            const gcx1 = gcx + @as(i32, @intCast(gcw_u));
            const gcy1 = gcy + @as(i32, @intCast(gch_u));
            const ux1 = x +% w;
            const uy1 = y +% h;
            const ix0 = @max(x, gcx);
            const iy0 = @max(y, gcy);
            const ix1 = @min(ux1, gcx1);
            const iy1 = @min(uy1, gcy1);
            rx = ix0;
            ry = iy0;
            rw = if (ix1 > ix0) ix1 - ix0 else 0;
            rh = if (iy1 > iy0) iy1 - iy0 else 0;
            if (rw == 0 or rh == 0) return 0;
        }
    }
    _h.fillRectIntoTarget(t, rx, ry, rw, rh, color);
    return 0;
}

// ── [3] drawTriangle(this, x1, y1, x2, y2, x3, y3) — sub_42585A ──────────
fn drawTriangle(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x1 = args.getI32(1);
    const y1 = args.getI32(2);
    const x2 = args.getI32(3);
    const y2 = args.getI32(4);
    const x3 = args.getI32(5);
    const y3 = args.getI32(6);
    const color = penColor(vm, this);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    _h.drawLineInTarget(t, x1, y1, x2, y2, color);
    _h.drawLineInTarget(t, x2, y2, x3, y3, color);
    _h.drawLineInTarget(t, x3, y3, x1, y1, color);
    return 0;
}

// ── [6] fillTriangle — sub_425BA4 — STUB ────────────────────────────────
fn fillTriangle(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [8] fillTextureTriangle — sub_425DD8 — STUB ─────────────────────────
fn fillTextureTriangle(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [9] setPixel(this, x, y, color) — sub_425F6E ────────────────────────
fn setPixel(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const color_byte = args.getU32(3);
    const t = _h.graphicsTarget(vm, this) orelse return 0;
    const color: u32 = 0xFF000000 | (color_byte & 0x00FFFFFF);
    _h.setPixelInTarget(t, x, y, color);
    return 0;
}

// ── [10] getPixel(this, x, y) → int — sub_426015 ────────────────────────
fn getPixel(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    args.setReturn(0);
    const t = _h.graphicsTarget(vm, this) orelse return 1;
    if (x < 0 or y < 0) return 1;
    const tw: i32 = @intCast(t.width);
    const th: i32 = @intCast(t.height);
    if (x >= tw or y >= th) return 1;
    args.setReturn(t.pixels[@as(usize, @intCast(y)) * t.width + @as(usize, @intCast(x))]);
    return 1;
}

// ── [11] setClip(this, x, y, w, h) — sub_426096 ─────────────────────────
fn setClip(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const w = args.getI32(3);
    const h = args.getI32(4);
    const inst = vm.heap.get(this) orelse return 0;
    const target = _h.graphicsTarget(vm, this) orelse {
        const sw_raw: u32 = if (w < 0) 0 else @intCast(w);
        const sh_raw: u32 = if (h < 0) 0 else @intCast(h);
        inst.field_map.put(FIELD_CLIP_X_CANON, @bitCast(x)) catch {};
        inst.field_map.put(FIELD_CLIP_Y_CANON, @bitCast(y)) catch {};
        inst.field_map.put(FIELD_CLIP_W_CANON, sw_raw) catch {};
        inst.field_map.put(FIELD_CLIP_H_CANON, sh_raw) catch {};
        return 0;
    };
    const tw: i32 = @intCast(target.width);
    const th: i32 = @intCast(target.height);
    const ux1 = x +% w;
    const uy1 = y +% h;
    const ix0: i32 = @max(@as(i32, 0), x);
    const iy0: i32 = @max(@as(i32, 0), y);
    const ix1: i32 = @min(tw, ux1);
    const iy1: i32 = @min(th, uy1);
    const iw: i32 = if (ix1 > ix0) ix1 - ix0 else 0;
    const ih: i32 = if (iy1 > iy0) iy1 - iy0 else 0;
    inst.field_map.put(FIELD_CLIP_X_CANON, @bitCast(ix0)) catch {};
    inst.field_map.put(FIELD_CLIP_Y_CANON, @bitCast(iy0)) catch {};
    inst.field_map.put(FIELD_CLIP_W_CANON, @bitCast(iw)) catch {};
    inst.field_map.put(FIELD_CLIP_H_CANON, @bitCast(ih)) catch {};
    return 0;
}

// ── [12] setInverseVideo — sub_426172 — no-op ───────────────────────────
fn setInverseVideo(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [13] setNormalVideo — sub_426184 — no-op ────────────────────────────
fn setNormalVideo(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [14] setColor(this, r, g, b) — sub_426196 ───────────────────────────
fn setColor(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const r = args.getU32(1);
    const g = args.getU32(2);
    const b = args.getU32(3);
    const rgb24: u32 = ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
    const inst = vm.heap.get(this) orelse return 0;
    inst.field_map.put(FIELD_PEN_COLOR, rgb24 | 0x01000000) catch {};
    return 0;
}

pub const handle = bridge.canonical(.{
    .{ 0,  "clearRect",            clearRect },
    .{ 1,  "drawImage",            drawImage },
    .{ 2,  "drawLine",             drawLine },
    .{ 3,  "drawTriangle",         drawTriangle },
    .{ 4,  "drawRect",             drawRect },
    .{ 5,  "drawChars",            drawChars },
    .{ 6,  "fillTriangle",         fillTriangle },
    .{ 7,  "fillRect",             fillRect },
    .{ 8,  "fillTextureTriangle",  fillTextureTriangle },
    .{ 9,  "setPixel",             setPixel },
    .{ 10, "getPixel",             getPixel },
    .{ 11, "setClip",              setClip },
    .{ 12, "setInverseVideo",      setInverseVideo },
    .{ 13, "setNormalVideo",       setNormalVideo },
    .{ 14, "setColor",             setColor },
});
