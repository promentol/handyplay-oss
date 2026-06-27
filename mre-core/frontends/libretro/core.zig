//! libretro core for mre-player (.vxp / MediaTek MRE).
//!
//! Exports the `retro_*` C ABI. Builds natively to a `.so`/`.dylib` (desktop
//! RetroArch) and any other libretro host. The VM, loader, and save-state code
//! are the same frontend-agnostic `core/` used by the SDL frontend.
const std = @import("std");
const core = @import("core");
const lr = @import("libretro.zig");

const gpa = std.heap.c_allocator;

/// Single source of truth for frame timing: we report `FPS` to the frontend via av_info
/// and advance the sim by exactly `FRAME_MS` (= 1000/FPS) per `retro_run`, so the game
/// clock tracks the libretro frame rate. MRE games are gated by their own `vm.timers[]`
/// intervals, so 30 fps × ~33 ms reproduces the real-hardware cadence.
const FPS: f64 = 30.0;
const FRAME_MS: u32 = @intFromFloat(@round(1000.0 / FPS));

var env_cb: lr.EnvironmentFn = null;
var video_cb: lr.VideoRefreshFn = null;
var audio_batch_cb: lr.AudioSampleBatchFn = null;
var input_poll_cb: lr.InputPollFn = null;
var input_state_cb: lr.InputStateFn = null;

var g_mem: ?core.Memory = null;
var g_vm: ?*core.Vm = null;
var g_rom: []u8 = &.{};
var prev_buttons: [12]bool = [_]bool{false} ** 12;

// RetroPad button id -> MRE keycode (see core/vm.zig Key).
const KEYMAP = [_]struct { id: c_uint, code: i32 }{
    .{ .id = lr.DEVICE_ID_JOYPAD_UP, .code = -1 },
    .{ .id = lr.DEVICE_ID_JOYPAD_DOWN, .code = -2 },
    .{ .id = lr.DEVICE_ID_JOYPAD_LEFT, .code = -3 },
    .{ .id = lr.DEVICE_ID_JOYPAD_RIGHT, .code = -4 },
    .{ .id = lr.DEVICE_ID_JOYPAD_A, .code = -5 }, // OK
    .{ .id = lr.DEVICE_ID_JOYPAD_B, .code = -5 }, // OK
    .{ .id = lr.DEVICE_ID_JOYPAD_L, .code = -6 }, // left soft key
    .{ .id = lr.DEVICE_ID_JOYPAD_R, .code = -7 }, // right soft key
    .{ .id = lr.DEVICE_ID_JOYPAD_START, .code = -5 },
};

export fn retro_api_version() callconv(.c) c_uint {
    return lr.API_VERSION;
}

export fn retro_set_environment(cb: lr.EnvironmentFn) callconv(.c) void {
    env_cb = cb;
}
export fn retro_set_video_refresh(cb: lr.VideoRefreshFn) callconv(.c) void {
    video_cb = cb;
}
export fn retro_set_audio_sample(_: ?*anyopaque) callconv(.c) void {}
export fn retro_set_audio_sample_batch(cb: lr.AudioSampleBatchFn) callconv(.c) void {
    audio_batch_cb = cb;
}
export fn retro_set_input_poll(cb: lr.InputPollFn) callconv(.c) void {
    input_poll_cb = cb;
}
export fn retro_set_input_state(cb: lr.InputStateFn) callconv(.c) void {
    input_state_cb = cb;
}

export fn retro_init() callconv(.c) void {}
export fn retro_deinit() callconv(.c) void {}

export fn retro_get_system_info(info: *lr.SystemInfo) callconv(.c) void {
    info.* = .{
        .library_name = "mre-player",
        .library_version = "0.1",
        .valid_extensions = "vxp",
        .need_fullpath = false, // ROM bytes handed to us in game.data
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: *lr.SystemAvInfo) callconv(.c) void {
    info.* = .{
        .geometry = .{
            .base_width = core.gfx.screen_w,
            .base_height = core.gfx.screen_h,
            .max_width = core.gfx.screen_w,
            .max_height = core.gfx.screen_h,
            .aspect_ratio = @as(f32, core.gfx.screen_w) / @as(f32, core.gfx.screen_h),
        },
        .timing = .{ .fps = FPS, .sample_rate = 44100.0 },
    };
}

export fn retro_set_controller_port_device(_: c_uint, _: c_uint) callconv(.c) void {}
export fn retro_reset() callconv(.c) void {
    // Re-boot the loaded ROM from scratch.
    if (g_rom.len != 0) {
        teardown();
        _ = bootRom(g_rom) catch {};
    }
}

fn teardown() void {
    if (g_vm) |vm| {
        vm.destroy();
        g_vm = null;
    }
    if (g_mem) |*m| {
        m.deinit();
        g_mem = null;
    }
}

fn bootRom(rom: []const u8) !void {
    g_mem = try core.Memory.init(gpa, 32 * 1024 * 1024);
    const vm = try core.Vm.create(gpa, &g_mem.?);
    g_vm = vm;
    try vm.loadAndStart(rom);
}

export fn retro_load_game(game: ?*const lr.GameInfo) callconv(.c) bool {
    const g = game orelse return false;
    const data = g.data orelse return false;
    if (g.size == 0) return false;

    // Tell the frontend we render RGB565.
    var fmt: c_uint = lr.PIXEL_FORMAT_RGB565;
    if (env_cb) |cb| _ = cb(lr.ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);

    // Keep our own copy of the ROM (frontend may free game.data).
    const bytes = @as([*]const u8, @ptrCast(data))[0..g.size];
    g_rom = gpa.dupe(u8, bytes) catch return false;

    prev_buttons = [_]bool{false} ** 12;
    bootRom(g_rom) catch return false;
    return true;
}

export fn retro_unload_game() callconv(.c) void {
    teardown();
    if (g_rom.len != 0) {
        gpa.free(g_rom);
        g_rom = &.{};
    }
}

export fn retro_run() callconv(.c) void {
    const vm = g_vm orelse return;

    // Input: edge-detect each mapped RetroPad button -> MRE key down/up.
    if (input_poll_cb) |poll| poll();
    if (input_state_cb) |state| {
        for (KEYMAP) |k| {
            const pressed = state(0, lr.DEVICE_JOYPAD, 0, k.id) != 0;
            const idx = k.id; // 0..11
            if (pressed and !prev_buttons[idx]) vm.deliverKey(2, k.code); // DOWN
            if (!pressed and prev_buttons[idx]) vm.deliverKey(1, k.code); // UP
            prev_buttons[idx] = pressed;
        }
    }

    // Advance one frame (FRAME_MS = 1000/FPS; the game redraws from its timer cb).
    vm.tick(FRAME_MS);
    if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();

    // Present RGB565 framebuffer.
    if (video_cb) |refresh|
        refresh(vm.gfx.screen.ptr, core.gfx.screen_w, core.gfx.screen_h, core.gfx.screen_w * 2);
}

// --- save-states ----------------------------------------------------------
export fn retro_serialize_size() callconv(.c) usize {
    const vm = g_vm orelse return 0;
    return core.savestate.size(vm);
}
export fn retro_serialize(data: ?*anyopaque, len: usize) callconv(.c) bool {
    const vm = g_vm orelse return false;
    const out = @as([*]u8, @ptrCast(data orelse return false))[0..len];
    _ = core.savestate.save(vm, out) catch return false;
    return true;
}
export fn retro_unserialize(data: ?*const anyopaque, len: usize) callconv(.c) bool {
    const vm = g_vm orelse return false;
    const in = @as([*]const u8, @ptrCast(data orelse return false))[0..len];
    core.savestate.load(vm, in) catch return false;
    return true;
}

// --- unused-but-required ABI ----------------------------------------------
export fn retro_cheat_reset() callconv(.c) void {}
export fn retro_cheat_set(_: c_uint, _: bool, _: ?[*:0]const u8) callconv(.c) void {}
export fn retro_load_game_special(_: c_uint, _: ?*const lr.GameInfo, _: usize) callconv(.c) bool {
    return false;
}
export fn retro_get_region() callconv(.c) c_uint {
    return lr.REGION_NTSC;
}
export fn retro_get_memory_data(_: c_uint) callconv(.c) ?*anyopaque {
    return null;
}
export fn retro_get_memory_size(_: c_uint) callconv(.c) usize {
    return 0;
}
