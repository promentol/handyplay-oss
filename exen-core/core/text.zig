//! Native 5×8 bitmap font used by `Graphics.drawChars`.
//!
//! Faithfully reproduces the simulator's host text path. At
//! `ref:5699` the host wires a 5×8-pixel, 256-glyph, 1-bit-per-
//! pixel atlas into the device vtable via
//! `sub_413A40(&unk_454DD0, 0x500, 8, 5, 9, 0x100)`. The atlas is 1280
//! bits per row × 8 rows = 1280 bytes total (the `9` argument is the
//! row stride between glyph rows, not the visible glyph height — the
//! glyph blitter `sub_413DF7:15375` iterates rows `[0, height-1)`, so
//! the visible height is 8).
//!
//! Bit convention is **inverted**: in the source atlas a bit value of
//! `0` means **ink** (foreground), `1` means **background** — see
//! `((1 << (7 - (j & 7))) & byte) == 0` at `ref:15444`. We
//! preserve that convention.
//!
//! The atlas bytes are extracted from `the reference simulator` at file offset
//! `0x54DD0` (PE VA `0x454DD0`) and embedded into the binary via
//! `@embedFile`, so we have zero runtime dependency on FreeType or an
//! external font file.

const std = @import("std");

const log = std.log.scoped(.text);

/// Embedded 5×8 1bpp font atlas (160 bytes per row × 8 rows = 1280 B).
/// Glyph `n` occupies columns `n*5 .. n*5+4` of every row.
const ATLAS: *const [1280]u8 = @embedFile("assets/font_5x8.bin");

const GLYPH_WIDTH: u32 = 5;
const GLYPH_HEIGHT: u32 = 8;
const STRIDE_BYTES: u32 = 160; // 1280 bits / 8

pub const Target = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// No-op kept for API compatibility with the previous FreeType backend.
pub fn init(
    allocator: std.mem.Allocator,
    font_path: [:0]const u8,
    pixel_size: u32,
) !void {
    _ = allocator;
    _ = font_path;
    _ = pixel_size;
    log.info("font ready: 5×8 native atlas (256 glyphs, embedded)", .{});
}

pub fn deinit() void {}

/// Blit one 5×8 glyph at top-left (x, y). The character index is the
/// raw byte value (0..255) — matches the gamelet's `byte[]` semantics
/// and the simulator's `chars[i]` indexing at `ref:15354`.
fn drawGlyph(t: Target, x: i32, y: i32, ch: u8, color: u32) void {
    const base_col: u32 = @as(u32, ch) * GLYPH_WIDTH;
    var gy: u32 = 0;
    while (gy < GLYPH_HEIGHT) : (gy += 1) {
        const py = y + @as(i32, @intCast(gy));
        if (py < 0 or py >= @as(i32, @intCast(t.height))) continue;
        var gx: u32 = 0;
        while (gx < GLYPH_WIDTH) : (gx += 1) {
            const px = x + @as(i32, @intCast(gx));
            if (px < 0 or px >= @as(i32, @intCast(t.width))) continue;
            const ax: u32 = base_col + gx;
            const byte = ATLAS[gy * STRIDE_BYTES + (ax >> 3)];
            const bit_mask: u8 = @as(u8, 1) << @intCast(7 - (ax & 7));
            // Inverted: bit=0 → ink, bit=1 → background.
            if ((byte & bit_mask) != 0) continue;
            const dst_idx: usize = @as(usize, @intCast(py)) * t.width + @as(usize, @intCast(px));
            t.pixels[dst_idx] = color;
        }
    }
}

/// Render `s` left-to-right starting at top-left (x, y) with the
/// caller's pen colour. Advances 6 px per glyph (5 px width + 1 px
/// inter-glyph spacing — matches `sub_413B4F:15304`'s `v13 = a1[13] +
/// 1`). Returns the x-coordinate just past the last glyph.
///
/// The simulator stops on byte `0xFF` (see `*a5 != -1` at
/// `ref:15351`); we replicate that so length-prefixed buffers
/// containing a 0xFF terminator render correctly without the caller
/// needing to trim.
pub fn drawString(t: Target, x: i32, y_top: i32, s: []const u8, color: u32) i32 {
    var cur_x = x;
    for (s) |b| {
        if (b == 0xFF) break;
        drawGlyph(t, cur_x, y_top, b, color);
        cur_x += @as(i32, @intCast(GLYPH_WIDTH + 1));
    }
    return cur_x;
}

/// Codepoint variant — accepts u32 codepoints but only honours the
/// low byte (the native atlas is a Latin-1 superset addressed by raw
/// byte; codepoints outside `0..0xFF` render as `?`).
pub fn drawCodepoints(t: Target, x: i32, y_top: i32, cps: []const u32, color: u32) i32 {
    var cur_x = x;
    for (cps) |cp| {
        const b: u8 = if (cp <= 0xFF) @intCast(cp) else '?';
        if (b == 0xFF) break;
        drawGlyph(t, cur_x, y_top, b, color);
        cur_x += @as(i32, @intCast(GLYPH_WIDTH + 1));
    }
    return cur_x;
}

/// Visible glyph height in pixels.
pub fn lineHeight() i32 {
    return @intCast(GLYPH_HEIGHT);
}

/// Distance from the supplied top-left y to the visual baseline.
/// Returns 0 because `Graphics.drawChars` already receives a top-left
/// coordinate from the gamelet (`a4` in `sub_413B4F`). Kept for API
/// compatibility with the previous FreeType backend, which needed a
/// baseline shift.
pub fn ascent() i32 {
    return 0;
}
