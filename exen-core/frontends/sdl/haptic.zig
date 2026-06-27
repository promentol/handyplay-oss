//! SDL3 haptic backend for `core.haptic`.
//!
//! `Gamelet.playVibrator` (native idx 81) calls into this whenever the
//! gamelet wants a vibration pulse. On a desktop SDL build without an
//! attached game controller there is no haptic device, so the default
//! behaviour is "log and no-op" — matching the canonical reference
//! simulator which has no vibration hardware either, just an `ExManuf
//! Vibrati...` debug print.
//!
//! When a game controller IS attached we open it and emit a rumble
//! pulse for the requested duration. This gives macOS / Linux users
//! with a gamepad real haptic feedback for Arthur, MotoGp, etc.

const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", "1");
    @cInclude("SDL3/SDL.h");
});

const log = std.log.scoped(.haptic);

var g_gamepad: ?*c.SDL_Gamepad = null;
var g_init_attempted: bool = false;

fn vibrateCallback(duration_ms: u32) callconv(.c) void {
    // Lazy init: open the first available gamepad on the first
    // vibrate call. Headless / no-gamepad runs just hit the log
    // branch and continue.
    if (!g_init_attempted) {
        g_init_attempted = true;
        if (!c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD)) return;
        var count: c_int = 0;
        const ids = c.SDL_GetGamepads(&count);
        if (ids != null and count > 0) {
            g_gamepad = c.SDL_OpenGamepad(ids[0]);
        }
        if (ids != null) c.SDL_free(ids);
    }
    if (g_gamepad) |pad| {
        // Both rumble motors at full strength for the requested ms.
        _ = c.SDL_RumbleGamepad(pad, 0xFFFF, 0xFFFF, duration_ms);
    } else {
        log.debug("vibrate {d}ms (no gamepad attached — no-op)", .{duration_ms});
    }
}

pub fn register() void {
    const haptic = @import("core").haptic;
    haptic.backend.vibrate_fn = vibrateCallback;
}

pub fn deinit() void {
    if (g_gamepad) |pad| {
        c.SDL_CloseGamepad(pad);
        g_gamepad = null;
    }
    if (g_init_attempted) c.SDL_QuitSubSystem(c.SDL_INIT_GAMEPAD);
}
