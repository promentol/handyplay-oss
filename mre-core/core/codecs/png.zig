//! Minimal standard PNG decoder -> RGBA8888. Supports non-interlaced images with
//! bit depths 1/2/4/8 and color types 0 (gray), 2 (RGB), 3 (palette), 4 (gray+A),
//! 6 (RGBA). Used by vm_graphic_load_image_FIX. (Distinct from exen-player2's
//! codec-5 PNG variant; this inflates the standard zlib IDAT stream.)
const std = @import("std");

const sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8, // w*h*4, owned by caller's allocator
};

pub const Error = error{ NotPng, Bad, Unsupported, OutOfMemory, Inflate };

pub fn decode(gpa: std.mem.Allocator, buf: []const u8) Error!Image {
    if (buf.len < 8 or !std.mem.eql(u8, buf[0..8], &sig)) return Error.NotPng;

    var w: u32 = 0;
    var h: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var off: usize = 8;
    while (off + 8 <= buf.len) {
        const len = std.mem.readInt(u32, buf[off..][0..4], .big);
        const ctype = buf[off + 4 .. off + 8];
        const data_start = off + 8;
        if (data_start + len + 4 > buf.len) return Error.Bad;
        const data = buf[data_start .. data_start + len];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len < 13) return Error.Bad;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            bit_depth = data[8];
            color_type = data[9];
            interlace = data[12];
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        off = data_start + len + 4; // skip data + CRC
    }

    if (w == 0 or h == 0) return Error.Bad;
    if (interlace != 0) return Error.Unsupported;
    if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8) return Error.Unsupported;

    const channels: u32 = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return Error.Unsupported,
    };
    const bits_pp = channels * bit_depth;
    const stride = (w * bits_pp + 7) / 8;
    const filt_bpp = @max(@as(u32, 1), bits_pp / 8);

    // Inflate the zlib IDAT stream into raw filtered scanlines.
    const raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    {
        var in = std.Io.Reader.fixed(idat.items);
        var out = std.Io.Writer.fixed(raw);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
        _ = d.reader.streamRemaining(&out) catch return Error.Inflate;
    }

    // Unfilter in place into a contiguous w*stride buffer.
    const recon = try gpa.alloc(u8, stride * h);
    defer gpa.free(recon);
    @memset(recon, 0);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const cur = recon[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) recon[(y - 1) * stride ..][0..stride] else null;
        unfilter(filter, src, cur, prev, filt_bpp);
    }

    // Expand to RGBA8888.
    const rgba = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(rgba);
    expand(rgba, recon, w, h, stride, bit_depth, color_type, palette, trns);

    return .{ .w = w, .h = h, .rgba = rgba };
}

fn unfilter(filter: u8, src: []const u8, cur: []u8, prev: ?[]const u8, bpp: u32) void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const x = src[i];
        const a: u32 = if (i >= bpp) cur[i - bpp] else 0;
        const b: u32 = if (prev) |p| p[i] else 0;
        const cc: u32 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        cur[i] = switch (filter) {
            0 => x,
            1 => @truncate(@as(u32, x) + a),
            2 => @truncate(@as(u32, x) + b),
            3 => @truncate(@as(u32, x) + (a + b) / 2),
            4 => @truncate(@as(u32, x) + paeth(a, b, cc)),
            else => x,
        };
    }
}

fn paeth(a: u32, b: u32, c: u32) u32 {
    const p = @as(i32, @intCast(a)) + @as(i32, @intCast(b)) - @as(i32, @intCast(c));
    const pa = @abs(p - @as(i32, @intCast(a)));
    const pb = @abs(p - @as(i32, @intCast(b)));
    const pc = @abs(p - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sampleAt(row: []const u8, x: u32, bit_depth: u8, channel: u32, channels: u32) u8 {
    if (bit_depth == 8) return row[x * channels + channel];
    // sub-byte samples (palette/grayscale): channel is always 0 here
    const bits = bit_depth;
    const idx = x; // single channel
    const per_byte = @as(u32, 8) / bits;
    const byte = row[idx / per_byte];
    const shift: u3 = @intCast((per_byte - 1 - (idx % per_byte)) * bits);
    const mask: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
    return (byte >> shift) & mask;
}

fn scale(val: u8, bit_depth: u8) u8 {
    return switch (bit_depth) {
        1 => if (val != 0) 255 else 0,
        2 => val * 85,
        4 => val * 17,
        else => val,
    };
}

test "decode 2x2 RGBA png" {
    const data = @embedFile("test2x2.png");
    const img = try decode(std.testing.allocator, data);
    defer std.testing.allocator.free(img.rgba);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqual(@as(u32, 2), img.h);
    // (0,0) red, (1,0) green, (0,1) blue, (1,1) white alpha=0
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, img.rgba[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.rgba[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, img.rgba[12..16]);
}

fn expand(rgba: []u8, recon: []const u8, w: u32, h: u32, stride: u32, bit_depth: u8, color_type: u8, palette: []const u8, trns: []const u8) void {
    const channels: u32 = switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => 1,
    };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = recon[y * stride ..][0..stride];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 255;
            switch (color_type) {
                0 => { // grayscale
                    const gv = scale(sampleAt(row, x, bit_depth, 0, 1), bit_depth);
                    r = gv;
                    g = gv;
                    b = gv;
                },
                2 => { // RGB (bit_depth 8)
                    r = row[x * 3 + 0];
                    g = row[x * 3 + 1];
                    b = row[x * 3 + 2];
                },
                3 => { // palette
                    const idx = sampleAt(row, x, bit_depth, 0, 1);
                    const pi = @as(u32, idx) * 3;
                    if (pi + 2 < palette.len) {
                        r = palette[pi];
                        g = palette[pi + 1];
                        b = palette[pi + 2];
                    }
                    if (idx < trns.len) a = trns[idx];
                },
                4 => { // gray + alpha (bit_depth 8)
                    r = row[x * 2];
                    g = r;
                    b = r;
                    a = row[x * 2 + 1];
                },
                6 => { // RGBA (bit_depth 8)
                    r = row[x * 4 + 0];
                    g = row[x * 4 + 1];
                    b = row[x * 4 + 2];
                    a = row[x * 4 + 3];
                },
                else => {},
            }
            _ = channels;
            rgba[o + 0] = r;
            rgba[o + 1] = g;
            rgba[o + 2] = b;
            rgba[o + 3] = a;
        }
    }
}
