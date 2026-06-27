//! Compressed MAUI-ADS payload — the compressed-ELF branch of .vxp loading.
//! The .vxp tail (just before the tag table) holds a u32
//! `elf_info_size` followed — backwards — by the 36-byte info struct describing two
//! zlib streams (RO then RW) plus a zero-init (ZI) tail and an embedded resource blob.
const std = @import("std");

pub const Info = extern struct {
    ro_offset: u32,
    ro_size: u32,
    org_ro_size: u32,
    rw_offset: u32,
    rw_size: u32,
    org_rw_size: u32,
    zi_size: u32,
    res_offset: u32,
    res_size: u32,
};

comptime {
    std.debug.assert(@sizeOf(Info) == 36);
}

pub const Error = error{ BadInfoSize, OutOfRange, Decompress };

/// Reads the info struct located at `tags_offset - 4 - sizeof(Info)`.
pub fn readInfo(file: []const u8, tags_offset: u32) Error!Info {
    if (tags_offset < 4 + @sizeOf(Info) or tags_offset > file.len) return Error.OutOfRange;
    const size_pos = tags_offset - 4;
    const elf_info_size = std.mem.readInt(u32, file[size_pos..][0..4], .little);
    if (elf_info_size != @sizeOf(Info)) return Error.BadInfoSize;

    const info_pos = tags_offset - 4 - @sizeOf(Info);
    var info: Info = undefined;
    @memcpy(std.mem.asBytes(&info), file[info_pos..][0..@sizeOf(Info)]);
    return info;
}

/// Decompresses RO and RW zlib streams into `dst` (the app's mapped memory). RW is
/// placed immediately after the uncompressed RO image. Returns segments_size
/// (org_ro + org_rw + zi).
pub fn decompress(file: []const u8, info: Info, dst: []u8) Error!u32 {
    const ro_end: u64 = @as(u64, info.org_ro_size) + info.org_rw_size + info.zi_size;
    if (ro_end > dst.len) return Error.OutOfRange;
    if (@as(u64, info.ro_offset) + info.ro_size > file.len) return Error.OutOfRange;
    if (@as(u64, info.rw_offset) + info.rw_size > file.len) return Error.OutOfRange;

    try inflate(file[info.ro_offset..][0..info.ro_size], dst[0..info.org_ro_size]);
    try inflate(
        file[info.rw_offset..][0..info.rw_size],
        dst[info.org_ro_size..][0..info.org_rw_size],
    );
    return @intCast(ro_end);
}

fn inflate(src: []const u8, dst: []u8) Error!void {
    var in = std.Io.Reader.fixed(src);
    var out = std.Io.Writer.fixed(dst);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const n = d.reader.streamRemaining(&out) catch return Error.Decompress;
    if (n != dst.len) return Error.Decompress;
}
