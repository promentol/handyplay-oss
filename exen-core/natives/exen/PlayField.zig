//! exen.PlayField — native funcs_407AA2[] indices 46..53
//!
//! Hash 0x7219d0b4. Tiled scrolling playfield.
//!
//! Field hashes (from docs/extracted/exen_PlayField.md + name CRCs in
//! core/debug/names.zig):
//!   background  (byte[])  0xa6f13e72   ← tile buffer payload
//!   backgroundW (int)     0xd0427691   ← grid width in cells (row stride)
//!   backgroundH (int)     0xd0429ee7   ← grid height in cells
//!   nbBits      (int)     0xd0426172   ← cell bit-depth (8 or 16)
//!
//! Canonical (a2 = PlayField `_DWORD *`) maps these to:
//!   a2[12] = tile_buffer handle
//!   a2[13] = width
//!   a2[14] = height
//!   a2[15] = nbBits
//!   a2[ 9] = sign-wrap threshold (never written by PlayField init,
//!            so always 0 → unsigned tile reads — we drop it here).

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const first_index: u32 = 46;
pub const last_index: u32 = 53;

const FIELD_STATE:        u32 = 0xd042ec80;
const FIELD_CHARSET:      u32 = 0x3dd35280;
const FIELD_CHAR_W:       u32 = 0xd0424a14;
const FIELD_CHAR_H:       u32 = 0xd042a262;
const FIELD_BACKGROUND:   u32 = 0xa6f13e72;
const FIELD_BACKGROUND_W: u32 = 0xd0427691;
const FIELD_BACKGROUND_H: u32 = 0xd0429ee7;
const FIELD_NB_BITS:      u32 = 0xd0426172;
const FIELD_VIEW_X:       u32 = 0xd0422195;
const FIELD_VIEW_Y:       u32 = 0xd042301c;
const FIELD_VIEW_W:       u32 = 0xd042d962;
const FIELD_VIEW_H:       u32 = 0xd0423114;

// ── Helpers ────────────────────────────────────────────────────────────────

/// Port of sub_426E30 (ref:26369): write one tile into the grid
/// at (x, y). For nbBits == 8 this is a single byte; otherwise a u16
/// little-endian word. Negative tiles get pre-wrapped via `+ (1<<nbBits)`
/// so the cell stores the unsigned image of the value.
fn writeCell(vm: *Vm, this: Handle, x: i32, y: i32, tile_in: i32) void {
    const inst = vm.heap.get(this) orelse return;
    const buf_h = inst.field_map.get(FIELD_BACKGROUND) orelse 0;
    if (buf_h == 0) return;
    const buf_inst = vm.heap.get(buf_h) orelse return;
    const bytes = buf_inst.bytes orelse return;

    const w: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_W) orelse 0);
    const nb_bits = inst.field_map.get(FIELD_NB_BITS) orelse 8;

    var tile = tile_in;
    if (tile < 0) tile +%= @as(i32, 1) << @intCast(nb_bits & 0x1f);

    const idx_signed: i32 = w * y + x;
    if (idx_signed < 0) return;
    const idx: usize = @intCast(idx_signed);

    if (nb_bits == 8) {
        if (idx >= bytes.len) return;
        bytes[idx] = @truncate(@as(u32, @bitCast(tile)));
    } else {
        const off = idx * 2;
        if (off + 2 > bytes.len) return;
        const v: u16 = @truncate(@as(u32, @bitCast(tile)));
        std.mem.writeInt(u16, bytes[off..][0..2], v, .little);
    }
}

/// Port of sub_426E9B (ref:26393): read one tile from the grid
/// at (x, y). Sign-wrap (`a1[9]`) is always 0 for PlayField (never written
/// by canonical init), so this is a plain unsigned read.
fn readCell(vm: *Vm, this: Handle, x: i32, y: i32) i32 {
    const inst = vm.heap.get(this) orelse return 0;
    const buf_h = inst.field_map.get(FIELD_BACKGROUND) orelse 0;
    if (buf_h == 0) return 0;
    const buf_inst = vm.heap.get(buf_h) orelse return 0;
    const bytes = buf_inst.bytes orelse return 0;

    const w: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_W) orelse 0);
    const nb_bits = inst.field_map.get(FIELD_NB_BITS) orelse 8;

    const idx_signed: i32 = w * y + x;
    if (idx_signed < 0) return 0;
    const idx: usize = @intCast(idx_signed);

    if (nb_bits == 8) {
        if (idx >= bytes.len) return 0;
        return @intCast(bytes[idx]);
    } else {
        const off = idx * 2;
        if (off + 2 > bytes.len) return 0;
        return @intCast(std.mem.readInt(u16, bytes[off..][0..2], .little));
    }
}

/// Common bounds guard used by sub_426F37 / sub_426FA8 / sub_427013.
/// Returns false when the cell op should be a no-op (out of range or
/// no tile buffer attached).
fn cellInBounds(vm: *Vm, this: Handle, x: i32, y: i32) bool {
    const inst = vm.heap.get(this) orelse return false;
    if ((inst.field_map.get(FIELD_BACKGROUND) orelse 0) == 0) return false;
    const w: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_W) orelse 0);
    const h: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_H) orelse 0);
    return x >= 0 and y >= 0 and x < w and y < h;
}

// ── Native bodies ──────────────────────────────────────────────────────────

// ── [46] sub_427013 — fillCells(x, y, w, h, tile) ──────────────────────────
// Canonical body (ref:26441):
//   if (a2[12]) {                          // tile-buffer present
//     v7=x; v6=y; v9=w; v8=h; v11=(i16)tile;
//     if (v7 < 0) { v9 += v7; v7 = 0; }    // clip left edge
//     if (v6 < 0) { v8 += v6; v6 = 0; }    // clip top edge
//     v4 = min(v9, width  - v7);           // clamp width
//     v3 = min(v8, height - v6);           // clamp height
//     for (i=0; i<v3; ++i)
//       for (j=0; j<v4; ++j)
//         sub_426E30(a2, j+v7, i+v6, v11); // writeCell
//   }
//   return 0;
//
// Tile is truncated to i16 in canonical (`v11 = *(_WORD*)(a1+20)`).
// writeCell's nb_bits path picks 8/16-bit storage.
fn fillCells(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x_in = args.getI32(1);
    const y_in = args.getI32(2);
    const w_in = args.getI32(3);
    const h_in = args.getI32(4);
    // Canonical truncates the tile arg to 16 bits via WORD-cast before
    // passing to writeCell; preserve that for nb_bits=16 sign behaviour.
    const tile: i32 = @as(i32, @as(i16, @truncate(args.getI32(5))));

    const inst = vm.heap.get(this) orelse return 0;
    if ((inst.field_map.get(FIELD_BACKGROUND) orelse 0) == 0) return 0;
    const grid_w: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_W) orelse 0);
    const grid_h: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_H) orelse 0);

    var x = x_in;
    var y = y_in;
    var w = w_in;
    var h = h_in;
    if (x < 0) { w +%= x; x = 0; }
    if (y < 0) { h +%= y; y = 0; }
    const eff_w = @min(w, grid_w - x);
    const eff_h = @min(h, grid_h - y);
    var i: i32 = 0;
    while (i < eff_h) : (i += 1) {
        var j: i32 = 0;
        while (j < eff_w) : (j += 1) {
            writeCell(vm, this, j + x, i + y, tile);
        }
    }
    return 0;
}

// [47] sub_42712F — moveTiles(sx, sy, dx, dy, w, h). ⚠ Zig impl pending.
fn unnamed_sub_42712F(vm: *Vm, args: bridge.ArgFrame) i16 {
    _ = vm; _ = args;
    return 0;
}

// ── [48] sub_427531 — draw(graphics, xoff, yoff) ──────────────────────────
// Canonical body (ref:26628). Single-pass composite of the tile
// grid into the Graphics target image:
//
//   v51 = state;  v61 = charW;  v60 = charH;  v58 = backgroundW;
//   v62 = backgroundH;  v35 = charSet;  v52 = sub_426785(charSet);
//   v49 = graphics;  v41 = sub_426785(graphics.target);
//   v46 = viewX - xoff;  v44 = viewY - yoff;
//   <save+clip Graphics to view window>
//   if ( background && charW && charH ) {
//     <split offset into (cell_start, pixel_start) per axis>
//     if ( (state & 6) == 6 && cell_start_x < bgW && cell_start_y < bgH
//          && pix_start_x < target.w && pix_start_y < target.h ) {
//        v33 = charSet.width / charW;          // tiles per row
//        do {
//          do {
//            v28 = sub_426E9B(this, cx, cy);   // signed tile value
//            if (v28 < 0) v28 = animTileIndex[(-v28) % (animMax+1)];
//            if (v28) {
//              --v28;
//              <branch on state bits 8 / 0x10 / 0x20 for transform modes>
//              sub_418008(target, px, py, charW, charH, charSet,
//                         charW*(v28 % v33), charH*(v28 / v33),
//                         charW, charH, mode, 0);
//            }
//            py += charH; ++cy;
//          } while (py < target.h && cy < bgH);
//          px += charW; ++cx;
//        } while (px < target.w && cx < bgW);
//     }
//   }
//   if ( firstSprite ) { <bubble-sort sprites by Y; walk list calling
//                         sub_42469C (AnimBitmap.draw) / sub_42490E
//                         (AnimFlash.draw) for each> }
//   <restore Graphics clip>
//
// This port covers the (state & 6) == 6 default-state path (no opacity
// bit / no flip) which is what every gamelet ships with. Animated tiles
// (negative cell values), state-bit transforms (8/0x10/0x20), and the
// sprite-list walk are deferred — those re-enter the bytecode VM via
// AnimBitmap/AnimFlash.draw which our dispatcher can't invoke from
// inside a native call.
// Canonical-shape wrapper around the typed `drawImpl`.
fn draw(vm: *Vm, args: bridge.ArgFrame) i16 {
    _ = drawImpl(vm, args.this(), args.handle(1), args.getI32(2), args.getI32(3));
    return 0;
}

fn drawImpl(vm: *Vm, this: Handle, graphics: Handle, xoff: i32, yoff: i32) i32 {
    const inst = vm.heap.get(this) orelse return 0;

    const state = inst.field_map.get(FIELD_STATE) orelse 0;
    if ((state & 6) != 6) return 0;
    if ((inst.field_map.get(FIELD_BACKGROUND) orelse 0) == 0) return 0;

    const charset_h = inst.field_map.get(FIELD_CHARSET) orelse 0;
    if (charset_h == 0) return 0;
    const charset_img = vm.heap.get(charset_h) orelse return 0;
    if (charset_img.pixels == null) _h.doTransformToSystemPalette(vm, charset_h);
    const src_px = charset_img.pixels orelse return 0;
    const src_w_u32 = charset_img.pix_w;
    if (src_w_u32 == 0) return 0;

    const char_w: i32 = @bitCast(inst.field_map.get(FIELD_CHAR_W) orelse 0);
    const char_h: i32 = @bitCast(inst.field_map.get(FIELD_CHAR_H) orelse 0);
    if (char_w <= 0 or char_h <= 0) return 0;

    const tiles_per_row: i32 = @intCast(src_w_u32 / @as(u32, @intCast(char_w)));
    if (tiles_per_row == 0) return 0;

    const bg_w: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_W) orelse 0);
    const bg_h: i32 = @bitCast(inst.field_map.get(FIELD_BACKGROUND_H) orelse 0);

    const view_x: i32 = @bitCast(inst.field_map.get(FIELD_VIEW_X) orelse 0);
    const view_y: i32 = @bitCast(inst.field_map.get(FIELD_VIEW_Y) orelse 0);

    const target = _h.graphicsTarget(vm, graphics) orelse return 0;
    const tw: i32 = @intCast(target.width);
    const th: i32 = @intCast(target.height);

    // Effective clip rect (canonical sub_4177C6: intersect graphics.clip with
    // view-window then propagate to target descriptor via sub_425650). The
    // canonical blit (sub_418008) writes only inside this intersection.
    // Without this, wrap-around `draw(yoff)` calls overspill the gameplay
    // viewport and paint duplicate stamps into HUD/border regions.
    const view_w: i32 = @bitCast(inst.field_map.get(FIELD_VIEW_W) orelse @as(u32, @intCast(tw)));
    const view_h: i32 = @bitCast(inst.field_map.get(FIELD_VIEW_H) orelse @as(u32, @intCast(th)));
    const gfx_inst = vm.heap.get(graphics);
    const gcx: i32 = if (gfx_inst) |g| @bitCast(g.field_map.get(0xC1C15078) orelse 0) else 0;
    const gcy: i32 = if (gfx_inst) |g| @bitCast(g.field_map.get(0xC1C15079) orelse 0) else 0;
    const gcw_u: u32 = if (gfx_inst) |g| (g.field_map.get(0xC1C1507A) orelse 0) else 0;
    const gch_u: u32 = if (gfx_inst) |g| (g.field_map.get(0xC1C1507B) orelse 0) else 0;
    // If graphics.clip is unset (w==0 or h==0), default to the full target.
    const gcw: i32 = if (gcw_u == 0) tw else @intCast(gcw_u);
    const gch: i32 = if (gch_u == 0) th else @intCast(gch_u);
    // Intersect graphics.clip with (viewX, viewY, viewW, viewH):
    const clip_x0 = @max(@max(gcx, view_x), 0);
    const clip_y0 = @max(@max(gcy, view_y), 0);
    const clip_x1 = @min(@min(gcx + gcw, view_x + view_w), tw);
    const clip_y1 = @min(@min(gcy + gch, view_y + view_h), th);
    if (clip_x1 <= clip_x0 or clip_y1 <= clip_y0) return 0;

    // Canonical (lines 26720-21): v46 = viewX - xoff, v44 = viewY - yoff.
    // Negative result → scrolled past origin: split into cell-stride
    // skip + sub-cell pixel offset.
    const ox = view_x - xoff;
    const oy = view_y - yoff;
    // Canonical lines 26743-26761: when offset ≥ 0 → start at cell 0 with
    // pixel offset = ox; when offset < 0 → skip `-ox/charW` cells and
    // start with pixel offset = ox % charW (C99 % keeps sign of dividend,
    // i.e. a negative remainder ∈ (-charW, 0]).
    var cell_x0: i32 = 0;
    var pix_x0: i32 = ox;
    if (ox < 0) {
        cell_x0 = @divTrunc(-ox, char_w);
        pix_x0 = @rem(ox, char_w);
    }
    var cell_y0: i32 = 0;
    var pix_y0: i32 = oy;
    if (oy < 0) {
        cell_y0 = @divTrunc(-oy, char_h);
        pix_y0 = @rem(oy, char_h);
    }

    // Visibility guard (canonical line 26762): nothing visible if start
    // cell is past the grid extent OR start pixel is past target extent.
    if (cell_x0 >= bg_w or cell_y0 >= bg_h or pix_x0 >= tw or pix_y0 >= th) {
        return 0;
    }

    // Double loop (canonical lines 26785-26836). Outer-X / inner-Y matches
    // the canonical iteration order. Outer bound is clip_x1 (not tw) so we
    // stop early once we've left the clip rect on the right.
    var cell_x = cell_x0;
    var pix_x = pix_x0;
    while (pix_x < clip_x1 and cell_x < bg_w) {
        var cell_y = cell_y0;
        var pix_y = pix_y0;
        while (pix_y < clip_y1 and cell_y < bg_h) {
            const tile = readCell(vm, this, cell_x, cell_y);
            // Animated tiles (tile < 0) deferred; treat as blank for now.
            if (tile > 0) {
                const t0 = tile - 1;
                const sx = (@mod(t0, tiles_per_row)) * char_w;
                const sy = (@divTrunc(t0, tiles_per_row)) * char_h;
                blitTile(target, src_px, src_w_u32, pix_x, pix_y, sx, sy, char_w, char_h, clip_x0, clip_y0, clip_x1, clip_y1);
            }
            pix_y += char_h;
            cell_y += 1;
        }
        pix_x += char_w;
        cell_x += 1;
    }
    return 0;
}

/// Inlined unscaled mode=1 blit of one tile from the charset Image's
/// pre-decoded ABGR raster into the Graphics target. Mirrors the
/// `sub_418008` mode=1 path that Graphics.drawImage already implements
/// for the no-scale no-transform case. Honors the canonical clip rect
/// `[cx0, cx1) × [cy0, cy1)` propagated from Graphics.clip ∩ view-rect.
fn blitTile(
    target: _h.DrawTarget,
    src_px: []const u32,
    src_w: u32,
    dx: i32,
    dy: i32,
    sx: i32,
    sy: i32,
    w: i32,
    h: i32,
    cx0: i32,
    cy0: i32,
    cx1: i32,
    cy1: i32,
) void {
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        const py = dy + j;
        if (py < cy0 or py >= cy1) continue;
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            const px_x = dx + i;
            if (px_x < cx0 or px_x >= cx1) continue;
            const src_col: usize = @intCast(sx + i);
            const src_row: usize = @intCast(sy + j);
            const src_idx = src_row * src_w + src_col;
            if (src_idx >= src_px.len) continue;
            const p = src_px[src_idx];
            if ((p >> 24) == 0) continue; // alpha-0 transparent
            const dst_idx = @as(usize, @intCast(py)) * target.width + @as(usize, @intCast(px_x));
            target.pixels[dst_idx] = p;
        }
    }
}

// ── [49] sub_426FA8 — setCellTile(x, y, tile) ─────────────────────────────
// Canonical body (ref:26428):
//   v4 = a1[1];                                      // x
//   v3 = a1[2];                                      // y
//   if ( v4>=0 && v3>=0 && v4<a2[13] && v3<a2[14] && a2[12] )
//     sub_426E30(a2, v4, v3, a1[3]);                 // write tile
//   return 0;
//
// Canonical-shape (bridge.canonical): args.this() is the PlayField receiver,
// args.i32(N) reads the explicit args, return value is the push count
// (0 = void; no `*a1 = v` write needed because canonical returns 0).
fn setCellTile(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const tile = args.getI32(3);
    if (cellInBounds(vm, this, x, y)) writeCell(vm, this, x, y, tile);
    return 0;
}

// ── [50] sub_426F37 — getCellTile(x, y) ───────────────────────────────────
// Canonical body (ref:26412):
//   v4 = a1[1];                                      // x
//   v3 = a1[2];                                      // y
//   v5 = 0;
//   if ( v4>=0 && v3>=0 && v4<a2[13] && v3<a2[14] && a2[12] )
//     v5 = sub_426E9B(a2, v4, v3);
//   *a1 = v5;
//   return 1;
fn getCellTile(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const x = args.getI32(1);
    const y = args.getI32(2);
    const tile: i32 = if (cellInBounds(vm, this, x, y)) readCell(vm, this, x, y) else 0;
    args.setReturnI32(tile);
    return 1;
}

// [51] sub_427F95 — addSprite(sprite). ⚠ Zig impl pending.
fn unnamed_sub_427F95(vm: *Vm, args: bridge.ArgFrame) i16 {
    _ = vm; _ = args;
    return 0;
}

// [52] sub_4280BD — removeSprite(sprite). ⚠ Zig impl pending.
fn unnamed_sub_4280BD(vm: *Vm, args: bridge.ArgFrame) i16 {
    _ = vm; _ = args;
    return 0;
}

// [53] sub_428208 — removeAllSprite(). ⚠ Zig impl pending.
fn unnamed_sub_428208(vm: *Vm, args: bridge.ArgFrame) i16 {
    _ = vm; _ = args;
    return 0;
}

// Canonical-exact dispatch: every native takes (vm, ArgFrame) and returns
// push count (i16). The bridge propagates frame.slab[0..push] back to the
// caller's operand stack — matches ref's `SP += 4 * sub_407A94(...)`.
pub const handle = bridge.canonical(.{
    .{ 46, "PlayField.fillCells",      fillCells },
    .{ 47, "PlayField.moveTiles",      unnamed_sub_42712F },
    .{ 48, "PlayField.draw",           draw },
    .{ 49, "PlayField.setCellTile",    setCellTile },
    .{ 50, "PlayField.getCellTile",    getCellTile },
    .{ 51, "PlayField.addSprite",      unnamed_sub_427F95 },
    .{ 52, "PlayField.removeSprite",   unnamed_sub_4280BD },
    .{ 53, "PlayField.removeAllSprite", unnamed_sub_428208 },
});
