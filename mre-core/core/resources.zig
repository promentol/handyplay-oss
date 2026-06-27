//! .vxp embedded resource section.
//!
//! The resource section is a flat table of `[name\0][offset:u32][size:u32]`
//! records terminated by a zero name byte. Offsets may be section-relative (the
//! reference flips to "global" mode on the first such entry and biases all by the
//! section base). `vm_load_resource(name)` copies the named blob into guest memory.
const std = @import("std");

pub const Entry = struct { name: []const u8, offset: u32, size: u32 };

pub const Resources = struct {
    file: []const u8 = &.{}, // whole .vxp bytes (resource data lives here)
    base: u32 = 0,
    size: u32 = 0,
    entries: std.ArrayList(Entry) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Resources {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Resources) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.deinit(self.gpa);
    }

    pub fn scan(self: *Resources, file: []const u8, base: u32, size: u32) !void {
        self.file = file;
        self.base = base;
        self.size = size;
        if (size == 0 or base + size > file.len) return;

        var pos: u32 = base;
        var global = false;
        while (true) {
            if (pos > base + size or pos >= file.len) break;
            if (file[pos] == 0) break;

            const name_start = pos;
            const name_end = std.mem.indexOfScalarPos(u8, file, pos, 0) orelse break;
            const name = file[name_start..name_end];
            pos = @intCast(name_end + 1);
            if (pos + 8 > file.len) break;

            var res_offset = std.mem.readInt(u32, file[pos..][0..4], .little);
            const res_size = std.mem.readInt(u32, file[pos + 4 ..][0..4], .little);
            pos += 8;

            if (res_offset < base or global) {
                res_offset += base;
                global = true;
            }
            if (res_offset < base or res_offset + res_size > base + size) break;

            try self.entries.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, name),
                .offset = res_offset,
                .size = res_size,
            });
        }
    }

    pub fn find(self: *Resources, name: []const u8) ?Entry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};
