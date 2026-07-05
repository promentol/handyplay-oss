//! libretro core for exen-player2 (.exn / ExEn 2 Java-bytecode VM).
//!
//! Pure interpreter — no Unicorn. Builds natively to a `.so`/`.dylib` for
//! RetroArch and any other libretro host. The VM reads its runtime
//! assets (reference/simulator.ini, assets/unk_4494F0.bin, flash/) from the cwd
//! (system-directory wiring is a later refinement); the game .exn is taken by path
//! (need_fullpath=true) so `exen.loadExn` opens it directly.
const std = @import("std");
const exen = @import("core");
const natives = @import("natives");
const lr = @import("libretro.zig");

const gpa = std.heap.c_allocator;

/// Single source of truth for game speed. We report `FPS` to the frontend via av_info
/// and advance the simulation by exactly `FRAME_MS` (= 1000/FPS) per `retro_run`, so the
/// game clock stays consistent with the libretro frame rate the frontend paces us to.
/// exen has NO gamelet-timer wiring (it free-runs one Bootstrap.tick per frame), so FPS
/// directly sets the game speed; 20 runs slower than the original 30 free-run rate.
const FPS: f64 = 20.0;
const FRAME_MS: u32 = @intFromFloat(@round(1000.0 / FPS));

const bios = @import("bios.zig");

// Required BIOS (by MD5, filename-independent): only the 4CVP builtins blob — the
// device profile (132x176) is hardcoded in exen.boot, so simulator.ini is no longer
// needed. User-supplied firmware: exen_builtins.bin.
const BIOS = [_]bios.Req{
    .{ .md5 = "870bef21d6f269e3e3d91943c66de8e8", .dst = "assets/unk_4494F0.bin" },
};

fn systemDir() ?[]const u8 {
    var p: ?[*:0]const u8 = null;
    if (env_cb) |cb| if (cb(lr.ENVIRONMENT_GET_SYSTEM_DIRECTORY, @ptrCast(&p)))
        if (p) |s| return std.mem.sliceTo(s, 0);
    return null;
}

var env_cb: lr.EnvironmentFn = null;
var video_cb: lr.VideoRefreshFn = null;
var input_poll_cb: lr.InputPollFn = null;
var input_state_cb: lr.InputStateFn = null;

var g_booted = false;
var prev_buttons: [12]bool = [_]bool{false} ** 12;
// ABGR8888 -> XRGB8888 conversion scratch (libretro has no ABGR format).
const MAX_PX = 320 * 320;
var convert_buf: [MAX_PX]u32 = undefined;

// RetroPad id -> ExEn key code (core/exen.zig: arrows are keypad ASCII; FIRE=-8).
const KEYMAP = [_]struct { id: c_uint, code: i32 }{
    .{ .id = lr.DEVICE_ID_JOYPAD_UP, .code = '2' },
    .{ .id = lr.DEVICE_ID_JOYPAD_DOWN, .code = '8' },
    .{ .id = lr.DEVICE_ID_JOYPAD_LEFT, .code = '4' },
    .{ .id = lr.DEVICE_ID_JOYPAD_RIGHT, .code = '6' },
    .{ .id = lr.DEVICE_ID_JOYPAD_A, .code = -8 }, // FIRE
    .{ .id = lr.DEVICE_ID_JOYPAD_B, .code = -8 },
    .{ .id = lr.DEVICE_ID_JOYPAD_START, .code = -8 },
    .{ .id = lr.DEVICE_ID_JOYPAD_L, .code = '*' },
    .{ .id = lr.DEVICE_ID_JOYPAD_R, .code = '#' },
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
export fn retro_set_audio_sample_batch(_: ?*anyopaque) callconv(.c) void {}
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
        .library_name = "exen-player",
        .library_version = "0.1",
        .valid_extensions = "exn",
        .need_fullpath = true, // exen.loadExn opens the path directly
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: *lr.SystemAvInfo) callconv(.c) void {
    const w = if (g_booted) exen.screenWidth() else 132;
    const h = if (g_booted) exen.screenHeight() else 176;
    info.* = .{
        .geometry = .{
            .base_width = w,
            .base_height = h,
            .max_width = 320,
            .max_height = 320,
            .aspect_ratio = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h)),
        },
        .timing = .{ .fps = FPS, .sample_rate = 44100.0 },
    };
}

export fn retro_set_controller_port_device(_: c_uint, _: c_uint) callconv(.c) void {}
export fn retro_reset() callconv(.c) void {}

export fn retro_load_game(game: ?*const lr.GameInfo) callconv(.c) bool {
    const g = game orelse return false;
    const path = g.path orelse return false; // need_fullpath

    var fmt: c_uint = lr.PIXEL_FORMAT_XRGB8888;
    if (env_cb) |cb| _ = cb(lr.ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);

    // Locate + install BIOS from the system dir by MD5, then boot.
    const sysdir = systemDir() orelse "/";
    bios.install(gpa, sysdir, &BIOS) catch return false;
    exen.boot(gpa, "reference/simulator.ini") catch return false;
    exen.setNativeDispatcher(&natives.dispatch);
    exen.setNativeNames(&natives.native_names);
    exen.loadExn(std.mem.sliceTo(path, 0)) catch return false;
    prev_buttons = [_]bool{false} ** 12;
    g_booted = true;
    return true;
}

export fn retro_unload_game() callconv(.c) void {
    if (g_booted) {
        exen.shutdown();
        g_booted = false;
    }
}

export fn retro_run() callconv(.c) void {
    if (!g_booted) return;

    if (input_poll_cb) |poll| poll();
    if (input_state_cb) |state| {
        for (KEYMAP) |k| {
            const pressed = state(0, lr.DEVICE_JOYPAD, 0, k.id) != 0;
            if (pressed and !prev_buttons[k.id]) exen.signalKeypress(k.code);
            if (!pressed and prev_buttons[k.id]) exen.signalKeyrelease(k.code);
            prev_buttons[k.id] = pressed;
        }
    }

    exen.tick(FRAME_MS);

    const fb = exen.framebuffer() orelse return;
    const n = @min(fb.width * fb.height, MAX_PX);
    // ABGR8888 (bytes R,G,B,A) -> XRGB8888 (0x00RRGGBB): swap R and B.
    for (0..n) |i| {
        const c = fb.pixels[i];
        convert_buf[i] = ((c & 0xFF) << 16) | (c & 0x0000FF00) | ((c >> 16) & 0xFF);
    }
    if (video_cb) |refresh|
        refresh(&convert_buf, fb.width, fb.height, fb.width * 4);
}

// --- save-states ----------------------------------------------------------
export fn retro_serialize_size() callconv(.c) usize {
    return exen.stateSize();
}
export fn retro_serialize(data: ?*anyopaque, len: usize) callconv(.c) bool {
    const out = @as([*]u8, @ptrCast(data orelse return false))[0..len];
    _ = exen.saveState(out) catch return false;
    return true;
}
export fn retro_unserialize(data: ?*const anyopaque, len: usize) callconv(.c) bool {
    const in = @as([*]const u8, @ptrCast(data orelse return false))[0..len];
    exen.loadState(in) catch return false;
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
