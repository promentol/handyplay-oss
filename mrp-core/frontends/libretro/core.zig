//! libretro core for mrp-player (.mrp / MediaTek MRP, sky-mobi Mythroad).
//!
//! Runs the native ARM dsm engine in Unicorn (links libunicorn). Builds natively to
//! a `.so`/`.dylib` for RetroArch and any other libretro host.
//!
//! The engine loads packages by NAME from `mythroad/` relative to the cwd, and needs
//! `cfunction.ext` + the `mythroad/` asset tree present (system-directory wiring is a
//! later refinement). `need_fullpath=true`: we take the basename of game.path and boot
//! that package (the .mrp must already live in mythroad/).
const std = @import("std");
const core = @import("core");
const lr = @import("libretro.zig");
const bios = @import("bios.zig");

const gpa = std.heap.c_allocator;

/// Single source of truth for frame timing: we report `FPS` to the frontend via av_info
/// and advance the sim by exactly `FRAME_MS` (= 1000/FPS) per `retro_run`, so the game
/// clock tracks the libretro frame rate. MRP games re-arm their own one-shot timer
/// (`timerStart`), so 30 fps × ~33 ms reproduces the real-hardware cadence.
const FPS: f64 = 30.0;
const FRAME_MS: u32 = @intFromFloat(@round(1000.0 / FPS));

var env_cb: lr.EnvironmentFn = null;
var video_cb: lr.VideoRefreshFn = null;
var input_poll_cb: lr.InputPollFn = null;
var input_state_cb: lr.InputStateFn = null;

var g_vm: ?*core.Vm = null;
var prev_buttons: [12]bool = [_]bool{false} ** 12;

// One-shot timer the game re-arms (frontend state — included in save-states below).
var timer_remaining: i64 = 0;
var timer_active: bool = false;
fn timerStartCb(_: ?*anyopaque, ms: u16) void {
    timer_remaining = ms;
    timer_active = true;
}
fn timerStopCb(_: ?*anyopaque) void {
    timer_active = false;
}

// MR_KEY_* + event codes (types.h). mrp_event(code, p0, p1).
const MR_KEY = struct {
    const UP = 12;
    const DOWN = 13;
    const LEFT = 14;
    const RIGHT = 15;
    const SOFTLEFT = 17;
    const SOFTRIGHT = 18;
    const SELECT = 20;
};
const EV_PRESS = 0;
const EV_RELEASE = 1;
const KEYMAP = [_]struct { id: c_uint, code: i32 }{
    .{ .id = lr.DEVICE_ID_JOYPAD_UP, .code = MR_KEY.UP },
    .{ .id = lr.DEVICE_ID_JOYPAD_DOWN, .code = MR_KEY.DOWN },
    .{ .id = lr.DEVICE_ID_JOYPAD_LEFT, .code = MR_KEY.LEFT },
    .{ .id = lr.DEVICE_ID_JOYPAD_RIGHT, .code = MR_KEY.RIGHT },
    .{ .id = lr.DEVICE_ID_JOYPAD_A, .code = MR_KEY.SELECT },
    .{ .id = lr.DEVICE_ID_JOYPAD_B, .code = MR_KEY.SELECT },
    .{ .id = lr.DEVICE_ID_JOYPAD_L, .code = MR_KEY.SOFTLEFT },
    .{ .id = lr.DEVICE_ID_JOYPAD_R, .code = MR_KEY.SOFTRIGHT },
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
        .library_name = "mrp-player",
        .library_version = "0.1",
        .valid_extensions = "mrp",
        .need_fullpath = true,
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
export fn retro_reset() callconv(.c) void {}

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..];
    }
    return path;
}

fn systemDir() ?[]const u8 {
    var p: ?[*:0]const u8 = null;
    if (env_cb) |cb| if (cb(lr.ENVIRONMENT_GET_SYSTEM_DIRECTORY, @ptrCast(&p)))
        if (p) |s| return std.mem.sliceTo(s, 0);
    return null;
}

/// Copy a host/MEMFS file `src` to MEMFS path `dst` (creating parent dirs).
fn copyFile(src: []const u8, dst: []const u8) !void {
    const data = try std.fs.cwd().readFileAlloc(gpa, src, 32 << 20);
    defer gpa.free(data);
    if (std.fs.path.dirname(dst)) |d| std.fs.cwd().makePath(d) catch {};
    const f = try std.fs.cwd().createFile(dst, .{});
    defer f.close();
    try f.writeAll(data);
}

// Required firmware, identified by MD5 (filename-independent). The dsm engine
// (cfunction.ext) + system fonts; user-supplied firmware.
const BIOS = [_]bios.Req{
    .{ .md5 = "b87d3bca0bd693861bfddd1fb430eb95", .dst = "cfunction.ext" },
    .{ .md5 = "f21f21559a38f8927597cc2088525072", .dst = "mythroad/system/gb16.uc2" },
    .{ .md5 = "c2ead6ea893b43cf9c661f6d78655736", .dst = "mythroad/system/gb12.uc2" },
};

export fn retro_load_game(game: ?*const lr.GameInfo) callconv(.c) bool {
    const g = game orelse return false;
    const path = std.mem.sliceTo(g.path orelse return false, 0);

    var fmt: c_uint = lr.PIXEL_FORMAT_RGB565;
    if (env_cb) |cb| _ = cb(lr.ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);

    // Locate + install BIOS from the system dir by MD5 (firmware required).
    const sysdir = systemDir() orelse "/";
    bios.install(gpa, sysdir, &BIOS) catch return false;

    // Content: the engine opens mythroad/<pkg>, so stage the game there.
    const name = basename(path);
    var dstbuf: [512]u8 = undefined;
    const dst = std.fmt.bufPrint(&dstbuf, "mythroad/{s}", .{name}) catch return false;
    copyFile(path, dst) catch return false;

    const vm = core.Vm.create(gpa) catch return false;
    vm.host = .{ .timerStart = timerStartCb, .timerStop = timerStopCb };
    g_vm = vm;
    timer_active = false;
    timer_remaining = 0;
    prev_buttons = [_]bool{false} ** 12;
    vm.start("cfunction.ext", name, "start.mr") catch return false;
    return true;
}

export fn retro_unload_game() callconv(.c) void {
    if (g_vm) |vm| {
        vm.destroy();
        g_vm = null;
    }
}

export fn retro_run() callconv(.c) void {
    const vm = g_vm orelse return;
    const delta: u32 = FRAME_MS;
    vm.clock_ms +%= delta;

    if (input_poll_cb) |poll| poll();
    if (input_state_cb) |state| {
        for (KEYMAP) |k| {
            const pressed = state(0, lr.DEVICE_JOYPAD, 0, k.id) != 0;
            if (pressed and !prev_buttons[k.id]) _ = vm.event(EV_PRESS, k.code, 0);
            if (!pressed and prev_buttons[k.id]) _ = vm.event(EV_RELEASE, k.code, 0);
            prev_buttons[k.id] = pressed;
        }
    }

    if (timer_active) {
        timer_remaining -= delta;
        if (timer_remaining <= 0) {
            timer_active = false;
            _ = vm.timer();
        }
    }

    if (video_cb) |refresh|
        refresh(&vm.gfx.screen, core.gfx.screen_w, core.gfx.screen_h, core.gfx.screen_w * 2);
}

// --- save-states (VM blob + the frontend timer state appended) -------------
const TIMER_BYTES = 16;
export fn retro_serialize_size() callconv(.c) usize {
    const vm = g_vm orelse return 0;
    return core.savestate.size(vm) + TIMER_BYTES;
}
export fn retro_serialize(data: ?*anyopaque, len: usize) callconv(.c) bool {
    const vm = g_vm orelse return false;
    const out = @as([*]u8, @ptrCast(data orelse return false))[0..len];
    _ = core.savestate.save(vm, out) catch return false;
    // Append the timer at the fixed bound offset (so unserialize reads the same spot).
    const off = core.savestate.size(vm);
    if (off + TIMER_BYTES > len) return false;
    std.mem.writeInt(i64, out[off..][0..8], timer_remaining, .little);
    std.mem.writeInt(u32, out[off + 8 ..][0..4], @intFromBool(timer_active), .little);
    return true;
}
export fn retro_unserialize(data: ?*const anyopaque, len: usize) callconv(.c) bool {
    const vm = g_vm orelse return false;
    const in = @as([*]const u8, @ptrCast(data orelse return false))[0..len];
    core.savestate.load(vm, in) catch return false;
    // timer state is appended right after the VM blob (size = savestate.size headroom)
    const n = core.savestate.size(vm);
    if (n + TIMER_BYTES <= len) {
        timer_remaining = std.mem.readInt(i64, in[n..][0..8], .little);
        timer_active = std.mem.readInt(u32, in[n + 8 ..][0..4], .little) != 0;
    }
    return true;
}

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
