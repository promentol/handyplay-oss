//! SDL3 frontend: a live 240x320 window for the MRP runtime.
//!
//! Boots the dsm engine + a package (default the dsm_gm launcher), then runs the
//! event model: key PRESS/RELEASE + mouse + a one-shot timer the game re-arms each
//! tick (via an SDL timer callback). The RGB565 framebuffer (`vm.gfx.screen`) is
//! uploaded to an SDL texture each frame.
//!
//! Run: zig build run-sdl -- [assets_dir] [package.mrp] [ext_name]
//! Keys: arrows/WASD = D-pad, Enter = OK, Q/[ = left soft, E/] = right soft,
//!       0-9 = keypad, - = *, = = #, Tab = send, Esc = quit.
const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h");
});

const scale = 2;

// types.h MR_KEY_* values.
const MR_KEY_0 = 0;
const MR_KEY_STAR = 10;
const MR_KEY_POUND = 11;
const MR_KEY_UP = 12;
const MR_KEY_DOWN = 13;
const MR_KEY_LEFT = 14;
const MR_KEY_RIGHT = 15;
const MR_KEY_POWER = 16;
const MR_KEY_SOFTLEFT = 17;
const MR_KEY_SOFTRIGHT = 18;
const MR_KEY_SEND = 19;
const MR_KEY_SELECT = 20;
// event codes
const MR_KEY_PRESS = 0;
const MR_KEY_RELEASE = 1;
const MR_MOUSE_DOWN = 2;
const MR_MOUSE_UP = 3;
const MR_MOUSE_MOVE = 12;

const TimerState = struct {
    interval: u32 = 0,
    fire_at: u64 = 0,
    active: bool = false,
};

fn timerStartCb(ctx: ?*anyopaque, ms: u16) void {
    const t: *TimerState = @ptrCast(@alignCast(ctx.?));
    t.interval = ms;
    t.fire_at = 0; // loop computes the deadline
    t.active = true;
}
fn timerStopCb(ctx: ?*anyopaque) void {
    const t: *TimerState = @ptrCast(@alignCast(ctx.?));
    t.active = false;
}

fn mrKey(key: c.SDL_Keycode) ?i32 {
    return switch (key) {
        c.SDLK_0...c.SDLK_9 => MR_KEY_0 + @as(i32, @intCast(key - c.SDLK_0)),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => MR_KEY_SELECT,
        c.SDLK_EQUALS => MR_KEY_POUND,
        c.SDLK_MINUS => MR_KEY_STAR,
        c.SDLK_W, c.SDLK_UP => MR_KEY_UP,
        c.SDLK_S, c.SDLK_DOWN => MR_KEY_DOWN,
        c.SDLK_A, c.SDLK_LEFT => MR_KEY_LEFT,
        c.SDLK_D, c.SDLK_RIGHT => MR_KEY_RIGHT,
        c.SDLK_Q, c.SDLK_LEFTBRACKET => MR_KEY_SOFTLEFT,
        c.SDLK_E, c.SDLK_RIGHTBRACKET => MR_KEY_SOFTRIGHT,
        c.SDLK_TAB => MR_KEY_SEND,
        else => null,
    };
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const assets = if (args.len > 1) args[1] else "assets";
    const pkg = if (args.len > 2) args[2] else "dsm_gm.mrp";
    const ext_name = if (args.len > 3) args[3] else "start.mr";

    try std.posix.chdir(assets);

    var timer_state = TimerState{};
    const vm = try core.Vm.create(gpa);
    defer vm.destroy();
    vm.host = .{ .ctx = &timer_state, .timerStart = timerStartCb, .timerStop = timerStopCb };

    try vm.start("cfunction.ext", pkg, ext_name);

    // --- SDL setup ---
    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const w: c_int = @intCast(core.gfx.screen_w);
    const h: c_int = @intCast(core.gfx.screen_h);
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer("MRP Player", w * scale, h * scale, 0, &window, &renderer)) {
        std.debug.print("SDL_CreateWindowAndRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    }
    defer c.SDL_DestroyRenderer(renderer);
    defer c.SDL_DestroyWindow(window);
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_ShowWindow(window);

    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGB565, c.SDL_TEXTUREACCESS_STREAMING, w, h) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlTexture;
    };
    defer c.SDL_DestroyTexture(tex);

    var down_key: ?i32 = null; // mirror main.c's single-key tracking
    var mouse_down = false;
    var running = true;
    while (running and !vm.quit_requested and !vm.halted) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (ev.key.key == c.SDLK_ESCAPE) {
                        running = false;
                    } else if (!ev.key.repeat and down_key == null) {
                        if (mrKey(ev.key.key)) |code| {
                            down_key = code;
                            _ = vm.event(MR_KEY_PRESS, code, 0);
                        }
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    if (mrKey(ev.key.key)) |code| {
                        if (down_key == code) {
                            down_key = null;
                            _ = vm.event(MR_KEY_RELEASE, code, 0);
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    mouse_down = true;
                    _ = vm.event(MR_MOUSE_DOWN, @intFromFloat(ev.button.x / scale), @intFromFloat(ev.button.y / scale));
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    mouse_down = false;
                    _ = vm.event(MR_MOUSE_UP, @intFromFloat(ev.button.x / scale), @intFromFloat(ev.button.y / scale));
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (mouse_down)
                        _ = vm.event(MR_MOUSE_MOVE, @intFromFloat(ev.motion.x / scale), @intFromFloat(ev.motion.y / scale));
                },
                else => {},
            }
        }

        // Fire the one-shot timer if its deadline elapsed (the game re-arms inside).
        if (timer_state.active) {
            const now = c.SDL_GetTicks();
            if (timer_state.fire_at == 0) {
                timer_state.fire_at = now + timer_state.interval;
            } else if (now >= timer_state.fire_at) {
                timer_state.active = false;
                _ = vm.timer();
            }
        }

        _ = c.SDL_UpdateTexture(tex, null, &vm.gfx.screen, w * 2);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, tex, null, null);
        _ = c.SDL_RenderPresent(renderer);
        c.SDL_Delay(10);
    }

    vm.report();
}
