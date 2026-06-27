//! WASM frontend: exports a tiny C ABI for a browser/JS shell to drive the MRE
//! core. The .vxp is handed in via a heap buffer (alloc + boot); the JS shell
//! pulls the RGB565 framebuffer pointer each frame and blits it to a <canvas>.
//!
//! Built with `zig build-obj -target wasm32-emscripten` and linked by emcc against
//! the Emscripten-built Unicorn (wasm/libunicorn-arm-wasm.a). See wasm/build.sh.
const std = @import("std");
const core = @import("core");
const icon = @import("icon.zig");

// Use emscripten's libc malloc: it manages the wasm heap that emscripten's own
// HEAP views track, rather than Zig's page allocator growing memory out from
// under emscripten. (Memory still grows, but through emscripten's path.)
const gpa = std.heap.c_allocator;

var g_mem: ?core.Memory = null;
var g_vm: ?*core.Vm = null;
var g_file: []u8 = &.{};
var g_paused: bool = false;

/// Allocate a buffer in wasm linear memory for JS to copy the .vxp bytes into.
export fn mre_alloc(n: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, n) catch return null;
    g_file = buf;
    return buf.ptr;
}

/// Load and start the game previously written into the mre_alloc buffer.
/// Returns 0 on success, negative on failure.
export fn mre_boot() i32 {
    g_mem = core.Memory.init(gpa, 32 * 1024 * 1024) catch return -1;
    const vm = core.Vm.create(gpa, &g_mem.?) catch return -2;
    g_vm = vm;
    vm.loadAndStart(g_file) catch |e| {
        std.debug.print("[mre] load error: {s}\n", .{@errorName(e)});
        return -3;
    };
    return 0;
}

/// Advance the game's main loop by delta_ms (fires timers, pumps events).
export fn mre_tick(delta_ms: u32) void {
    if (g_paused) return;
    if (g_vm) |vm| vm.tick(delta_ms);
}

// --- libretro-style control + metadata ----------------------------------
/// Pause/resume the run loop (tick becomes a no-op while paused).
export fn mre_pause() void {
    g_paused = true;
}
export fn mre_resume() void {
    g_paused = false;
}
export fn mre_is_paused() i32 {
    return if (g_paused) 1 else 0;
}

/// Game display name into `out` (UTF-8, up to `max`); returns length. Stub: the
/// core doesn't parse a name yet, so 0 — the shell falls back to the filename.
export fn mre_get_name(out: [*]u8, max: usize) usize {
    _ = out;
    _ = max;
    return 0;
}

/// Render a `size`x`size` RGBA icon for codepoint `cp` (first letter of the name)
/// into `out` (size*size*4 bytes). Pixel-art stub until real icons exist.
export fn mre_icon(cp: u32, out: [*]u8, size: u32) void {
    icon.renderLetter(cp, out, size);
}

/// Pointer to the RGB565 screen buffer (screen_w * screen_h u16).
export fn mre_screen_ptr() ?[*]u16 {
    const vm = g_vm orelse return null;
    if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();
    return vm.gfx.screen.ptr;
}

export fn mre_screen_w() u32 {
    return core.gfx.screen_w;
}

export fn mre_screen_h() u32 {
    return core.gfx.screen_h;
}

/// Deliver a key event. event: 1=down,2=up. keycode: MRE keycode (arrows -1..-4,
/// ok -5, lsk -6, rsk -7, digits 48..57, * 42, # 35).
export fn mre_key(event: u32, keycode: i32) void {
    if (g_vm) |vm| vm.deliverKey(event, keycode);
}

/// Deliver a pen event. event: 1=tap,2=release,3=move.
export fn mre_pen(event: u32, x: i32, y: i32) void {
    if (g_vm) |vm| vm.deliverPen(event, x, y);
}

/// 1 if the game requested exit (vm_exit_app), else 0.
export fn mre_quit_requested() i32 {
    const vm = g_vm orelse return 0;
    return if (vm.quit_requested) 1 else 0;
}

// --- save-state (retro_serialize primitive) --------------------------------

/// Upper-bound byte size of a save-state (stable; for retro_serialize_size).
export fn mre_state_size() usize {
    const vm = g_vm orelse return 0;
    return core.savestate.size(vm);
}

/// Serialize VM state into [ptr, ptr+len). Returns bytes written, or 0 on failure.
export fn mre_state_save(ptr: [*]u8, len: usize) usize {
    const vm = g_vm orelse return 0;
    return core.savestate.save(vm, ptr[0..len]) catch 0;
}

/// Restore VM state from [ptr, ptr+len). Returns 0 on success, negative on failure.
export fn mre_state_load(ptr: [*]const u8, len: usize) i32 {
    const vm = g_vm orelse return -1;
    core.savestate.load(vm, ptr[0..len]) catch return -2;
    return 0;
}
