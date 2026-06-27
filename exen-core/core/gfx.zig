//! Graphics primitives — the host-side body of the gamelet-facing
//! `exen.Graphics.*` natives (subset of `funcs_407AA2[185]`).
//!
//! Single-buffer model: one ABGR8888 framebuffer sized to the simulated
//! LCD. Drawing functions write into it directly; the SDL host uploads
//! it to a texture each frame.
//!
//! This module deliberately exposes the API shape the VM would call
//! (clearRect, fillRect, drawImage, setColor, drawLine, setPixel,
//! getPixel) so that wiring it to the bytecode interpreter later is a
//! pure binding job — no rework. For now the VM is a no-op and the
//! host calls these directly to compose the boot splash.

const std = @import("std");

pub const Framebuffer = struct {
    width: u32,
    height: u32,
    pixels: []u32, // ABGR8888 little-endian = byte order R G B A
    allocator: std.mem.Allocator,

    /// Current pen color (ABGR8888) for primitive fills/lines. Mirrors
    /// the gamelet-visible color state in `exen.Graphics.setColor(int)`.
    color: u32 = 0xFF000000, // opaque black

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Framebuffer {
        const px = try allocator.alloc(u32, @as(usize, w) * h);
        @memset(px, 0xFF000000);
        return .{
            .width = w,
            .height = h,
            .pixels = px,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Framebuffer) void {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
    }

    /// Convert an ExEn 24-bit RGB color int to our ABGR8888 storage.
    /// The gamelet's `setColor(int rgb)` takes 0x00RRGGBB; we always
    /// add full alpha when writing the framebuffer.
    pub fn packRgb24(rgb: u32) u32 {
        const r: u32 = (rgb >> 16) & 0xFF;
        const g: u32 = (rgb >> 8) & 0xFF;
        const b: u32 = rgb & 0xFF;
        return 0xFF000000 | (b << 16) | (g << 8) | r;
    }

    pub fn setColor(self: *Framebuffer, rgb24: u32) void {
        self.color = packRgb24(rgb24);
    }
};

// ── primitives ─────────────────────────────────────────────────────────────

/// Fill an axis-aligned rect with the current pen color. Mirrors
/// `exen.Graphics.fillRect(int x, int y, int w, int h)`.
/// Out-of-bounds regions are silently clipped (matches the
/// behavior implied by the simulator's null-pointer guards at
/// `non catcheable interrupt in native exen.Graphics.fillRect`).
pub fn fillRect(fb: *Framebuffer, x: i32, y: i32, w: i32, h: i32) void {
    fillRectColor(fb, x, y, w, h, fb.color);
}

/// Clear an axis-aligned rect to opaque black. Mirrors
/// `exen.Graphics.clearRect(int x, int y, int w, int h)`.
pub fn clearRect(fb: *Framebuffer, x: i32, y: i32, w: i32, h: i32) void {
    fillRectColor(fb, x, y, w, h, 0xFF000000);
}

fn fillRectColor(fb: *Framebuffer, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const fb_w: i32 = @intCast(fb.width);
    const fb_h: i32 = @intCast(fb.height);
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    const x1 = @min(x + w, fb_w);
    const y1 = @min(y + h, fb_h);
    if (x1 <= x0 or y1 <= y0) return;

    var py: i32 = y0;
    while (py < y1) : (py += 1) {
        const row_off: usize = @as(usize, @intCast(py)) * fb.width;
        var px: i32 = x0;
        while (px < x1) : (px += 1) {
            fb.pixels[row_off + @as(usize, @intCast(px))] = color;
        }
    }
}

/// Set a single pixel to the current pen color. Mirrors
/// `exen.Graphics.setPixel(int x, int y)` — coords outside the
/// framebuffer are dropped.
pub fn setPixel(fb: *Framebuffer, x: i32, y: i32) void {
    if (x < 0 or y < 0) return;
    if (x >= @as(i32, @intCast(fb.width))) return;
    if (y >= @as(i32, @intCast(fb.height))) return;
    fb.pixels[@as(usize, @intCast(y)) * fb.width + @as(usize, @intCast(x))] = fb.color;
}

/// Read a pixel. Mirrors `exen.Graphics.getPixel(int x, int y)` —
/// returns 0 for out-of-bounds reads.
pub fn getPixel(fb: *const Framebuffer, x: i32, y: i32) u32 {
    if (x < 0 or y < 0) return 0;
    if (x >= @as(i32, @intCast(fb.width))) return 0;
    if (y >= @as(i32, @intCast(fb.height))) return 0;
    return fb.pixels[@as(usize, @intCast(y)) * fb.width + @as(usize, @intCast(x))];
}

/// Bresenham line in the current pen color. Mirrors
/// `exen.Graphics.drawLine(int x0, int y0, int x1, int y1)`.
pub fn drawLine(fb: *Framebuffer, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var x: i32 = x0;
    var y: i32 = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err: i32 = dx + dy;
    while (true) {
        setPixel(fb, x, y);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            if (x == x1) break;
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            if (y == y1) break;
            err += dx;
            y += sy;
        }
    }
}

/// Blit a source ABGR8888 image onto the framebuffer at (dx, dy).
/// Mirrors `exen.Graphics.drawImage(int dx, int dy, ...)` — pixels
/// with alpha == 0 are skipped (treated as transparent).
pub fn drawImage(
    fb: *Framebuffer,
    src_pixels: []const u32,
    src_w: u32,
    src_h: u32,
    dx: i32,
    dy: i32,
) void {
    if (src_w == 0 or src_h == 0) return;
    const fb_w: i32 = @intCast(fb.width);
    const fb_h: i32 = @intCast(fb.height);

    // Source-rect clipping against framebuffer.
    const sx0: i32 = @max(0, -dx);
    const sy0: i32 = @max(0, -dy);
    const sx1: i32 = @min(@as(i32, @intCast(src_w)), fb_w - dx);
    const sy1: i32 = @min(@as(i32, @intCast(src_h)), fb_h - dy);
    if (sx1 <= sx0 or sy1 <= sy0) return;

    var sy: i32 = sy0;
    while (sy < sy1) : (sy += 1) {
        const dst_y = dy + sy;
        const src_row_off: usize = @as(usize, @intCast(sy)) * src_w;
        const dst_row_off: usize = @as(usize, @intCast(dst_y)) * fb.width;
        var sx: i32 = sx0;
        while (sx < sx1) : (sx += 1) {
            const px = src_pixels[src_row_off + @as(usize, @intCast(sx))];
            if ((px >> 24) == 0) continue; // alpha=0 → transparent
            fb.pixels[dst_row_off + @as(usize, @intCast(dx + sx))] = px;
        }
    }
}

// ── tests ─────────────────────────────────────────────────────────────────

test "fillRect clips to bounds" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 4);
    defer fb.deinit();
    fb.setColor(0x00FF00);
    fillRect(&fb, -1, -1, 3, 3);
    // Top-left 2x2 should be green; rest still black.
    const g: u32 = (@as(u32, 0xFF) << 24) | (@as(u32, 0xFF) << 8); // ABGR: A=FF,B=00,G=FF,R=00
    try std.testing.expectEqual(g, fb.pixels[0]);
    try std.testing.expectEqual(g, fb.pixels[1]);
    try std.testing.expectEqual(g, fb.pixels[4]);
    try std.testing.expectEqual(g, fb.pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.pixels[10]);
}

test "drawImage skips transparent pixels" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 4);
    defer fb.deinit();
    // 2x2 source: opaque white, transparent, transparent, opaque white
    const src = [_]u32{ 0xFFFFFFFF, 0x00000000, 0x00000000, 0xFFFFFFFF };
    drawImage(&fb, &src, 2, 2, 1, 1);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb.pixels[1 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), fb.pixels[1 * 4 + 2]); // skipped
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), fb.pixels[2 * 4 + 2]);
}
