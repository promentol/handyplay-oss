//! Audio backend interface.
//!
//! `Gamelet.playMelody` / `Gamelet.stopMelody` (natives idx 82 / 83)
//! are canonically `EXManufMelodyPlay` / `EXManufMelodyStop` —
//! `sub_43B192` / `sub_43B259` in `reference/ref`. Canonical
//! routes them to Win32 `midiOutShortMsg` via a `SetTimer`-driven
//! scheduler.
//!
//! Our core stays platform-agnostic: it just calls the function
//! pointers registered here. The SDL frontend installs callbacks at
//! boot that translate the the platform byte-stream (`(opcode, param)`
//! pairs) into SDL3 audio samples via a small square-wave generator,
//! matching `docs/audio.md`'s "option 1" plan.
//!
//! Both callbacks use the C calling convention so the implementation
//! can live in a `.c` file or use any C library (e.g. SDL3, TinyMidi,
//! TinySoundFont) without Zig-callconv adapters.

/// Called by `Gamelet.playMelody`. `data` points at the gamelet's
/// MIDI-ish event byte stream; `len` is its byte length. The
/// implementation must copy any bytes it needs to keep — the heap
/// buffer can be freed or overwritten as soon as this returns.
pub const PlayFn = *const fn (data: [*]const u8, len: usize) callconv(.c) void;

/// Called by `Gamelet.stopMelody`. Cancels any pending playback.
pub const StopFn = *const fn () callconv(.c) void;

/// Process-wide audio backend. The SDL frontend sets `.play_fn` /
/// `.stop_fn` during boot; if neither is set (e.g. headless builds),
/// the play/stop calls silently no-op.
pub const Backend = struct {
    play_fn: ?PlayFn = null,
    stop_fn: ?StopFn = null,
};

pub var backend: Backend = .{};

/// Convenience wrapper used by the natives. Safe to call before the
/// frontend has registered a backend (no-op until then).
pub fn play(data: []const u8) void {
    if (backend.play_fn) |f| f(data.ptr, data.len);
}

pub fn stop() void {
    if (backend.stop_fn) |f| f();
}
