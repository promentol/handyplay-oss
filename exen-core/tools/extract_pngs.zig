//! Extract PNGs from an ExEn .exn flash image.
//!
//! ExEn storage format (deduced from ref sub_41DACD + sub_432E50):
//!   - 8-byte PNG signature
//!   - chunks: length(4 BE) + type(4) + data(length). NO trailing CRC.
//!   - no IEND chunk; the decoder returns right after IDAT.
//!   - IHDR.compression == 1 (not 0/deflate).
//!   - IDAT body uses one of 5 custom codecs. High nibble of IDAT[0] picks
//!     the codec (1..5). This program currently implements codec 5 only
//!     (sub_432A00, an LZSS variant).
//!
//! Output is a standard paletted PNG: IHDR (compression=0) + PLTE + optional
//! tRNS + IDAT (zlib stored block of filter-zero rows) + IEND, with proper
//! per-chunk CRC32.

const std = @import("std");
const codec = @import("../core/codecs/codec_1to5.zig");

const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

const IHDR: u32 = 0x49484452;
const PLTE: u32 = 0x504c5445;
const tRNS: u32 = 0x74524e53;
const IDAT: u32 = 0x49444154;
const IEND: u32 = 0x49454e44;

const Chunk = struct {
    type: u32,
    data: []const u8,
};

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

pub const png_signature = png_sig;

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

/// Port of sub_432A76 in ref.
/// 32-bit BE control word; bottom 2 bits configure back-ref length/distance
/// split; top 30 bits each select literal (0) or 16-bit BE back-ref (1).
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

/// Append a PNG chunk (length, type, data, CRC) to `list`.
fn writeChunk(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    chunk_type: u32,
    data: []const u8,
) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    var type_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &type_bytes, chunk_type, .big);

    var crc = std.hash.Crc32.init();
    crc.update(&type_bytes);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);

    try list.appendSlice(allocator, &len_bytes);
    try list.appendSlice(allocator, &type_bytes);
    try list.appendSlice(allocator, data);
    try list.appendSlice(allocator, &crc_bytes);
}

/// Build a zlib stream containing a single uncompressed (stored) deflate
/// block. PNG decoders accept this just fine.
fn buildZlibStored(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]u8 {
    // 1 stored deflate block can hold up to 65535 bytes. None of the ExEn
    // images approach that, so a single block is enough.
    std.debug.assert(payload.len <= 0xFFFF);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // zlib header: CMF=0x78 (deflate, 32K window), FLG chosen so FCHECK works.
    // (0x78 << 8 | FLG) must be a multiple of 31. FLG=0x01 → 0x7801. ✓
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });

    // Stored block: 1 byte header (BFINAL=1, BTYPE=00), LEN (LE), NLEN (LE), data.
    try out.append(allocator, 0x01);
    var len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_bytes, @intCast(payload.len), .little);
    var nlen_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &nlen_bytes, ~@as(u16, @intCast(payload.len)), .little);
    try out.appendSlice(allocator, &len_bytes);
    try out.appendSlice(allocator, &nlen_bytes);
    try out.appendSlice(allocator, payload);

    // Adler-32 of the uncompressed payload, big-endian.
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, std.hash.Adler32.hash(payload), .big);
    try out.appendSlice(allocator, &adler_bytes);

    return try out.toOwnedSlice(allocator);
}

fn encodePng(
    allocator: std.mem.Allocator,
    info: ParsedPng,
    indexed: []const u8,
) ![]u8 {
    const bytes_per_row: u32 = if (info.bit_depth == 4)
        (info.width + 1) / 2
    else
        info.width;
    if (indexed.len != bytes_per_row * info.height) return error.SizeMismatch;

    // Build the raw IDAT pre-deflate payload: filter byte (0) + row bytes,
    // for each row.
    const raw_idat_len: usize = (@as(usize, bytes_per_row) + 1) * info.height;
    const raw_idat = try allocator.alloc(u8, raw_idat_len);
    defer allocator.free(raw_idat);
    var w: usize = 0;
    var r: usize = 0;
    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        raw_idat[w] = 0; // filter: None
        w += 1;
        @memcpy(raw_idat[w .. w + bytes_per_row], indexed[r .. r + bytes_per_row]);
        w += bytes_per_row;
        r += bytes_per_row;
    }

    const zlib_data = try buildZlibStored(allocator, raw_idat);
    defer allocator.free(zlib_data);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &png_sig);

    // IHDR: rewrite with compression=0 (standard deflate).
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], info.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], info.height, .big);
    ihdr[8] = info.bit_depth;
    ihdr[9] = info.color_type;
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(&out, allocator, IHDR, &ihdr);

    if (info.palette) |plte| try writeChunk(&out, allocator, PLTE, plte);
    if (info.trns) |trns| try writeChunk(&out, allocator, tRNS, trns);
    try writeChunk(&out, allocator, IDAT, zlib_data);
    try writeChunk(&out, allocator, IEND, &.{});

    return try out.toOwnedSlice(allocator);
}

fn findAllSignatures(buf: []const u8, allocator: std.mem.Allocator) ![]usize {
    var hits: std.ArrayListUnmanaged(usize) = .empty;
    defer hits.deinit(allocator);
    var i: usize = 0;
    while (i + png_sig.len <= buf.len) {
        if (std.mem.eql(u8, buf[i .. i + png_sig.len], &png_sig)) {
            try hits.append(allocator, i);
            i += 1;
        } else {
            i += 1;
        }
    }
    return try hits.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse "TheTerminator.exn";
    const out_dir_path = args.next() orelse "extracted_pngs";

    const cwd = std.fs.cwd();
    const buf = try cwd.readFileAlloc(allocator, input_path, 64 * 1024 * 1024);
    defer allocator.free(buf);

    try cwd.makePath(out_dir_path);
    var out_dir = try cwd.openDir(out_dir_path, .{});
    defer out_dir.close();

    const offsets = try findAllSignatures(buf, allocator);
    defer allocator.free(offsets);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_file_writer.interface;

    const stem = std.fs.path.stem(input_path);

    var written: usize = 0;
    var skipped_codec: usize = 0;
    var skipped_parse: usize = 0;
    for (offsets, 0..) |off, idx| {
        const info = parsePng(buf, off) catch {
            skipped_parse += 1;
            continue;
        };
        if (info.idat.len == 0) {
            skipped_parse += 1;
            continue;
        }
        const codec_id: u8 = info.idat[0] >> 4;
        const indexed_opt: ?[]u8 = switch (codec_id) {
            1 => codec.decodeCodec1(allocator, info.idat) catch null,
            2 => codec.decodeCodec2(allocator, info.idat) catch null,
            3 => codec.decodeCodec3(allocator, info.idat) catch null,
            4 => codec.decodeCodec4(allocator, info.idat) catch null,
            5 => decodeCodec5(allocator, info.idat) catch null,
            else => null,
        };
        if (indexed_opt == null) {
            try stdout.print(
                "  #{d:>2} 0x{x:0>5} {d}x{d} bpp={d} codec={d}  (decode failed)\n",
                .{ idx, off, info.width, info.height, info.bit_depth, codec_id },
            );
            skipped_codec += 1;
            continue;
        }
        const indexed = indexed_opt.?;
        defer allocator.free(indexed);

        const png_bytes = try encodePng(allocator, info, indexed);
        defer allocator.free(png_bytes);

        var name_buf: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buf,
            "{s}_{d:0>3}_{d}x{d}_at_0x{x}.png",
            .{ stem, idx, info.width, info.height, off },
        );

        var out_file = try out_dir.createFile(name, .{});
        defer out_file.close();
        try out_file.writeAll(png_bytes);

        try stdout.print(
            "  #{d:>2} 0x{x:0>5} {d}x{d} bpp={d} ct={d} codec={d}  -> {s}\n",
            .{ idx, off, info.width, info.height, info.bit_depth, info.color_type, codec_id, name },
        );
        written += 1;
    }

    try stdout.print(
        "\nScanned {s}\n  PNG signatures:    {d}\n  Written (codec 5): {d}\n  Skipped (codec):   {d}\n  Skipped (parse):   {d}\n",
        .{ input_path, offsets.len, written, skipped_codec, skipped_parse },
    );
    try stdout.flush();
}
