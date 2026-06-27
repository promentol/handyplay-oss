//! Byte cursor/reader helpers for save-state serialization. The ExEn save-state
//! itself lives in exen.zig (it needs the module-global VM/heap/framebuffer state);
//! this just provides the little-endian read/write primitives it builds on.
const std = @import("std");

pub const Cursor = struct {
    buf: []u8,
    pos: usize = 0,
    pub fn bytes(self: *Cursor, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    pub fn u32v(self: *Cursor, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    pub fn usizev(self: *Cursor, v: usize) void {
        self.u32v(@intCast(v));
    }
    pub fn val(self: *Cursor, v: anytype) void {
        self.bytes(std.mem.asBytes(&v));
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    pub fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }
    pub fn u32v(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.bytes(4))[0..4], .little);
    }
    pub fn usizev(self: *Reader) !usize {
        return @intCast(try self.u32v());
    }
    pub fn val(self: *Reader, comptime T: type) !T {
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), try self.bytes(@sizeOf(T)));
        return v;
    }
};
