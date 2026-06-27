//! Haptic (vibration) backend interface.
//!
//! `Gamelet.playVibrator` (native idx 81) canonically dispatches to
//! `sub_434189(1000)` — a Win32 helper that records "vibrate for
//! N ms" in `dword_4A20BC` and emits the `ExManufVibrati...` debug
//! string. On the reference simulator there is no actual vibration
//! hardware; the call is observable only through the trace.
//!
//! Like `core.audio`, this module stays platform-agnostic: the
//! frontend installs a callback at boot; if no callback is registered
//! the call silently no-ops (matches reference-simulator behaviour).

/// Called by `Gamelet.playVibrator`. `duration_ms` is the requested
/// vibration length in milliseconds (canonical hard-codes 1000ms; we
/// pass it through so a future caller-provided variant can override).
pub const VibrateFn = *const fn (duration_ms: u32) callconv(.c) void;

pub const Backend = struct {
    vibrate_fn: ?VibrateFn = null,
};

pub var backend: Backend = .{};

pub fn vibrate(duration_ms: u32) void {
    if (backend.vibrate_fn) |f| f(duration_ms);
}
