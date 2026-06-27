//! Filesystem-backed convenience wrappers around the pure-bytes
//! metadata API in `metadata.zig`. Kept in a separate file so the
//! freestanding/wasm builds (which don't have a real filesystem)
//! never see `std.fs`.

const std = @import("std");
const loader = @import("loader.zig");
const meta = @import("metadata.zig");

/// Heap-owned variant of `Metadata` — the `name` is duplicated so the
/// caller can keep it after the underlying buffer is freed.
pub const OwnedMetadata = struct {
    name: []u8,
    file_size: usize,
    section_count: u32,
    icon: ?meta.Icon = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedMetadata) void {
        self.allocator.free(self.name);
    }
};

/// Cheap path: read header bytes only and return an OWNED copy of the
/// gamelet name. Caller frees with `allocator.free`.
pub fn readName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var hdr: [64]u8 = undefined;
    const got = try file.readAll(&hdr);
    const name = try meta.getName(hdr[0..got]);
    return try allocator.dupe(u8, name);
}

/// Read the .exn fully and extract metadata. The returned struct owns
/// its `name` slice (heap-duped).
pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !OwnedMetadata {
    var ef = try loader.load(allocator, path);
    defer ef.deinit();

    const m = try meta.readMetadataBytes(allocator, ef.raw);
    return .{
        .name = try allocator.dupe(u8, m.name),
        .file_size = m.file_size,
        .section_count = m.section_count,
        .icon = m.icon,
        .allocator = allocator,
    };
}

/// Extract the icon PNG bytes from a .exn on disk. Returns null when
/// the file has no image section. Caller frees with `allocator.free`.
pub fn readIconPng(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var ef = try loader.load(allocator, path);
    defer ef.deinit();

    const icon = (try meta.getIcon(allocator, ef.raw)) orelse return null;
    const png = ef.raw[icon.png_offset .. icon.png_offset + icon.png_length];
    return try allocator.dupe(u8, png);
}
