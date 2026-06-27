//! Decode a gamelet's image section into an RGBA8888 framebuffer suitable for
//! upload to SDL3's `SDL_PIXELFORMAT_ABGR8888` (memory order R, G, B, A).
//!
//! Reuses the codec-5 LZSS decoder from `../extract_pngs.zig`. Image sections
//! in `.exn` files have a 6-byte ExEn prefix `(u16 width, u16 height, u16 ?)`,
//! then a standard PNG signature + chunks (no trailing CRC, no IEND).

const std = @import("std");
const png = @import("codecs/png.zig");
const exn = @import("exn/loader.zig");

pub const Error = error{
    NotAnImage,
    UnsupportedCodec,
    UnsupportedBitDepth,
    EmptyIdat,
    NoPalette,
    PaletteOverflow,
    DimensionMismatch,
};

pub const DecodedImage = struct {
    width: u32,
    height: u32,
    rgba: []u32, // length = width * height; SDL_PIXELFORMAT_ABGR8888
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.rgba);
    }
};

/// Decode the image at `section` (must have `kind == .image`).
pub fn decodeImage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    section: exn.SectionInfo,
) !DecodedImage {
    if (section.kind != .image) return Error.NotAnImage;
    const sig_off = @as(usize, section.offset) + 6;
    const info = try png.parsePng(raw, sig_off);

    if (info.idat.len < 1) return Error.EmptyIdat;
    const codec: u8 = info.idat[0] >> 4;
    if (codec != 5) return Error.UnsupportedCodec;

    const indexed = try png.decodeCodec5(allocator, info.idat);
    defer allocator.free(indexed);

    const palette = info.palette orelse return Error.NoPalette;
    const trns = info.trns;

    const total_px = @as(usize, info.width) * @as(usize, info.height);
    const rgba = try allocator.alloc(u32, total_px);
    errdefer allocator.free(rgba);

    switch (info.bit_depth) {
        8 => {
            if (indexed.len < total_px) return Error.DimensionMismatch;
            for (rgba, 0..) |*dst, i| {
                dst.* = paletteLookup(palette, trns, indexed[i]) catch return Error.PaletteOverflow;
            }
        },
        4 => {
            // Two pixels per byte, high nibble first. Rows are byte-aligned;
            // odd-width rows have an unused low nibble in the last byte.
            const bytes_per_row: usize = (@as(usize, info.width) + 1) / 2;
            if (indexed.len < bytes_per_row * info.height) return Error.DimensionMismatch;
            var y: u32 = 0;
            while (y < info.height) : (y += 1) {
                const row_in = indexed[y * bytes_per_row ..][0..bytes_per_row];
                const row_out = rgba[y * info.width ..][0..info.width];
                var x: u32 = 0;
                while (x < info.width) : (x += 1) {
                    const byte = row_in[x / 2];
                    const idx: u8 = if ((x & 1) == 0) (byte >> 4) & 0x0F else byte & 0x0F;
                    row_out[x] = paletteLookup(palette, trns, idx) catch return Error.PaletteOverflow;
                }
            }
        },
        else => return Error.UnsupportedBitDepth,
    }

    return .{
        .width = info.width,
        .height = info.height,
        .rgba = rgba,
        .allocator = allocator,
    };
}

fn paletteLookup(palette: []const u8, trns: ?[]const u8, idx: u8) Error!u32 {
    const pal_off = @as(usize, idx) * 3;
    if (pal_off + 3 > palette.len) return Error.PaletteOverflow;
    const r = palette[pal_off];
    const g = palette[pal_off + 1];
    const b = palette[pal_off + 2];
    const a: u8 = if (trns) |t| (if (idx < t.len) t[idx] else 0xFF) else 0xFF;
    // SDL_PIXELFORMAT_ABGR8888 on little-endian: byte order R G B A → u32 value
    // (A << 24) | (B << 16) | (G << 8) | R.
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}

test "decode TheTerminator.exn section 1 (if present)" {
    var loaded = exn.load(std.testing.allocator, "TheTerminator.exn") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer loaded.deinit();

    var layout = try exn.parseLayout(std.testing.allocator, loaded.raw);
    defer layout.deinit();

    // Find the first image section.
    var img_section: ?exn.SectionInfo = null;
    for (layout.sections) |s| {
        if (s.kind == .image) {
            img_section = s;
            break;
        }
    }
    try std.testing.expect(img_section != null);

    var decoded = try decodeImage(std.testing.allocator, loaded.raw, img_section.?);
    defer decoded.deinit();

    // Confirm sizes match the 6-byte ExEn prefix at section start.
    const prefix_w = std.mem.readInt(u16, loaded.raw[img_section.?.offset..][0..2], .little);
    const prefix_h = std.mem.readInt(u16, loaded.raw[img_section.?.offset + 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u32, prefix_w), decoded.width);
    try std.testing.expectEqual(@as(u32, prefix_h), decoded.height);
    try std.testing.expectEqual(@as(usize, prefix_w) * prefix_h, decoded.rgba.len);

    // At least one non-transparent pixel.
    var saw_opaque = false;
    for (decoded.rgba) |px| {
        if ((px >> 24) != 0) {
            saw_opaque = true;
            break;
        }
    }
    try std.testing.expect(saw_opaque);
}
