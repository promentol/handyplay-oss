//! MRE trailing-tag table parser.
//!
//! The tag table lives at the tail of a .vxp. The last 12 bytes are a footer whose
//! first u32 is `tags_offset`. From there, tags are `[id:u32][size:u32][data:size]`
//! repeated until a tag with id == 0. Tags are addressed by id (only a handful
//! matter): 0x0F = RAM size (KB), 0x21 = ADS type, 0x22 = zipped flag.
const std = @import("std");

pub const Tags = struct {
    tags_offset: u32 = 0,
    ram_kb: u32 = 0,
    ads_type: ?i32 = null, // tag 0x21
    zipped: bool = false, // tag 0x22

    /// ADS if tag 0x21 ∈ {0, 1, 5}.
    pub fn isAds(self: Tags) bool {
        const t = self.ads_type orelse return false;
        return t == 0 or t == 1 or t == 5;
    }

    pub fn isSimpleAds(self: Tags) bool {
        return (self.ads_type orelse return false) == 5;
    }

    pub fn isZipped(self: Tags) bool {
        return self.zipped;
    }
};

pub const Error = error{ TooSmall, Truncated };

pub fn parse(file: []const u8) Error!Tags {
    if (file.len < 12) return Error.TooSmall;

    var t: Tags = .{};
    t.tags_offset = rd32(file, @intCast(file.len - 12));

    var pos: u64 = t.tags_offset;
    while (true) {
        if (pos + 8 >= file.len) return Error.Truncated;
        const id = rd32(file, @intCast(pos));
        const size = rd32(file, @intCast(pos + 4));
        pos += 8;
        if (pos + size >= file.len) return Error.Truncated;

        const data = file[@intCast(pos)..][0..size];
        switch (id) {
            0x0F => if (size == 4) {
                t.ram_kb = std.mem.readInt(u32, data[0..4], .little);
            },
            0x21 => if (size == 4) {
                t.ads_type = std.mem.readInt(i32, data[0..4], .little);
            },
            0x22 => if (size == 4) {
                t.zipped = std.mem.readInt(i32, data[0..4], .little) != 0;
            },
            else => {},
        }

        pos += size;
        if (id == 0) break;
    }
    return t;
}

fn rd32(file: []const u8, off: u32) u32 {
    return std.mem.readInt(u32, file[off..][0..4], .little);
}

test "parse minimal tag table" {
    // Build: [body...][tag 0x0F size4 =2048][tag 0x21 size4 =1][tag 0 size0][footer:offset,_,_]
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try buf.appendSlice(a, &[_]u8{0} ** 16); // body
    const tags_off: u32 = @intCast(buf.items.len);
    try appendTag(a, &buf, 0x0F, &le32(2048));
    try appendTag(a, &buf, 0x21, &le32(1));
    try appendTag(a, &buf, 0x00, &.{});
    try buf.appendSlice(a, &le32(tags_off)); // footer[0]
    try buf.appendSlice(a, &le32(0));
    try buf.appendSlice(a, &le32(0));

    const t = try parse(buf.items);
    try std.testing.expectEqual(tags_off, t.tags_offset);
    try std.testing.expectEqual(@as(u32, 2048), t.ram_kb);
    try std.testing.expect(t.isAds());
    try std.testing.expect(!t.isZipped());
}

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn appendTag(a: std.mem.Allocator, buf: *std.ArrayList(u8), id: u32, data: []const u8) !void {
    try buf.appendSlice(a, &le32(id));
    try buf.appendSlice(a, &le32(@intCast(data.len)));
    try buf.appendSlice(a, data);
}
