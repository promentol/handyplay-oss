//! Frontend-agnostic audio backend (mirrors exen-player2/core/audio.zig).
//!
//! The core never talks to a sound device directly — it calls the function
//! pointers a frontend installs here. The SDL frontend wires these to an SDL audio
//! device; a future libretro frontend would instead push samples into libretro's
//! audio callback; headless builds leave them null (silent no-op). All callbacks use
//! the C calling convention so a frontend can implement them in C or via any C lib.
const std = @import("std");

/// Play an encoded clip. `data`/`len` is the raw clip (the `format` byte is the MRE
/// codec id). The implementation must copy any bytes it needs to keep. Returns a
/// playback handle (>=0) or -1.
pub const PlayFn = *const fn (data: [*]const u8, len: usize, format: u8) callconv(.c) i32;
/// Stop all playback.
pub const StopAllFn = *const fn () callconv(.c) void;
/// Close one playback handle.
pub const CloseFn = *const fn (handle: i32) callconv(.c) void;

pub const Backend = struct {
    play_fn: ?PlayFn = null,
    stop_all_fn: ?StopAllFn = null,
    close_fn: ?CloseFn = null,
};

pub var backend: Backend = .{};
pub var volume: u8 = 4; // 0..6, MRE convention

pub fn play(data: []const u8, format: u8) i32 {
    if (backend.play_fn) |f| return f(data.ptr, data.len, format);
    return -1;
}
pub fn stopAll() void {
    if (backend.stop_all_fn) |f| f();
}
pub fn close(handle: i32) void {
    if (backend.close_fn) |f| f(handle);
}
