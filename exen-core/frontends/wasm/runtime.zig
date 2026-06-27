//! ExEn 2 runtime frontend for WebAssembly (emscripten).
//!
//! Exposes a small C ABI for a browser shell to drive the full VM — the same
//! runtime the SDL3 frontend uses, just with input/framebuffer marshalled across
//! the wasm boundary instead of through SDL. The game `.exn`, `reference/
//! simulator.ini`, `assets/unk_4494F0.bin`, and `flash/` are read from emscripten's
//! MEMFS (preloaded via emcc --preload-file; the game is written in by JS).
//!
//! Built with `zig build-obj -target wasm32-emscripten` + emcc link (see
//! wasm/build.sh). No Unicorn — ExEn is a pure bytecode interpreter.
const std = @import("std");
const exen = @import("core");
const natives = @import("natives");
const icon = @import("icon.zig");

// Emscripten libc malloc — keeps allocations in the heap emscripten's HEAP views
// track (Zig's page allocator would grow wasm memory out from under them).
const gpa = std.heap.c_allocator;

var g_booted = false;
var g_paused: bool = false;

/// Boot the VM and load the game previously written to MEMFS at "/game.exn".
/// Returns 0 on success, negative on failure.
export fn exn_boot() i32 {
    exen.boot(gpa, "reference/simulator.ini") catch |e| {
        std.debug.print("[exn] boot error: {s}\n", .{@errorName(e)});
        return -1;
    };
    exen.setNativeDispatcher(&natives.dispatch);
    exen.loadExn("/game.exn") catch |e| {
        std.debug.print("[exn] loadExn error: {s}\n", .{@errorName(e)});
        return -2;
    };
    g_booted = true;
    return 0;
}

/// Advance the VM by delta_ms (drives the deterministic VM clock + the gamelet's
/// tick handler, which redraws). delta_ms is the per-frame step.
export fn exn_tick(delta_ms: u32) void {
    if (g_booted and !g_paused) exen.tick(delta_ms);
}

// --- libretro-style control + metadata ----------------------------------
export fn exn_pause() void {
    g_paused = true;
}
export fn exn_resume() void {
    g_paused = false;
}
export fn exn_is_paused() i32 {
    return if (g_paused) 1 else 0;
}
export fn exn_get_name(out: [*]u8, max: usize) usize {
    _ = out;
    _ = max;
    return 0;
}
export fn exn_icon(cp: u32, out: [*]u8, size: u32) void {
    icon.renderLetter(cp, out, size);
}

/// Pointer to the simulated-LCD framebuffer (ABGR8888 little-endian == canvas
/// RGBA byte order, so JS can blit it straight into an ImageData).
export fn exn_screen_ptr() ?[*]u32 {
    const fb = exen.framebuffer() orelse return null;
    return fb.pixels.ptr;
}

export fn exn_screen_w() u32 {
    return exen.screenWidth();
}

export fn exn_screen_h() u32 {
    return exen.screenHeight();
}

/// Deliver a key. down=1 → keypress, down=0 → keyrelease. `code` is an ExEn key
/// code (KEY_UP='2', DOWN='8', LEFT='4', RIGHT='6', FIRE=-8, SOFT1='*', SOFT2='#',
/// digits = their ASCII).
export fn exn_key(down: i32, code: i32) void {
    if (!g_booted) return;
    if (down != 0) exen.signalKeypress(code) else exen.signalKeyrelease(code);
}

/// 1 if the gamelet requested exit, else 0.
export fn exn_quit_requested() i32 {
    return if (exen.vmExitRequested()) 1 else 0;
}

// --- save-state (retro_serialize primitive) --------------------------------
export fn exn_state_size() usize {
    return exen.stateSize();
}
export fn exn_state_save(ptr: [*]u8, len: usize) usize {
    return exen.saveState(ptr[0..len]) catch 0;
}
export fn exn_state_load(ptr: [*]const u8, len: usize) i32 {
    exen.loadState(ptr[0..len]) catch return -1;
    return 0;
}
