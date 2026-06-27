//! Framebuffer + the host-side bitmap-blit sink for the screen.
//!
//! The dsm engine renders into a full-screen RGB565 buffer in guest memory and
//! calls `mr_drawBitmap(bmp, x, y, w, h)` to flush a dirty rect. `bmp` points at
//! a SCREEN_WIDTH-stride framebuffer, so we copy the [x,x+w) x [y,y+h) window into
//! our own `screen` (same RGB565 format) and mark it dirty for the frontend.
const std = @import("std");

pub const screen_w: u32 = 240; // SCREEN_WIDTH
pub const screen_h: u32 = 320; // SCREEN_HEIGHT

pub const Gfx = struct {
    screen: [screen_w * screen_h]u16 = [_]u16{0} ** (screen_w * screen_h),
    dirty: bool = false,

    /// Copy a window of a full-screen-stride RGB565 buffer into `screen`.
    /// `bmp` is a host slice of the guest framebuffer (>= screen_w*screen_h u16).
    pub fn drawBitmap(self: *Gfx, bmp: []const u16, x: i32, y: i32, w: i32, h: i32) void {
        var j: i32 = 0;
        while (j < h) : (j += 1) {
            var i: i32 = 0;
            while (i < w) : (i += 1) {
                const xx = x + i;
                const yy = y + j;
                if (xx < 0 or yy < 0 or xx >= @as(i32, @intCast(screen_w)) or yy >= @as(i32, @intCast(screen_h)))
                    continue;
                const idx: usize = @intCast(xx + yy * @as(i32, @intCast(screen_w)));
                if (idx < bmp.len) self.screen[idx] = bmp[idx];
            }
        }
        self.dirty = true;
    }
};

// RGB565 channel extraction (utils.h PIXEL565*).
pub inline fn r5(v: u16) u8 {
    return @intCast(((@as(u32, v) >> 11) << 3) & 0xff);
}
pub inline fn g6(v: u16) u8 {
    return @intCast(((@as(u32, v) >> 5) << 2) & 0xff);
}
pub inline fn b5(v: u16) u8 {
    return @intCast((@as(u32, v) << 3) & 0xff);
}
