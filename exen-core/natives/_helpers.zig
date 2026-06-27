//! Shared helpers used across per-class native files. Each helper
//! takes a `*Vm` because natives operate on VM state — but the logic
//! here is "what natives DO with the VM", not "how the VM works
//! internally" (which lives in `core/vm/`).
//!
//! Three concerns covered:
//!   * Resource cursor I/O      — load/store + FIELD_RES_* hashes
//!   * Image palette decode     — doTransformToSystemPalette
//!   * Per-pixel target drawing — DrawTarget + graphicsTarget +
//!                                fillRect / setPixel / drawLine
//!
//! `instField` is here too — a one-line accessor wrapper that every
//! per-class native (Graphics/Image/Resource/Gamelet) uses.
//!
//! The leading underscore on the filename signals "internal to
//! natives/, not a class file" so it doesn't get mistaken for an ExEn
//! class by tab-completion or the dispatcher.

const std = @import("std");
const core = @import("core");
const exn = core.exn;

const Vm = core.interp.Vm;

// ── Resource field hashes ──────────────────────────────────────────────
// Match the class definition of exen.Resource (0xbab5c664) so the
// gamelet's bytecode GETFIELDs see the same values our natives wrote.
// Mapping (slot → instance offset → role) verified against sub_428AA0
// / sub_428B4E / sub_429813:
//
//   slot 0  (a2[6])  0xd042fc48  base   (file offset)
//   slot 1  (a2[7])  0xd04255b5  length
//   slot 2  (a2[8])  0xd042ab2b  position
//   slot 3  (a2[9])  0xd0426778  id
pub const FIELD_RES_BASE: u32 = 0xd042fc48;
pub const FIELD_RES_LENGTH: u32 = 0xd04255b5;
pub const FIELD_RES_POSITION: u32 = 0xd042ab2b;
pub const FIELD_RES_ID: u32 = 0xd0426778;

/// Graphics target-image field — set by `Graphics.<init>` via PUTFIELD.
///   slot 0 (own)  0x3dd3bff1  target Image (object)
pub const FIELD_GFX_TARGET: u32 = 0x3dd3bff1;

// ── pure accessors ─────────────────────────────────────────────────────

/// Read instance's hash-keyed field, default 0.
pub fn instField(vm: *Vm, handle: u32, hash: u32) u32 {
    if (vm.heap.get(handle)) |inst| return inst.field_map.get(hash) orelse 0;
    return 0;
}

// ── Resource I/O ───────────────────────────────────────────────────────

pub fn loadResource(vm: *Vm, handle: u32) ?exn.ResourceState {
    const inst = vm.heap.get(handle) orelse return null;
    return .{
        .base = inst.field_map.get(FIELD_RES_BASE) orelse return null,
        .length = inst.field_map.get(FIELD_RES_LENGTH) orelse 0,
        .position = inst.field_map.get(FIELD_RES_POSITION) orelse 0,
    };
}

/// Persist a `ResourceState`'s position back to the instance.
pub fn storeResource(vm: *Vm, handle: u32, st: exn.ResourceState) void {
    if (vm.heap.get(handle)) |inst| {
        inst.field_map.put(FIELD_RES_POSITION, st.position) catch {};
    }
}

// ── Per-pixel drawing into a target ────────────────────────────────────

pub const DrawTarget = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// Pick the destination raster for a Graphics native. The gamelet
/// binds an offscreen Image to each Graphics via PUTFIELD on
/// 0x3dd3bff1; we honour that here. If the target field is unset
/// (handle 0) or points to an Image without a writable raster, fall
/// back to the LCD — keeps simple gamelets that don't allocate an
/// offscreen Image visually working.
/// Canonical-exact Graphics target lookup.
///
/// Canonical (sub_425699/sub_425D20/sub_425A50/sub_4257A1/sub_425C73 — all
/// Graphics natives): `target_desc = sub_426785(this.field[+24])` —
/// every draw resolves through `FIELD_GFX_TARGET (0x3dd3bff1)` to an
/// Image's descriptor, and writes go to its pixel buffer.
///
/// Canonical halts (`sub_407A13` non-catcheable abort) if the target
/// is null. We mirror that: no LCD fallback — return null on missing
/// target so the calling native silently skips its draw. The caller
/// (drawImage/fillRect/etc.) treats `orelse return` as the canonical
/// "halt and return 0" behaviour.
///
/// Lazy-allocates the Image's pixel buffer on first draw — canonical's
/// `sub_426785` returns a descriptor whose buffer was already allocated
/// when the gamelet called `Image.<init>`; we mirror that.
pub fn graphicsTarget(vm: *Vm, this: u32) ?DrawTarget {
    const gfx = vm.heap.get(this) orelse return null;
    const off_h = gfx.field_map.get(FIELD_GFX_TARGET) orelse return null;
    if (off_h == 0) return null;
    const img = vm.heap.get(off_h) orelse return null;
    img.is_render_target = true; // composited-to, not palette-decoded

    if (img.pixels_owned == null and img.pix_w > 0 and img.pix_h > 0) {
        const n: usize = @as(usize, img.pix_w) * @as(usize, img.pix_h);
        if (vm.allocator.alloc(u32, n)) |buf| {
            @memset(buf, 0xFF000000); // opaque black init
            img.pixels_owned = buf;
            img.pixels = buf;
        } else |_| {}
    }
    if (img.pixels_owned) |px| {
        return .{ .pixels = px, .width = img.pix_w, .height = img.pix_h };
    }
    return null;
}

/// Solid-fill a rect into a DrawTarget with clipping.
pub fn fillRectIntoTarget(t: DrawTarget, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const tw: i32 = @intCast(t.width);
    const th: i32 = @intCast(t.height);
    const x0 = @max(x, 0);
    var y0 = @max(y, 0);
    const x1 = @min(x + w, tw);
    const y1 = @min(y + h, th);
    if (x1 <= x0 or y1 <= y0) return;
    while (y0 < y1) : (y0 += 1) {
        const row_off: usize = @as(usize, @intCast(y0)) * t.width;
        var xi = x0;
        while (xi < x1) : (xi += 1) {
            t.pixels[row_off + @as(usize, @intCast(xi))] = color;
        }
    }
}

pub fn setPixelInTarget(t: DrawTarget, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const tw: i32 = @intCast(t.width);
    const th: i32 = @intCast(t.height);
    if (x >= tw or y >= th) return;
    t.pixels[@as(usize, @intCast(y)) * t.width + @as(usize, @intCast(x))] = color;
}

pub fn drawLineInTarget(t: DrawTarget, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
    // Bresenham. Pixels outside the target are clipped via setPixelInTarget.
    var sx = x0;
    var sy = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const step_x: i32 = if (sx < x1) 1 else -1;
    const step_y: i32 = if (sy < y1) 1 else -1;
    var err: i32 = dx + dy;
    while (true) {
        setPixelInTarget(t, sx, sy, color);
        if (sx == x1 and sy == y1) break;
        const e2 = err * 2;
        if (e2 >= dy) {
            if (sx == x1) break;
            err += dy;
            sx += step_x;
        }
        if (e2 <= dx) {
            if (sy == y1) break;
            err += dx;
            sy += step_y;
        }
    }
}

// ── Image palette decode ───────────────────────────────────────────────

/// Convert an Image's indexed-byte data + palette to an ABGR raster.
/// Mirrors `sub_42664C` → `sub_418CDF`. Skips Images that already have
/// PNG-decoded pixels (`pixels` non-null) so we don't clobber sprites
/// that bypass the palette path entirely.
pub fn doTransformToSystemPalette(vm: *Vm, image_handle: u32) void {
    const inst = vm.heap.get(image_handle) orelse return;
    if (inst.pixels != null) return; // already decoded via PNG/B&W path
    // Render targets (offscreen Images bound as a Graphics draw target)
    // get their pixels from compositing, not a palette-decoded resource.
    // Decoding their (blank) indexed buffer here would overwrite the
    // composed pixels with black — breaking offscreen-composited content
    // like Pikubi2's menu-text strip. Canonical keeps one indexed buffer
    // per image; we approximate by never palette-decoding a render target.
    if (inst.is_render_target) return;
    const w = inst.pix_w;
    const h = inst.pix_h;
    if (w == 0 or h == 0) return;
    // Indexed pixel bytes live in the Image's pixel-buffer field
    // (hash 0xa6f15ba5). The byte data lives EITHER in the Instance's
    // `bytes` slice (when populated via Resource.readBytes) OR in the
    // `fields[1..]` u32 slots (when populated via BASTORE writes from
    // the gamelet's bytecode). We try both.
    const bytes_handle = inst.field_map.get(0xa6f15ba5) orelse return;
    const bytes_inst = vm.heap.get(bytes_handle) orelse return;
    // Resolve a palette source. Prefer the side-table (filled by
    // setPalette); fall back to the palette-buffer field — first its
    // .bytes slice, then its fields[1..] u32 slots.
    const pal_handle = inst.field_map.get(0xa6f1230d) orelse 0;
    const pal_inst = if (pal_handle != 0) vm.heap.get(pal_handle) else null;
    const have_side_palette = blk: {
        if (Vm.palette_state.getPtr(image_handle)) |pstate| {
            if (pstate.cursor > 0) break :blk true;
        }
        break :blk false;
    };
    // Skip the decode if we have no usable palette source.
    if (!have_side_palette) {
        if (pal_inst == null) return;
        if (pal_inst.?.bytes == null and pal_inst.?.fields[0] == 0) return;
    }
    // NOTE: a non-canonical "defer decode while palette is all-zero" guard
    // used to sit here (added to chase Pikubi2 font-atlas colours). It made
    // `inst.pixels` stay null for offscreen render-target images whose
    // palette is legitimately all-zero (e.g. Pikubi2's menu text strip),
    // so `PlayField.draw` / `drawImage` bailed at `pixels orelse return`
    // and drew nothing — the menu text regressed from black rectangles to
    // missing entirely. Canonical `sub_42664C` always decodes; we match it.

    const total: usize = @as(usize, w) * @as(usize, h);
    const buf = vm.allocator.alloc(u32, total) catch return;
    // Parallel buffer of source palette indices — lets drawImage match
    // transparency by palette index, not by decoded ABGR.
    const idx_buf = vm.allocator.alloc(u8, total) catch {
        vm.allocator.free(buf);
        return;
    };
    // Helper: read byte i from the indexed-pixel buffer. Prefer the
    // populated .bytes slice, fall back to fields[1+i] (truncated to
    // u8) for arrays the gamelet filled via BASTORE.
    const pix_bytes = bytes_inst.bytes;
    const pix_field_count: u32 = bytes_inst.fields[0];
    const read_pix = struct {
        fn at(b: ?[]const u8, f: []const u32, fc: u32, k: usize) u8 {
            if (b) |bb| return if (k < bb.len) bb[k] else 0;
            const slot = k + 1;
            if (slot >= f.len) return 0;
            if (k >= fc) return 0;
            return @truncate(f[slot]);
        }
    }.at;
    // Same for palette: side-table first, then pal_inst.bytes, then
    // pal_inst.fields[1..].
    const pstate_ptr = Vm.palette_state.getPtr(image_handle);
    const pal_field_count: u32 = if (pal_inst) |pi| pi.fields[0] else 0;
    const pal_bytes_slice: ?[]const u8 = if (pal_inst) |pi| pi.bytes else null;
    const read_pal = struct {
        fn at(ps: ?*Vm.PaletteState, pb: ?[]const u8, pf: []const u32, pfc: u32, k: u8) u8 {
            if (ps) |p| {
                if (p.cursor > 0 and @as(u32, k) < p.cursor) return p.bytes[k];
            }
            if (pb) |b| return if (k < b.len) b[k] else 0;
            const slot = @as(usize, k) + 1;
            if (slot >= pf.len) return 0;
            if (@as(u32, k) >= pfc) return 0;
            return @truncate(pf[slot]);
        }
    }.at;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const pix_idx = read_pix(pix_bytes, &bytes_inst.fields, pix_field_count, i);
        idx_buf[i] = pix_idx;
        const c = read_pal(pstate_ptr, pal_bytes_slice, if (pal_inst) |pi| &pi.fields else &[_]u32{}, pal_field_count, pix_idx);
        const r3: u32 = (c >> 5) & 0x07;
        const g3: u32 = (c >> 2) & 0x07;
        const b2: u32 = c & 0x03;
        const r: u32 = (r3 * 255) / 7;
        const g: u32 = (g3 * 255) / 7;
        const b: u32 = (b2 * 255) / 3;
        // All palette-decoded pixels are opaque. Transparency is signalled
        // separately via `setTransparentColor` → FIELD_IMG_TR_MODE/COLOR
        // which `Graphics.drawImage` consults via the `tr_skip` path.
        // (Previously this branched `palette[0] → alpha=0` as an implicit
        // transparency rule. That broke Pikubi/Wallbreaker backgrounds:
        // when the gamelet redraws a tile whose fill is palette-0, the
        // alpha-0 pixels were silently skipped by drawImage, leaving old
        // sprites ghosting at their previous positions.)
        buf[i] = 0xFF000000 | (b << 16) | (g << 8) | r;
    }
    inst.pixels_owned = buf;
    inst.pixels = buf;
    // Free any stale index buffer before storing the fresh one (in case
    // doTransform ran before and pixels were nulled out).
    if (inst.pixel_indices) |old| vm.allocator.free(old);
    inst.pixel_indices = idx_buf;
}
