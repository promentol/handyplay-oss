//! Minimal GIF decoder -> RGBA8888 (first frame). Handles the global/local color
//! tables, the Graphic Control Extension transparent index, and LZW decompression.
//! MRE games commonly store sprites as single-frame GIFs.
const std = @import("std");

pub const Image = struct { w: u32, h: u32, rgba: []u8 };
pub const Error = error{ NotGif, Bad, OutOfMemory };

pub fn decode(gpa: std.mem.Allocator, buf: []const u8) Error!Image {
    if (buf.len < 13 or !(std.mem.eql(u8, buf[0..6], "GIF87a") or std.mem.eql(u8, buf[0..6], "GIF89a")))
        return Error.NotGif;

    const scr_w = rd16(buf, 6);
    const scr_h = rd16(buf, 8);
    const packed_lsd = buf[10];
    var off: usize = 13;

    var gct: []const u8 = &.{};
    if (packed_lsd & 0x80 != 0) {
        const n = @as(usize, 2) << @intCast(packed_lsd & 7);
        if (off + n * 3 > buf.len) return Error.Bad;
        gct = buf[off .. off + n * 3];
        off += n * 3;
    }

    var transparent: i32 = -1;

    while (off < buf.len) {
        const b = buf[off];
        if (b == 0x3B) break; // trailer
        if (b == 0x21) { // extension
            if (off + 2 > buf.len) return Error.Bad;
            const label = buf[off + 1];
            off += 2;
            if (label == 0xF9 and off < buf.len and buf[off] >= 4) {
                const flags = buf[off + 1];
                if (flags & 1 != 0) transparent = buf[off + 4];
            }
            off = skipSubBlocks(buf, off);
            continue;
        }
        if (b == 0x2C) { // image descriptor
            if (off + 10 > buf.len) return Error.Bad;
            const fx = rd16(buf, off + 1);
            const fy = rd16(buf, off + 3);
            const fw = rd16(buf, off + 5);
            const fh = rd16(buf, off + 7);
            const packed_id = buf[off + 9];
            off += 10;

            var ct = gct;
            if (packed_id & 0x80 != 0) {
                const n = @as(usize, 2) << @intCast(packed_id & 7);
                if (off + n * 3 > buf.len) return Error.Bad;
                ct = buf[off .. off + n * 3];
                off += n * 3;
            }
            if (off >= buf.len) return Error.Bad;
            const min_code = buf[off];
            off += 1;

            // gather LZW sub-block data
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(gpa);
            while (off < buf.len) {
                const blk = buf[off];
                off += 1;
                if (blk == 0) break;
                if (off + blk > buf.len) return Error.Bad;
                try data.appendSlice(gpa, buf[off .. off + blk]);
                off += blk;
            }

            const indices = try gpa.alloc(u8, @as(usize, fw) * fh);
            defer gpa.free(indices);
            lzw(min_code, data.items, indices);

            // De-interlace: an interlaced GIF stores rows in 4 passes (starts
            // 0,4,2,1 with steps 8,8,4,2). LZW yields them in that pass order, so
            // remap to sequential rows — otherwise the image renders as a repeated
            // vertical smear.
            if (packed_id & 0x40 != 0 and fh > 0 and fw > 0) {
                const tmp = try gpa.alloc(u8, @as(usize, fw) * fh);
                defer gpa.free(tmp);
                @memcpy(tmp, indices);
                const passes = [_][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
                var decoded_row: u32 = 0;
                for (passes) |ps| {
                    var ay: u32 = ps[0];
                    while (ay < fh) : (ay += ps[1]) {
                        @memcpy(
                            indices[@as(usize, ay) * fw ..][0..fw],
                            tmp[@as(usize, decoded_row) * fw ..][0..fw],
                        );
                        decoded_row += 1;
                    }
                }
            }

            // Compose into logical-screen-sized RGBA (transparent outside frame).
            const rgba = try gpa.alloc(u8, @as(usize, scr_w) * scr_h * 4);
            errdefer gpa.free(rgba);
            @memset(rgba, 0);
            var yy: u32 = 0;
            while (yy < fh) : (yy += 1) {
                var xx: u32 = 0;
                while (xx < fw) : (xx += 1) {
                    const sx = fx + xx;
                    const sy = fy + yy;
                    if (sx >= scr_w or sy >= scr_h) continue;
                    const idx = indices[yy * fw + xx];
                    const o = (@as(usize, sy) * scr_w + sx) * 4;
                    const pi = @as(usize, idx) * 3;
                    if (pi + 2 < ct.len) {
                        rgba[o] = ct[pi];
                        rgba[o + 1] = ct[pi + 1];
                        rgba[o + 2] = ct[pi + 2];
                    }
                    rgba[o + 3] = if (transparent >= 0 and idx == transparent) 0 else 255;
                }
            }
            return .{ .w = scr_w, .h = scr_h, .rgba = rgba };
        }
        off += 1; // unknown byte, skip
    }
    return Error.Bad;
}

fn skipSubBlocks(buf: []const u8, start: usize) usize {
    var off = start;
    while (off < buf.len) {
        const len = buf[off];
        off += 1;
        if (len == 0) break;
        off += len;
    }
    return off;
}

/// Stack-based GIF LZW decode into `out` (truncates/zero-fills to out.len).
fn lzw(min_code: u8, data: []const u8, out: []u8) void {
    const clear: u16 = @as(u16, 1) << @intCast(min_code);
    const end: u16 = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;

    var i: u16 = 0;
    while (i < clear) : (i += 1) {
        prefix[i] = 0xFFFF;
        suffix[i] = @intCast(i);
    }

    var code_size: u5 = @intCast(min_code + 1);
    var next_code: u16 = end + 1;
    var prev: u16 = 0xFFFF;
    var first: u8 = 0;

    var bitbuf: u32 = 0;
    var bitcnt: u5 = 0;
    var pos: usize = 0;
    var outp: usize = 0;

    while (outp < out.len) {
        // read `code_size` bits, LSB-first
        while (bitcnt < code_size) {
            if (pos >= data.len) return;
            bitbuf |= @as(u32, data[pos]) << bitcnt;
            pos += 1;
            bitcnt += 8;
        }
        const code: u16 = @intCast(bitbuf & ((@as(u32, 1) << code_size) - 1));
        bitbuf >>= code_size;
        bitcnt -= code_size;

        if (code == clear) {
            code_size = @intCast(min_code + 1);
            next_code = end + 1;
            prev = 0xFFFF;
            continue;
        }
        if (code == end) return;

        var sp: usize = 0;
        var cur = code;
        if (prev == 0xFFFF) {
            first = suffix[code];
            out[outp] = first;
            outp += 1;
            prev = code;
            continue;
        }
        if (cur >= next_code) {
            stack[sp] = first;
            sp += 1;
            cur = prev;
        }
        while (cur >= clear) {
            stack[sp] = suffix[cur];
            sp += 1;
            cur = prefix[cur];
            if (sp >= stack.len) break;
        }
        first = suffix[cur];
        stack[sp] = first;
        sp += 1;
        // emit reversed
        while (sp > 0 and outp < out.len) {
            sp -= 1;
            out[outp] = stack[sp];
            outp += 1;
        }
        if (next_code < 4096) {
            prefix[next_code] = prev;
            suffix[next_code] = first;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @as(u4, @intCast(code_size))) and code_size < 12) code_size += 1;
        }
        prev = code;
    }
}

fn rd16(buf: []const u8, o: usize) u16 {
    return @as(u16, buf[o]) | (@as(u16, buf[o + 1]) << 8);
}

test "decode tiny gif" {
    const data = @embedFile("test2x2.gif");
    const img = try decode(std.testing.allocator, data);
    defer std.testing.allocator.free(img.rgba);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqual(@as(u32, 2), img.h);
    // palette: 0=red,1=green,2=blue,3=white ; pixels TL=0,TR=1,BL=2,BR=3
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, img.rgba[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.rgba[8..12]);
}
