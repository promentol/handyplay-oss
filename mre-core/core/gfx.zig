//! Graphics state + canvas/layer model.
//!
//! MRE canvases live in guest memory as `[signature:12][frame_property:20][pixels]`
//! (RGB565). `vm_graphic_get_layer_buffer` returns the *pixel* pointer (canvas+32),
//! so `findCanvas` accepts either the signature address or the pixel address.
//! Drawing primitives take a pixel/canvas pointer and write RGB565 directly into the
//! shared buffer; `flushLayer` composites layers into the host `screen` framebuffer.
const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const screen_w: u32 = 240;
pub const screen_h: u32 = 320;

pub const canvas_data_offset: u32 = 32; // sizeof(signature)+sizeof(frame_property)
const magic = "MTKCANVAS";

// frame_property field byte offsets (relative to the property struct start)
const fp_width = 5;
const fp_height = 7;
const fp_trans_color = 12;
const fp_flag = 0;

/// Magenta transparent-key our image loader writes for alpha<128 pixels (see
/// natives.zig gLoadImage). Kept in sync there.
pub const trans_sentinel: u16 = 0xF81F;

const max_layers = 16;
const max_poly_points = 64;

pub fn getRed(c: u16) u8 {
    return @intCast(((c >> 11) & 0x1F) << 3);
}
pub fn getGreen(c: u16) u8 {
    return @intCast(((c >> 5) & 0x3F) << 2);
}
pub fn getBlue(c: u16) u8 {
    return @intCast((c & 0x1F) << 3);
}
pub fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
}

const Layer = struct { buf: u32, x: i32, y: i32, w: i32, h: i32, trans_color: i32 };
const Clip = struct { flag: bool = false, left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

/// View into a canvas located in guest memory.
const Canvas = struct {
    pixels: u32, // EMU offset of pixel data
    w: i32,
    h: i32,
    flag: bool,
    trans_color: u16,
};

pub const Graphics = struct {
    mem: *Memory,
    screen: []u16, // host-side composite target (RGB565)
    base_buf1: u32 = 0,
    base_buf2: u32 = 0,
    layers: [max_layers]Layer = undefined,
    layer_count: usize = 0,
    active_layer: usize = 0,
    global_color: u16 = 0,
    clip: Clip = .{},

    pub fn init(gpa: std.mem.Allocator, mem: *Memory) !Graphics {
        const screen = try gpa.alloc(u16, screen_w * screen_h);
        @memset(screen, 0);
        var g: Graphics = .{ .mem = mem, .screen = screen };
        g.base_buf1 = try g.makeBaseCanvas();
        g.base_buf2 = try g.makeBaseCanvas();
        return g;
    }

    pub fn deinit(self: *Graphics, gpa: std.mem.Allocator) void {
        gpa.free(self.screen);
    }

    fn makeBaseCanvas(self: *Graphics) !u32 {
        const sz = canvas_data_offset + screen_w * screen_h * 2;
        const canvas = self.mem.sharedMalloc(sz, false, 2);
        if (canvas == 0) return error.AllocFailed;
        self.writeSignature(canvas, screen_w, screen_h);
        return canvas + canvas_data_offset; // pixel pointer (base_buf)
    }

    fn writeSignature(self: *Graphics, canvas: u32, w: u16, h: u16) void {
        const buf = self.mem.buf;
        @memcpy(buf[canvas..][0..9], magic);
        buf[canvas + 9] = 1; // frame_count
        buf[canvas + 10] = 0xFF; // i_dont_know
        buf[canvas + 11] = 1; // color_format
        const fp = canvas + 12;
        @memset(buf[fp..][0..20], 0);
        self.mem.writeU16(fp + fp_width, w);
        self.mem.writeU16(fp + fp_height, h);
    }

    pub const CanvasInfo = struct { pixels: u32, w: i32, h: i32, flag: bool, trans_color: u16 };

    /// Public canvas lookup for get_img_property etc.
    pub fn canvasInfo(self: *Graphics, buf: u32) ?CanvasInfo {
        const c = self.findCanvas(buf) orelse return null;
        return .{ .pixels = c.pixels, .w = c.w, .h = c.h, .flag = c.flag, .trans_color = c.trans_color };
    }

    /// Resolve a canvas signature address from either a signature address or a
    /// pixel address (== signature + canvas_data_offset). Null if neither matches.
    fn signatureAddr(self: *Graphics, buf: u32) ?u32 {
        const m = self.mem;
        if (buf != 0 and buf + 9 <= m.buf.len and std.mem.eql(u8, m.buf[buf..][0..9], magic)) return buf;
        if (buf >= canvas_data_offset and buf - canvas_data_offset + 9 <= m.buf.len and
            std.mem.eql(u8, m.buf[buf - canvas_data_offset ..][0..9], magic)) return buf - canvas_data_offset;
        return null;
    }

    /// Accepts a signature address or a pixel address (== signature+32).
    fn findCanvas(self: *Graphics, buf: u32) ?Canvas {
        const m = self.mem;
        const cs = self.signatureAddr(buf) orelse return null;
        const fp = cs + 12;
        return .{
            .pixels = cs + canvas_data_offset,
            .w = m.readU16(fp + fp_width),
            .h = m.readU16(fp + fp_height),
            .flag = m.buf[fp + fp_flag] != 0,
            .trans_color = m.readU16(fp + fp_trans_color),
        };
    }

    /// vm_graphic_get_frame_number: frames stored in the canvas signature (byte 9,
    /// after the 9-byte magic). writeSignature seeds this to 1 for a decoded image;
    /// true multi-frame GIF playback would decode and raise this. 0 => not a canvas.
    pub fn frameNumber(self: *Graphics, buf: u32) i32 {
        const cs = self.signatureAddr(buf) orelse return 0;
        return self.mem.buf[cs + 9];
    }

    // --- layer management ----------------------------------------------------

    pub fn createLayer(self: *Graphics, x: i32, y: i32, w: i32, h: i32, trans: i32) i32 {
        if (self.layer_count == 0) {
            if (x != 0 or y != 0 or w != screen_w or h != screen_h) return -1;
            self.layers[0] = .{ .buf = self.base_buf1, .x = x, .y = y, .w = w, .h = h, .trans_color = trans };
            self.layer_count = 1;
            self.active_layer = 0;
            return 0;
        } else if (self.layer_count == 1) {
            if (w > screen_w or h > screen_h) return -1;
            // resize base_buf2's frame_property to w,h
            const fp = self.base_buf2 - canvas_data_offset + 12;
            self.mem.writeU16(fp + fp_width, @intCast(w));
            self.mem.writeU16(fp + fp_height, @intCast(h));
            self.layers[1] = .{ .buf = self.base_buf2, .x = x, .y = y, .w = w, .h = h, .trans_color = trans };
            self.layer_count = 2;
            return 1;
        }
        return -1;
    }

    /// create_layer_ex: register an app-provided pixel buffer as a new layer.
    pub fn createLayerExternal(self: *Graphics, x: i32, y: i32, w: i32, h: i32, trans: i32, pixels: u32) i32 {
        if (self.layer_count >= max_layers) return -1;
        const idx = self.layer_count;
        self.layers[idx] = .{ .buf = pixels, .x = x, .y = y, .w = w, .h = h, .trans_color = trans };
        self.layer_count += 1;
        return @intCast(idx);
    }

    pub fn getLayerBuffer(self: *Graphics, handle: i32) u32 {
        if (handle < 0 or handle >= self.layer_count) return 0;
        return self.layers[@intCast(handle)].buf;
    }

    pub fn activeLayer(self: *Graphics, handle: i32) i32 {
        if (handle < 0 or handle >= self.layer_count) return -1;
        self.active_layer = @intCast(handle);
        return 0;
    }

    /// clear_layer_bg: fill the layer with its transparent color (the trans_color
    /// passed to create_layer). Games call this per frame to reset a layer before
    /// redrawing; the trans pixels are then skipped during flush_layer compositing.
    pub fn clearLayerBg(self: *Graphics, handle: i32) i32 {
        const idx: usize = if (handle < 0) self.active_layer else @intCast(handle);
        if (idx >= self.layer_count) return -1;
        const layer = self.layers[idx];
        const color: u16 = @truncate(@as(u32, @bitCast(layer.trans_color)));
        const n: u32 = @intCast(layer.w * layer.h);
        var i: u32 = 0;
        while (i < n) : (i += 1) self.mem.writeU16(layer.buf + i * 2, color);
        return 0;
    }

    pub fn flushLayer(self: *Graphics, handles: []const i32) i32 {
        // Resolve handles: a negative handle (-1) means the active layer.
        var resolved: [max_layers]usize = undefined;
        const n = handles.len;
        for (handles, 0..) |h, i| {
            const idx: usize = if (h < 0) self.active_layer else @intCast(h);
            if (idx >= self.layer_count) return -1;
            resolved[i] = idx;
        }
        var sy: i32 = 0;
        while (sy < screen_h) : (sy += 1) {
            var sx: i32 = 0;
            while (sx < screen_w) : (sx += 1) {
                var lid: isize = @as(isize, @intCast(n)) - 1;
                while (lid >= 0) : (lid -= 1) {
                    const layer = self.layers[resolved[@intCast(lid)]];
                    const lx = sx - layer.x;
                    const ly = sy - layer.y;
                    if (lx < 0 or lx >= layer.w or ly < 0 or ly >= layer.h) continue;
                    const color = self.mem.readU16(layer.buf + @as(u32, @intCast(ly * layer.w + lx)) * 2);
                    if (@as(i32, color) == layer.trans_color) continue;
                    self.screen[@intCast(sy * @as(i32, screen_w) + sx)] = color;
                    break;
                }
            }
        }
        return 0;
    }

    // --- primitives ----------------------------------------------------------

    fn clipBounds(self: *Graphics, cw: i32, ch: i32) [4]i32 {
        var l: i32 = 0;
        var t: i32 = 0;
        var r: i32 = cw;
        var b: i32 = ch;
        if (self.clip.flag) {
            if (l < self.clip.left) l = self.clip.left;
            if (t < self.clip.top) t = self.clip.top;
            if (r > self.clip.right + 1) r = self.clip.right + 1;
            if (b > self.clip.bottom + 1) b = self.clip.bottom + 1;
        }
        return .{ l, t, r, b };
    }

    fn putPixel(self: *Graphics, c: Canvas, x: i32, y: i32, color: u16) void {
        if (x < 0 or x >= c.w or y < 0 or y >= c.h) return;
        self.mem.writeU16(c.pixels + @as(u32, @intCast(y * c.w + x)) * 2, color);
    }

    pub fn setPixel(self: *Graphics, buf: u32, x: i32, y: i32, color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        const cb = self.clipBounds(c.w, c.h);
        if (x < cb[0] or x >= cb[2] or y < cb[1] or y >= cb[3]) return;
        self.putPixel(c, x, y, color);
    }

    pub fn fillRect(self: *Graphics, buf: u32, x: i32, y: i32, w: i32, h: i32, line_color: u16, back_color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        var st_x = @max(@as(i32, 0), x);
        var st_y = @max(@as(i32, 0), y);
        var end_x = @min(c.w, x + w);
        var end_y = @min(c.h, y + h);
        if (self.clip.flag) {
            st_x = @max(st_x, self.clip.left);
            st_y = @max(st_y, self.clip.top);
            end_x = @min(end_x, self.clip.right + 1);
            end_y = @min(end_y, self.clip.bottom + 1);
        }
        var sy = st_y;
        while (sy < end_y) : (sy += 1) {
            var sx = st_x;
            while (sx < end_x) : (sx += 1) {
                const edge = (sx == x or sy == y or sx == x + w - 1 or sy == y + h - 1);
                self.putPixel(c, sx, sy, if (edge) line_color else back_color);
            }
        }
    }

    /// vm_graphic_fill_polygon: even-odd scanline fill of an N-point polygon into a
    /// canvas, using the global pen color. Points are `vm_graphic_point {VMINT16 x,y}`
    /// (4 bytes each) at `pts_emu` in guest memory. Honors the clip rect.
    pub fn fillPolygon(self: *Graphics, buf: u32, pts_emu: u32, npoints: u32, color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        const n = @min(npoints, @as(u32, max_poly_points));
        if (n < 3) return;
        var px: [max_poly_points]i32 = undefined;
        var py: [max_poly_points]i32 = undefined;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            px[i] = @as(i16, @bitCast(self.mem.readU16(pts_emu + i * 4)));
            py[i] = @as(i16, @bitCast(self.mem.readU16(pts_emu + i * 4 + 2)));
        }
        const cb = self.clipBounds(c.w, c.h); // [left, top, right, bottom] (r/b exclusive)
        var min_y = py[0];
        var max_y = py[0];
        var k: u32 = 1;
        while (k < n) : (k += 1) {
            min_y = @min(min_y, py[k]);
            max_y = @max(max_y, py[k]);
        }
        min_y = @max(min_y, cb[1]);
        max_y = @min(max_y, cb[3]);
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var xs: [max_poly_points]i32 = undefined;
            var cnt: u32 = 0;
            var a: u32 = 0;
            while (a < n) : (a += 1) {
                const b = (a + 1) % n;
                var y0 = py[a];
                var y1 = py[b];
                var x0 = px[a];
                var x1 = px[b];
                if (y0 == y1) continue; // horizontal edge contributes no crossing
                if (y0 > y1) {
                    std.mem.swap(i32, &y0, &y1);
                    std.mem.swap(i32, &x0, &x1);
                }
                if (y >= y0 and y < y1) { // half-open avoids double-counting vertices
                    xs[cnt] = x0 + @divTrunc((y - y0) * (x1 - x0), (y1 - y0));
                    cnt += 1;
                }
            }
            // insertion sort the crossings
            var s: u32 = 1;
            while (s < cnt) : (s += 1) {
                const key = xs[s];
                var j: i32 = @as(i32, @intCast(s)) - 1;
                while (j >= 0 and xs[@intCast(j)] > key) : (j -= 1) xs[@intCast(j + 1)] = xs[@intCast(j)];
                xs[@intCast(j + 1)] = key;
            }
            var p: u32 = 0;
            while (p + 1 < cnt) : (p += 2) {
                const sx = @max(xs[p], cb[0]);
                const ex = @min(xs[p + 1], cb[2]);
                var xx = sx;
                while (xx < ex) : (xx += 1) self.putPixel(c, xx, y, color);
            }
        }
    }

    pub fn line(self: *Graphics, buf: u32, x0: i32, y0: i32, x1: i32, y1: i32, color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        // Bresenham, clipped per-pixel.
        var x = x0;
        var y = y0;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        const cb = self.clipBounds(c.w, c.h);
        while (true) {
            if (x >= cb[0] and x < cb[2] and y >= cb[1] and y < cb[3]) self.putPixel(c, x, y, color);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    pub fn blt(self: *Graphics, dst_buf: u32, x_dest: i32, y_dest: i32, src_buf: u32, x_src: i32, y_src: i32, width: i32, height: i32) void {
        const dst = self.findCanvas(dst_buf) orelse return;
        const src = self.findCanvas(src_buf) orelse return;
        var w = width;
        var h = height;
        if (x_src + w > src.w) w = src.w - x_src;
        if (y_src + h > src.h) h = src.h - y_src;

        var st_x = @max(@as(i32, 0), x_dest);
        var st_y = @max(@as(i32, 0), y_dest);
        var end_x = @min(dst.w, x_dest + w);
        var end_y = @min(dst.h, y_dest + h);
        if (self.clip.flag) {
            st_x = @max(st_x, self.clip.left);
            st_y = @max(st_y, self.clip.top);
            end_x = @min(end_x, self.clip.right + 1);
            end_y = @min(end_y, self.clip.bottom + 1);
        }
        var sy = st_y;
        while (sy < end_y) : (sy += 1) {
            var sx = st_x;
            while (sx < end_x) : (sx += 1) {
                const im_x = sx - x_dest + x_src;
                const im_y = sy - y_dest + y_src;
                if (im_x < 0 or im_x >= src.w or im_y < 0 or im_y >= src.h) continue;
                const color = self.mem.readU16(src.pixels + @as(u32, @intCast(im_y * src.w + im_x)) * 2);
                if (!src.flag or color != src.trans_color)
                    self.mem.writeU16(dst.pixels + @as(u32, @intCast(sy * dst.w + sx)) * 2, color);
            }
        }
    }

    pub fn setClip(self: *Graphics, l: i32, t: i32, r: i32, b: i32) void {
        self.clip = .{ .flag = true, .left = l, .top = t, .right = r, .bottom = b };
    }
    pub fn resetClip(self: *Graphics) void {
        self.clip.flag = false;
    }

    /// Direct-framebuffer API: `base_buf1` doubles as the screen back-buffer for
    /// games that use vm_graphic_get_buffer instead of layers.
    pub fn screenBuffer(self: *Graphics) u32 {
        return self.base_buf1;
    }

    /// Present the screen back-buffer (base_buf1) into the host composite target.
    pub fn present(self: *Graphics) void {
        const px = self.base_buf1;
        var idx: u32 = 0;
        const n: u32 = screen_w * screen_h;
        while (idx < n) : (idx += 1) {
            self.screen[idx] = self.mem.readU16(px + idx * 2);
        }
    }

    // --- more primitives -----------------------------------------------------

    pub fn rect(self: *Graphics, buf: u32, x: i32, y: i32, w: i32, h: i32, color: u16) void {
        // outline only
        self.fillRectEdgeOnly(buf, x, y, w, h, color);
    }

    fn fillRectEdgeOnly(self: *Graphics, buf: u32, x: i32, y: i32, w: i32, h: i32, color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        const cb = self.rectBounds(c, x, y, w, h);
        var sy = cb[1];
        while (sy < cb[3]) : (sy += 1) {
            var sx = cb[0];
            while (sx < cb[2]) : (sx += 1) {
                if (sx == x or sy == y or sx == x + w - 1 or sy == y + h - 1)
                    self.putPixel(c, sx, sy, color);
            }
        }
    }

    fn rectBounds(self: *Graphics, c: Canvas, x: i32, y: i32, w: i32, h: i32) [4]i32 {
        var st_x = @max(@as(i32, 0), x);
        var st_y = @max(@as(i32, 0), y);
        var end_x = @min(c.w, x + w);
        var end_y = @min(c.h, y + h);
        if (self.clip.flag) {
            st_x = @max(st_x, self.clip.left);
            st_y = @max(st_y, self.clip.top);
            end_x = @min(end_x, self.clip.right + 1);
            end_y = @min(end_y, self.clip.bottom + 1);
        }
        return .{ st_x, st_y, end_x, end_y };
    }

    pub fn roundRect(self: *Graphics, buf: u32, x: i32, y: i32, w: i32, h: i32, corner: i32, color: u16) void {
        // Approximate: outline with square corners (corner radius cosmetic).
        _ = corner;
        self.fillRectEdgeOnly(buf, x, y, w, h, color);
    }

    pub fn fillRoundRect(self: *Graphics, buf: u32, x: i32, y: i32, w: i32, h: i32, corner: i32, color: u16) void {
        _ = corner;
        self.fillRect(buf, x, y, w, h, color, color);
    }

    pub fn rotate(self: *Graphics, dst_buf: u32, x_des: i32, y_des: i32, src_buf: u32, degrees: i32) void {
        const dst = self.findCanvas(dst_buf) orelse return;
        const src = self.findCanvas(src_buf) orelse return;
        var width = src.w;
        var height = src.h;
        if (degrees == 90 or degrees == 270) {
            const t = width;
            width = height;
            height = t;
        }
        const cb = self.rectBounds(dst, x_des, y_des, width, height);
        var sy = cb[1];
        while (sy < cb[3]) : (sy += 1) {
            var sx = cb[0];
            while (sx < cb[2]) : (sx += 1) {
                var im_x = sx - x_des;
                var im_y = sy - y_des;
                if (degrees == 90) {
                    const t = im_x;
                    im_x = im_y;
                    im_y = width - t - 1;
                } else if (degrees == 270) {
                    const t = im_x;
                    im_x = height - im_y - 1;
                    im_y = t;
                } else if (degrees == 180) {
                    im_x = width - im_x - 1;
                    im_y = height - im_y - 1;
                }
                if (im_x < 0 or im_x >= src.w or im_y < 0 or im_y >= src.h) continue;
                const color = self.mem.readU16(src.pixels + @as(u32, @intCast(im_y * src.w + im_x)) * 2);
                if (!src.flag or color != src.trans_color)
                    self.mem.writeU16(dst.pixels + @as(u32, @intCast(sy * dst.w + sx)) * 2, color);
            }
        }
    }

    pub fn mirror(self: *Graphics, dst_buf: u32, x_des: i32, y_des: i32, src_buf: u32, horizontal: bool) void {
        const dst = self.findCanvas(dst_buf) orelse return;
        const src = self.findCanvas(src_buf) orelse return;
        const cb = self.rectBounds(dst, x_des, y_des, src.w, src.h);
        var sy = cb[1];
        while (sy < cb[3]) : (sy += 1) {
            var sx = cb[0];
            while (sx < cb[2]) : (sx += 1) {
                var im_x = sx - x_des;
                var im_y = sy - y_des;
                if (horizontal) im_x = src.w - im_x - 1 else im_y = src.h - im_y - 1;
                if (im_x < 0 or im_x >= src.w or im_y < 0 or im_y >= src.h) continue;
                const color = self.mem.readU16(src.pixels + @as(u32, @intCast(im_y * src.w + im_x)) * 2);
                if (!src.flag or color != src.trans_color)
                    self.mem.writeU16(dst.pixels + @as(u32, @intCast(sy * dst.w + sx)) * 2, color);
            }
        }
    }

    pub fn translateLayer(self: *Graphics, handle: i32, tx: i32, ty: i32) i32 {
        if (handle < 0 or handle >= self.layer_count) return -1;
        self.layers[@intCast(handle)].x += tx;
        self.layers[@intCast(handle)].y += ty;
        return 0;
    }

    /// Allocate a canvas in the app arena, returns the canvas (signature) address.
    pub fn createCanvas(self: *Graphics, app_malloc: *const fn (*anyopaque, u32) u32, ctx: *anyopaque, w: u16, h: u16) u32 {
        const sz = canvas_data_offset + @as(u32, w) * h * 2;
        const canvas = app_malloc(ctx, sz);
        if (canvas == 0) return 0;
        self.writeSignature(canvas, w, h);
        // offset field (frame_property+16) = image size
        self.mem.writeU32(canvas + 12 + 16, @as(u32, w) * h * 2);
        return canvas;
    }

    pub fn canvasSetTransColor(self: *Graphics, canvas: u32, trans: u16) i32 {
        const cs = self.signatureAddr(canvas) orelse return -1;
        const fp = cs + 12;
        const old_flag = self.mem.buf[fp + fp_flag] != 0;
        const old_trans = self.mem.readU16(fp + fp_trans_color);
        // Our image loader marks alpha-transparent pixels with `trans_sentinel`
        // (magenta) and keys on it. If a game overrides the key with a different
        // color (e.g. Adam n Eve sets black), those sentinel pixels would no
        // longer match the key and would render as opaque magenta. Migrate them
        // to the new key so they stay transparent.
        if (old_flag and old_trans == trans_sentinel and trans != trans_sentinel) {
            const w = self.mem.readU16(fp + fp_width);
            const h = self.mem.readU16(fp + fp_height);
            const pixels = cs + canvas_data_offset;
            var i: u32 = 0;
            const n: u32 = @as(u32, w) * h;
            while (i < n) : (i += 1) {
                if (self.mem.readU16(pixels + i * 2) == trans_sentinel)
                    self.mem.writeU16(pixels + i * 2, trans);
            }
        }
        self.mem.buf[fp + fp_flag] = 1;
        self.mem.writeU16(fp + fp_trans_color, trans);
        return 0;
    }

    // --- text rendering (uses embedded unifont) ------------------------------

    const font = @embedFile("assets/unifont.bin");

    fn glyphOffset(c: u16) u32 {
        const idx = @as(u32, c) * 4;
        if (idx + 4 > font.len) return 0;
        return std.mem.readInt(u32, font[idx..][0..4], .little);
    }

    pub fn charWidth(c: u16) i32 {
        if (c < 0x20) return 0; // control chars are not printable (match textout)
        const off = glyphOffset(c);
        if (off == 0 or off >= font.len) return 0;
        return @as(i32, font[off] & 0xF) + 1;
    }

    pub fn charHeight() i32 {
        return 16;
    }

    /// Baseline (ascent) of the 16px bitmap font: the row, measured from the glyph
    /// top, on which characters sit. Used by vm_graphic_get_string_baseline.
    pub fn charBaseline() i32 {
        return 13;
    }

    /// Reads a UCS2-LE string from guest memory and sums widths.
    pub fn stringWidth(self: *Graphics, str_emu: u32) i32 {
        var w: i32 = 0;
        var p = str_emu;
        while (true) {
            const c = self.mem.readU16(p);
            if (c == 0) break;
            w += charWidth(c);
            p += 2;
        }
        return w + 1;
    }

    pub fn textout(self: *Graphics, buf: u32, x: i32, y: i32, str_emu: u32, length: i32, color: u16) void {
        const c = self.findCanvas(buf) orelse return;
        var bnds = [4]i32{ 0, 0, c.w, c.h };
        if (self.clip.flag) {
            bnds[0] = @max(bnds[0], self.clip.left);
            bnds[1] = @max(bnds[1], self.clip.top);
            bnds[2] = @min(bnds[2], self.clip.right + 1);
            bnds[3] = @min(bnds[3], self.clip.bottom + 1);
        }
        const st_y = @max(bnds[1], y);
        const end_y = @min(bnds[3], y + 16);

        var x_off = x;
        var i: i32 = 0;
        var p = str_emu;
        while (length < 0 or i < length) : (i += 1) {
            const ch = self.mem.readU16(p);
            if (ch == 0) break;
            p += 2;
            if (ch < 0x20) continue; // C0 control chars (CR/LF/…) are not printable
            const off = glyphOffset(ch);
            if (off == 0 or off + 2 >= font.len) {
                continue;
            }
            const ch_w: i32 = font[off] & 0xF;
            const wide = ch_w >= 8;
            if (x_off >= bnds[2]) break;
            if (x_off + ch_w < bnds[0]) {
                x_off += ch_w + 1;
                continue;
            }
            const st_x = @max(bnds[0], x_off);
            const end_x = @min(bnds[2], x_off + ch_w + 1);
            var sy = st_y;
            while (sy < end_y) : (sy += 1) {
                const ty: u32 = @intCast(sy - y);
                var lineb: u16 = 0;
                if (wide) {
                    const o = off + 2 + ty * 2;
                    if (o + 1 < font.len) lineb = (@as(u16, font[o]) << 8) | font[o + 1];
                } else {
                    const o = off + 2 + ty;
                    if (o < font.len) lineb = @as(u16, font[o]) << 8;
                }
                var sx = st_x;
                while (sx < end_x) : (sx += 1) {
                    const im_x: u4 = @intCast(@as(u32, @intCast(sx - x_off)) & 0xF);
                    if ((lineb >> (15 - im_x)) & 1 != 0)
                        self.putPixel(c, sx, sy, color);
                }
            }
            x_off += ch_w + 1;
        }
    }

    // --- _ex helpers operating on the active layer + global color ------------

    pub fn activeBuf(self: *Graphics, handle: i32) ?u32 {
        // A negative handle (commonly -1) means "the current active layer".
        const idx: usize = if (handle < 0) self.active_layer else @intCast(handle);
        if (idx >= self.layer_count) return null;
        return self.layers[idx].buf;
    }
};
