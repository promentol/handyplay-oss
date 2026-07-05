//! ExEn PNG-chunk parser + codec-5 IDAT decoder.
//! Copied from `../extract_pngs.zig` because Zig 0.15 forbids cross-module
//! imports. Keep these two implementations in sync.

const std = @import("std");
const codec = @import("codec_1to5.zig");

const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

const IHDR: u32 = 0x49484452;
const PLTE: u32 = 0x504c5445;
const tRNS: u32 = 0x74524e53;
const IDAT: u32 = 0x49444154;

pub const ParsedPng = struct {
    offset: usize,
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    palette: ?[]const u8 = null,
    trns: ?[]const u8 = null,
    idat: []const u8,
};

pub const ParseError = error{ Truncated, NotIhdr, MissingIdat, BadType };

fn isAsciiType(t: u32) bool {
    var i: u5 = 0;
    while (i < 4) : (i += 1) {
        const c: u8 = @truncate(t >> (24 - @as(u5, i) * 8));
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) return false;
    }
    return true;
}

pub fn parsePng(buf: []const u8, sig_off: usize) ParseError!ParsedPng {
    var info: ParsedPng = .{
        .offset = sig_off,
        .width = 0,
        .height = 0,
        .bit_depth = 0,
        .color_type = 0,
        .idat = &.{},
    };
    var off = sig_off + png_sig.len;
    var saw_ihdr = false;
    var saw_idat = false;
    var safety: usize = 0;
    while (off + 8 <= buf.len) : (safety += 1) {
        if (safety > 32) return error.BadType;
        const len = std.mem.readInt(u32, buf[off..][0..4], .big);
        const t = std.mem.readInt(u32, buf[off + 4 ..][0..4], .big);
        if (!isAsciiType(t)) return error.BadType;
        const data_start = off + 8;
        const data_end = data_start + len;
        if (data_end > buf.len) return error.Truncated;
        const data = buf[data_start..data_end];
        switch (t) {
            IHDR => {
                if (data.len < 13) return error.NotIhdr;
                info.width = std.mem.readInt(u32, data[0..4], .big);
                info.height = std.mem.readInt(u32, data[4..8], .big);
                info.bit_depth = data[8];
                info.color_type = data[9];
                saw_ihdr = true;
            },
            PLTE => info.palette = data,
            tRNS => info.trns = data,
            IDAT => {
                info.idat = data;
                saw_idat = true;
            },
            else => {},
        }
        off = data_end;
        if (t == IDAT) break;
    }
    if (!saw_ihdr) return error.NotIhdr;
    if (!saw_idat) return error.MissingIdat;
    return info;
}

pub const Decoded = struct {
    width: u32,
    height: u32,
    pixels: []u32, // ABGR8888 (LE byte order R G B A)
    indices: []u8 = &.{}, // one source palette index per pixel
};

/// Decode a PNG section (at `sig_off`) into an ABGR8888 pixel buffer.
/// Supports color_type 3 (indexed) with bit_depth 4 or 8 — the formats
/// ExEn gamelets use. Returns a buffer the caller owns.
pub fn decodePngToAbgr(allocator: std.mem.Allocator, buf: []const u8, sig_off: usize) !Decoded {
    const info = try parsePng(buf, sig_off);
    if (info.color_type != 3) return error.UnsupportedColorType;
    if (info.bit_depth != 4 and info.bit_depth != 8) return error.UnsupportedColorType;
    const plte = info.palette orelse return error.MissingPalette;

    // Codec dispatch — see sub_432E50 in ref. The high nibble
    // of IDAT byte 0 selects the decoder.
    if (info.idat.len == 0) return error.IdatTooShort;
    const codec_id: u8 = info.idat[0] >> 4;
    const raw = switch (codec_id) {
        1 => codec.decodeCodec1(allocator, info.idat) catch return error.UnsupportedCodec,
        2 => codec.decodeCodec2(allocator, info.idat) catch return error.UnsupportedCodec,
        3 => codec.decodeCodec3(allocator, info.idat) catch return error.UnsupportedCodec,
        4 => codec.decodeCodec4(allocator, info.idat) catch return error.UnsupportedCodec,
        5 => try decodeCodec5(allocator, info.idat),
        else => return error.UnsupportedCodec,
    };
    defer allocator.free(raw);

    // `decodeCodec5` produces the un-filtered scanline payload
    // directly (no per-row filter bytes — see extract_pngs.zig where
    // it copies indexed rows verbatim into a standard IDAT stream).
    const bytes_per_row: usize = (@as(usize, info.width) * info.bit_depth + 7) / 8;
    if (raw.len < bytes_per_row * info.height) return error.IdatTooShort;

    const npix = @as(usize, info.width) * info.height;
    const pixels = try allocator.alloc(u32, npix);
    errdefer allocator.free(pixels);
    // Per-pixel source palette index — retained so index-based transparency
    // (Image.setTransparentColor / setPaletteAlpha → Graphics.drawImage /
    // AnimBitmap.draw) can skip the transparent index on PNG-decoded images.
    const indices = try allocator.alloc(u8, npix);
    errdefer allocator.free(indices);

    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        const row_off = @as(usize, y) * bytes_per_row;
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const ix: u8 = if (info.bit_depth == 8)
                raw[row_off + x]
            else // 4bpp: 2 nibbles per byte, high nibble first
                (raw[row_off + x / 2] >> (4 - 4 * @as(u3, @intCast(x & 1)))) & 0x0F;
            indices[@as(usize, y) * info.width + x] = ix;
            const p_off = @as(usize, ix) * 3;
            const r: u32 = if (p_off + 2 < plte.len) plte[p_off] else 0;
            const g: u32 = if (p_off + 2 < plte.len) plte[p_off + 1] else 0;
            const b: u32 = if (p_off + 2 < plte.len) plte[p_off + 2] else 0;
            const a: u32 = if (info.trns) |trns|
                (if (ix < trns.len) @as(u32, trns[ix]) else 0xFF)
            else
                0xFF;
            pixels[@as(usize, y) * info.width + x] = (a << 24) | (b << 16) | (g << 8) | r;
        }
    }

    return .{ .width = info.width, .height = info.height, .pixels = pixels, .indices = indices };
}

/// Port of sub_432A76 in ref (ExEn LZSS-variant for IDAT codec 5).
pub fn decodeCodec5(allocator: std.mem.Allocator, idat: []const u8) ![]u8 {
    if (idat.len < 13) return error.IdatTooShort;
    const out_size: u32 =
        @as(u32, idat[9]) |
        (@as(u32, idat[10]) << 8) |
        (@as(u32, idat[11]) << 16);
    const out = try allocator.alloc(u8, out_size);
    errdefer allocator.free(out);

    var src: usize = 13;
    var dst: usize = 0;

    while (dst < out_size) {
        if (src + 4 > idat.len) return error.UnexpectedEof;
        var ctrl: u32 =
            (@as(u32, idat[src]) << 24) |
            (@as(u32, idat[src + 1]) << 16) |
            (@as(u32, idat[src + 2]) << 8) |
            @as(u32, idat[src + 3]);
        src += 4;
        const mode: u5 = @intCast(ctrl & 3);
        const shift: u5 = 14 - mode;
        const mask: u32 = @as(u32, 0x3FFF) >> mode;

        var i: u32 = 0;
        while (i < 30) : (i += 1) {
            if ((ctrl & 0x8000_0000) == 0) {
                if (src >= idat.len) return error.UnexpectedEof;
                out[dst] = idat[src];
                src += 1;
                dst += 1;
            } else {
                if (src + 2 > idat.len) return error.UnexpectedEof;
                const w: u32 =
                    (@as(u32, idat[src]) << 8) |
                    @as(u32, idat[src + 1]);
                src += 2;
                var run_len: u32 = (w >> shift) + 3;
                const dist: u32 = (w & mask) + 1;
                if (dst + run_len > out_size) run_len = out_size - @as(u32, @intCast(dst));
                if (dist > dst) return error.InvalidBackref;
                var j: u32 = 0;
                while (j < run_len) : (j += 1) {
                    out[dst] = out[dst - dist];
                    dst += 1;
                }
            }
            if (dst >= out_size) return out;
            ctrl <<= 1;
        }
    }
    return out;
}
