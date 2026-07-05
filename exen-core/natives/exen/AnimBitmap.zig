//! exen.AnimBitmap — native funcs_407AA2[] indices 43..45
//!
//! Frame-by-frame bitmap animation.
//!
//! Currently ported:
//!   45 → sub_42467B  getRealFrame(this, idx) — frame-index normalisation
//!   43 → sub_42469C  draw(graphics, dx, dy, frame, mode) — sprite renderer
//! Stub (defer to defaultNativeStub):
//!   44 → sub_4245FE  (frame helper) — pending

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

// TEMP DIAG — Phase 1 of HUD-frame-over-sprites investigation.
const clip_diag = std.log.scoped(.clip_diag);

pub const class_name: []const u8 = "AnimBitmap";
pub const first_index: u32 = 43;
pub const last_index: u32 = 45;

// ── AnimBitmap instance field hashes (verified from name registry) ─────────
// Per canonical byte-offset usage in sub_4243D0 + sub_42469C:
//   *(this+24) = image           = 0x3dd39153 (ref to source Image atlas)
//   *(this+28) = nbFrame         = 0xd042f952
//   *(this+32) = width  / frameW = 0xd0426be6 (also used as default sx)
//   *(this+36) = height / frameH = 0xd0425e87 (also used as default sy)
//   *(this+40) = state (flags)   = 0xd042ec80
//   *(this+44) = listCoords      = 0xa7f97fb5 (short[] of per-frame [sx,sy,sw,sh])
//   *(this+48) = frameSequence   = 0x18220a39 (int[] frame-index remap)
const FIELD_IMAGE:          u32 = 0x3dd39153;
const FIELD_FRAME_COUNT:    u32 = 0xd042f952;
const FIELD_FRAME_W:        u32 = 0xd0426be6;
const FIELD_FRAME_H:        u32 = 0xd0425e87;
const FIELD_STATE:          u32 = 0xd042ec80;
const FIELD_LIST_COORDS:    u32 = 0xa7f97fb5;
const FIELD_FRAME_REMAP:    u32 = 0x18220a39;

// ── [45] sub_42467B — getRealFrame(this, idx) → int ────────────────────────
// Canonical body (ref:24593):
//     *a1 = sub_424580(a2, a1[1]);   // a2 = this, a1[1] = frame_idx
//     return 1;
//
// sub_424580(this, idx) at ref:24547:
//   if (this[+48]) {              // remap table present
//     remap = this[+48];
//     v4 = idx % remap.length;
//     if (v4 < 0) v4 += remap.length;
//     idx = remap.entries[v4];
//   }
//   v5 = idx % this[+28];         // frame_count
//   if (v5 < 0) v5 += frame_count;
//   return v5;
fn getRealFrame(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const idx_in = args.getI32(1);
    args.setReturnI32(idx_in);
    const inst = vm.heap.get(this) orelse return 1;

    const frame_count_u = inst.field_map.get(FIELD_FRAME_COUNT) orelse 0;
    if (frame_count_u == 0) return 1;
    const frame_count: i32 = @bitCast(frame_count_u);

    var idx = idx_in;
    const remap_h = inst.field_map.get(FIELD_FRAME_REMAP) orelse 0;
    if (remap_h != 0) {
        if (vm.heap.get(remap_h)) |remap_inst| {
            const remap_len_u = remap_inst.fields[0];
            if (remap_len_u > 0) {
                const remap_len: i32 = @bitCast(remap_len_u);
                var rem_idx = @rem(idx, remap_len);
                if (rem_idx < 0) rem_idx += remap_len;
                const slot: usize = @as(usize, @intCast(rem_idx)) + 1;
                if (slot < remap_inst.fields.len) {
                    idx = @bitCast(remap_inst.fields[slot]);
                } else if (remap_inst.ints) |ix| {
                    const ui: usize = @intCast(rem_idx);
                    if (ui < ix.len) idx = @bitCast(ix[ui]);
                }
            }
        }
    }

    var result = @rem(idx, frame_count);
    if (result < 0) result += frame_count;
    args.setReturnI32(result);
    return 1;
}

// ── sub_4243D0 — frame-rect lookup ─────────────────────────────────────────
// Canonical body (ref:24479):
//   v8  = this[+28]; v10 = this[+32]; v9 = this[+36];
//   out_rect = (this[+32], this[+36], 0, 0);  // default sx/sy + 0/0 size
//   v11 = idx mod nbFrame (with negative normalisation);
//   if (this[+44]) {                          // listCoords present
//     coords = this[+44].bytes + 0 (header skip);
//     out_rect = (i16) coords[8*v11 .. 8*v11+8] as (sx, sy, sw, sh);
//   } else if (frameW && frameH && this[+24]) {  // grid fallback
//     img_w = this.image.width;
//     if (this[+40] & 1) img_w >>= 1;
//     tiles_per_row = img_w / frameW;
//     out_rect = (frameW * (v11 mod tiles_per_row),
//                 frameH * (v11 / tiles_per_row),
//                 frameW, frameH);
//   }
const FrameRect = struct { sx: i32, sy: i32, sw: i32, sh: i32 };

fn computeFrameRect(vm: *Vm, this: Handle, idx_in: i32) FrameRect {
    var rect = FrameRect{ .sx = 0, .sy = 0, .sw = 0, .sh = 0 };
    const inst = vm.heap.get(this) orelse return rect;

    const nb_frame_u = inst.field_map.get(FIELD_FRAME_COUNT) orelse 0;
    const frame_w: i32 = @bitCast(inst.field_map.get(FIELD_FRAME_W) orelse 0);
    const frame_h: i32 = @bitCast(inst.field_map.get(FIELD_FRAME_H) orelse 0);
    rect.sx = frame_w;
    rect.sy = frame_h;

    if (nb_frame_u == 0) return rect;
    const nb_frame: i32 = @bitCast(nb_frame_u);
    var v11 = @rem(idx_in, nb_frame);
    if (v11 < 0) v11 += nb_frame;

    const list_h = inst.field_map.get(FIELD_LIST_COORDS) orelse 0;
    if (list_h != 0) {
        if (vm.heap.get(list_h)) |coords_inst| {
            const base: usize = @intCast(v11 * 4);
            const slot = base + 1; // slot 0 holds array length
            const flen = coords_inst.fields.len;
            if (slot + 3 < flen) {
                rect.sx = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(coords_inst.fields[slot + 0])))));
                rect.sy = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(coords_inst.fields[slot + 1])))));
                rect.sw = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(coords_inst.fields[slot + 2])))));
                rect.sh = @as(i32, @as(i16, @bitCast(@as(u16, @truncate(coords_inst.fields[slot + 3])))));
            }
            return rect;
        }
    }

    // Grid fallback: tile the atlas by frameW × frameH.
    if (frame_w <= 0 or frame_h <= 0) return rect;
    const image_h = inst.field_map.get(FIELD_IMAGE) orelse 0;
    if (image_h == 0) return rect;
    const img_inst = vm.heap.get(image_h) orelse return rect;
    var img_w: i32 = @intCast(img_inst.pix_w);
    if (img_w == 0) return rect;
    const state = inst.field_map.get(FIELD_STATE) orelse 0;
    if ((state & 1) != 0) img_w >>= 1;
    const per_row = @divTrunc(img_w, frame_w);
    if (per_row <= 0) return rect;
    rect.sx = frame_w * @rem(v11, per_row);
    rect.sy = frame_h * @divTrunc(v11, per_row);
    rect.sw = frame_w;
    rect.sh = frame_h;
    return rect;
}

// ── Lightweight blit (unscaled) — mirrors the success branch of canonical
// sub_418008. `mode` is the J2ME TRANS_* transform (flip/rotate). `kernel`
// is the canonical `a11`/`v6` selector: 4 = normal sprite content;
// 3 = silhouette pass.
const Clip = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

fn blit(
    target: _h.DrawTarget,
    src_inst: *interp.Instance,
    sx: i32, sy: i32, sw: i32, sh: i32,
    dx: i32, dy: i32,
    mode: u32,
    kernel: u32,
    tr_skip_idx: ?u8,
    cl: Clip,
) void {
    const src_px = src_inst.pixels orelse return;
    const src_idx_buf: ?[]const u8 = src_inst.pixel_indices;
    if (sw <= 0 or sh <= 0) return;
    const iw: i32 = @intCast(src_inst.pix_w);
    const ih: i32 = @intCast(src_inst.pix_h);
    if (sx < 0 or sy < 0 or sx + sw > iw or sy + sh > ih) return;

    // MIDP transform semantics: mode 1 = TRANS_MIRROR_ROT180 (flip-Y only),
    // mode 3 = TRANS_ROT180 (flip-X + flip-Y). (Modes 4/7 keep existing flags.)
    const flip_x = (mode == 2 or mode == 3 or mode == 4 or mode == 7);
    const flip_y = (mode == 1 or mode == 3 or mode == 4 or mode == 7);
    const silhouette_color: u32 = 0xff404040;

    var j: i32 = 0;
    while (j < sh) : (j += 1) {
        const py = dy + j;
        if (py < cl.y0 or py >= cl.y1) continue;
        var i: i32 = 0;
        while (i < sw) : (i += 1) {
            const px_x = dx + i;
            if (px_x < cl.x0 or px_x >= cl.x1) continue;
            const u: i32 = if (flip_x) sw - 1 - i else i;
            const v: i32 = if (flip_y) sh - 1 - j else j;
            const sxx: usize = @intCast(sx + u);
            const syy: usize = @intCast(sy + v);
            const src_idx = syy * src_inst.pix_w + sxx;
            if (src_idx >= src_px.len) continue;
            const p = src_px[src_idx];
            if ((p >> 24) == 0) continue;
            // Index-based transparency (setPaletteAlpha / setTransparentColor):
            // skip pixels whose SOURCE palette index is the transparent one.
            // Mirrors Graphics.drawImage — canonical applies the transparent
            // index uniformly across the blit primitives, but our AnimBitmap
            // path previously honoured only alpha-0 (tRNS), leaving sprites
            // whose transparency is index-based (e.g. Spyro) with an opaque
            // index-0 background.
            if (tr_skip_idx) |tk| {
                if (src_idx_buf) |idxbuf| {
                    if (src_idx < idxbuf.len and idxbuf[src_idx] == tk) continue;
                }
            }
            const write_px = if (kernel == 3) silhouette_color else p;
            target.pixels[@as(usize, @intCast(py)) * target.width + @as(usize, @intCast(px_x))] = write_px;
        }
    }
}

// ── [43] sub_42469C — AnimBitmap.draw(graphics, dx, dy, frame_idx, mode) ───
// Canonical body (ref:24600):
//   v5  = this[+24]  (image);  v4 = this[+28] (nbFrame);  v15 = (i16)this[+40] (state lo16);
//   v12 = a1[1] (graphics);  v11/v8 = (dx, dy);  v9 = frame_idx;  v13 = mode;  v6 = 4;
//   if (!v12) return 0;
//   v14 = sub_426785(image_handle);    v7 = sub_426785(*(graphics + 24));
//   if (!v14 || !v7) return 0;
//   sub_425650(v12, v7);
//   if (!v5 || !v4 || !image.w || !image.h) return 0;
//   v10  = sub_424580(this, frame_idx)    // getRealFrame
//   sub_4243D0(this, v10, &v16)            // compute (sx, sy, sw, sh)
//   if (v15 & 2) {
//     if (state & 1)
//       sub_418008(target, dx, dy, sw, sh, src, sx + image.w/2, sy, sw, sh, 4, mode);
//     v6 = 3;
//   } else if (v15 & 1) {
//     sub_418008(target, dx, dy, sw, sh, src, sx + image.w/2, sy, sw, sh, 3, mode);
//   }
//   sub_418008(target, dx, dy, sw, sh, src, sx, sy, sw, sh, v6, mode);
//   return 0;
fn draw(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const graphics = args.handle(1);
    const dx = args.getI32(2);
    const dy = args.getI32(3);
    const frame_idx = args.getI32(4);
    const mode = args.getU32(5);
    if (graphics == 0) return 0;

    if (vm.heap.get(graphics)) |g| {
        const cx: i32 = @bitCast(g.field_map.get(0xC1C15078) orelse 0);
        const cy: i32 = @bitCast(g.field_map.get(0xC1C15079) orelse 0);
        const cw: i32 = @bitCast(g.field_map.get(0xC1C1507A) orelse 0);
        const ch: i32 = @bitCast(g.field_map.get(0xC1C1507B) orelse 0);
        clip_diag.info("AnimBitmap.draw gfx=0x{x:0>4} ab=0x{x:0>4} d=({d},{d}) frame={d} mode={d} clip=({d},{d},{d},{d})", .{
            graphics, this, dx, dy, frame_idx, mode, cx, cy, cw, ch,
        });
    }

    const inst = vm.heap.get(this) orelse return 0;
    const target = _h.graphicsTarget(vm, graphics) orelse return 0;

    // Honour the Graphics clip rect (canonical sub_425650 propagates it to
    // the target descriptor; the canonical blit writes only inside it). Our
    // blit previously clipped to the full target, so AnimBitmap-drawn tiles
    // (e.g. the isometric playfield) overflowed the gameplay viewport into
    // the HUD/border bands and left stale "overlay" pixels. Mirror
    // Graphics.drawImage's clip resolution.
    const tw_i: i32 = @intCast(target.width);
    const th_i: i32 = @intCast(target.height);
    var cl = Clip{ .x0 = 0, .y0 = 0, .x1 = tw_i, .y1 = th_i };
    if (vm.heap.get(graphics)) |g| {
        const gcw: i32 = @bitCast(g.field_map.get(0xC1C1507A) orelse 0);
        const gch: i32 = @bitCast(g.field_map.get(0xC1C1507B) orelse 0);
        if (gcw != 0 and gch != 0) {
            const gcx: i32 = @bitCast(g.field_map.get(0xC1C15078) orelse 0);
            const gcy: i32 = @bitCast(g.field_map.get(0xC1C15079) orelse 0);
            cl.x0 = @max(0, gcx);
            cl.y0 = @max(0, gcy);
            cl.x1 = @min(tw_i, gcx + gcw);
            cl.y1 = @min(th_i, gcy + gch);
            if (cl.x1 <= cl.x0 or cl.y1 <= cl.y0) return 0;
        }
    }

    const image_h = inst.field_map.get(FIELD_IMAGE) orelse 0;
    const nb_frame = inst.field_map.get(FIELD_FRAME_COUNT) orelse 0;
    if (image_h == 0 or nb_frame == 0) return 0;
    const src_inst = vm.heap.get(image_h) orelse return 0;
    if (src_inst.pixels == null) _h.doTransformToSystemPalette(vm, image_h);
    if (src_inst.pixels == null) return 0;
    if (src_inst.pix_w == 0 or src_inst.pix_h == 0) return 0;

    // 1. Get real frame index (canonical sub_424580).
    var real_idx = frame_idx;
    const fc: i32 = @bitCast(nb_frame);
    const remap_h = inst.field_map.get(FIELD_FRAME_REMAP) orelse 0;
    if (remap_h != 0) {
        if (vm.heap.get(remap_h)) |remap_inst| {
            const rlen_u = remap_inst.fields[0];
            if (rlen_u > 0) {
                const rlen: i32 = @bitCast(rlen_u);
                var ri = @rem(frame_idx, rlen);
                if (ri < 0) ri += rlen;
                const ridx: usize = @as(usize, @intCast(ri)) + 1;
                if (ridx < remap_inst.fields.len) {
                    real_idx = @bitCast(remap_inst.fields[ridx]);
                } else if (remap_inst.ints) |ix| {
                    const ui: usize = @intCast(ri);
                    if (ui < ix.len) real_idx = @bitCast(ix[ui]);
                }
            }
        }
    }
    var clamped = @rem(real_idx, fc);
    if (clamped < 0) clamped += fc;
    real_idx = clamped;

    // 2. Compute source rect (canonical sub_4243D0).
    const rect = computeFrameRect(vm, this, real_idx);
    if (rect.sw <= 0 or rect.sh <= 0) return 0;

    const state = inst.field_map.get(FIELD_STATE) orelse 0;
    const state_lo: u16 = @truncate(state);
    const img_w_half: i32 = @intCast(src_inst.pix_w / 2);

    // Resolve the source image's transparent palette index (set via
    // Image.setTransparentColor / setPaletteAlpha), gated on Graphics
    // paint_mode==1 — same rule as Graphics.drawImage.
    const tr_skip_idx: ?u8 = blk: {
        const paint_mode = if (vm.heap.get(graphics)) |g|
            (g.field_map.get(0x6f998aea) orelse 0) // FIELD_PAINT_MODE
        else
            @as(u32, 0);
        if (paint_mode != 1) break :blk null;
        const tr_mode = src_inst.field_map.get(0xC0FFEE03) orelse 0;
        const tr_idx_raw: u32 = switch (tr_mode) {
            48 => src_inst.field_map.get(0xC0FFEE01) orelse 0, // setTransparentColor
            32, 80 => src_inst.field_map.get(0xC0FFEE02) orelse 0, // setPaletteAlpha
            else => break :blk null,
        };
        break :blk @truncate(tr_idx_raw);
    };

    // 3. Auxiliary + main blits — canonical's kernel-3 vs kernel-4 distinction:
    //   v15 & 2 && state & 1: aux kernel=4 (normal at +w/2), main kernel=3 (shadow at sx)
    //   v15 & 1 only:         aux kernel=3 (shadow at +w/2), main kernel=4 (normal at sx)
    //   v15 & 2 only:         no aux,                       main kernel=3 (shadow at sx)
    //   default:              no aux,                       main kernel=4 (normal at sx)
    var main_kernel: u32 = 4;
    if ((state_lo & 2) != 0) {
        if ((state & 1) != 0) {
            blit(target, src_inst, rect.sx + img_w_half, rect.sy, rect.sw, rect.sh, dx, dy, mode, 4, tr_skip_idx, cl);
        }
        main_kernel = 3;
    } else if ((state_lo & 1) != 0) {
        blit(target, src_inst, rect.sx + img_w_half, rect.sy, rect.sw, rect.sh, dx, dy, mode, 3, tr_skip_idx, cl);
    }

    // 4. Main blit at (dx, dy) with the computed source rect.
    blit(target, src_inst, rect.sx, rect.sy, rect.sw, rect.sh, dx, dy, mode, main_kernel, tr_skip_idx, cl);
    return 0;
}

/// Known names for idxs in this class's range that have NO Zig handler
/// yet (they hit `defaultNativeStub` at runtime). Consumed by
/// `natives/mod.zig::native_names` for logs/tools; idxs in range but
/// absent here AND in `entries` render as "Class.?N". When porting one
/// of these, move the row into `entries` with its handler.
pub const stub_names = .{
    .{ 44, "moduloFrame" },   // sub_4245FE
};

pub const entries = .{
    .{ 43, "draw",         draw },
    .{ 45, "getRealFrame", getRealFrame },
};

pub const handle = bridge.canonical(entries);
