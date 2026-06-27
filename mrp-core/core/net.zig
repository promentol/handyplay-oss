//! Socket layer — stubbed by default (every entry returns MR_FAILED). The sky-mobi payment/
//! network backends are long defunct, so real sockets only buy crashes (Zig's
//! std.posix.connect aborts on unroutable cmwap proxy addresses) and hangs.
//! Games handle MR_FAILED gracefully (they fall back to offline/no-network).
//!
//! A real synchronous implementation lived here previously; if networking is ever
//! needed (e.g. a local mock payment gateway), reintroduce it behind raw syscalls
//! with non-blocking sockets — see git history.
const std = @import("std");

pub const MR_FAILED: i32 = -1;

pub const Net = struct {
    pub fn init(_: std.mem.Allocator) Net {
        return .{};
    }
    pub fn deinit(_: *Net) void {}

    pub fn initNetwork(_: *Net) i32 {
        return MR_FAILED;
    }
    pub fn closeNetwork(_: *Net) i32 {
        return MR_FAILED;
    }
    pub fn socket(_: *Net, _: i32, _: i32) i32 {
        return MR_FAILED;
    }
    pub fn connect(_: *Net, _: i32, _: u32, _: u16, _: i32) i32 {
        return MR_FAILED;
    }
    pub fn getSocketState(_: *Net, _: i32) i32 {
        return MR_FAILED;
    }
    pub fn closeSocket(_: *Net, _: i32) i32 {
        return MR_FAILED;
    }
    pub fn send(_: *Net, _: i32, _: []const u8) i32 {
        return MR_FAILED;
    }
    pub fn recv(_: *Net, _: i32, _: []u8) i32 {
        return MR_FAILED;
    }
    pub fn sendto(_: *Net, _: i32, _: []const u8, _: u32, _: u16) i32 {
        return MR_FAILED;
    }
    pub fn recvfrom(_: *Net, _: i32, _: []u8, _: *u32, _: *u16) i32 {
        return MR_FAILED;
    }
    pub fn getHostByName(_: *Net, _: []const u8) i32 {
        return MR_FAILED;
    }
};
