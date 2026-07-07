//! SDL3 frontend: live 240x320 window for the MRE emulator.
//!
//! The core renders an RGB565 framebuffer (`vm.gfx.screen`), which is uploaded
//! directly into an SDL RGB565 streaming texture each frame. The loop drives the
//! MRE event model (CREATE/ACTIVE/PAINT + periodic timer ticks) and forwards key
//! presses to the registered keyboard callback.
//!
//! Run: zig build run-sdl -- "games/Doodle jump trail version.vxp"
//! Keys: arrows = D-pad, Z/Enter = OK, A = left softkey, S = right softkey,
//!       0-9/*/# = keypad, Esc = quit.
const std = @import("std");
const core = @import("core");
const audio_sink = @import("audio.zig");

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h");
});

const scale = 2;

fn mreKey(key: c.SDL_Keycode) ?i32 {
    return switch (key) {
        c.SDLK_UP => -1,
        c.SDLK_DOWN => -2,
        c.SDLK_LEFT => -3,
        c.SDLK_RIGHT => -4,
        c.SDLK_Z, c.SDLK_RETURN, c.SDLK_SPACE => -5, // OK / select
        c.SDLK_A, c.SDLK_Q => -6, // left softkey
        c.SDLK_S, c.SDLK_W => -7, // right softkey
        c.SDLK_BACKSPACE => -8, // clear
        c.SDLK_0...c.SDLK_9 => @intCast(key), // ASCII '0'-'9' == VM_KEY_NUM0-9
        c.SDLK_ASTERISK => 42,
        c.SDLK_HASH => 35,
        else => null,
    };
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        std.debug.print("usage: mre-sdl <file.vxp>\n", .{});
        return error.BadArgs;
    }

    const file = try std.fs.cwd().readFileAlloc(gpa, args[1], 64 * 1024 * 1024);
    defer gpa.free(file);

    // Mirror the .vxp into the emulated fs so games can re-open themselves.
    std.fs.cwd().makePath("fs/c") catch {};
    std.fs.cwd().makePath("fs/d") catch {};
    std.fs.cwd().makePath("fs/e") catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = "fs/c/app.vxp", .data = file });

    var mem = try core.Memory.init(gpa, 32 * 1024 * 1024);
    defer mem.deinit();
    const vm = try core.Vm.create(gpa, &mem);
    defer vm.destroy();

    try vm.loadAndStart(file);
    vm.deliverSysEvent(core.vm.VM_MSG_ACTIVE, 0);

    // --- SDL setup ---
    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // Audio sink (non-fatal if no device: core falls back to silent timing).
    audio_sink.init();
    defer audio_sink.deinit();

    const w: c_int = @intCast(core.gfx.screen_w);
    const h: c_int = @intCast(core.gfx.screen_h);
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer("MRE Player", w * scale, h * scale, 0, &window, &renderer)) {
        std.debug.print("SDL_CreateWindowAndRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    }
    defer c.SDL_DestroyRenderer(renderer);
    defer c.SDL_DestroyWindow(window);

    // Grab keyboard focus / foreground activation (needed when launched detached).
    _ = c.SDL_RaiseWindow(window);
    _ = c.SDL_ShowWindow(window);

    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGB565, c.SDL_TEXTUREACCESS_STREAMING, w, h) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlTexture;
    };
    defer c.SDL_DestroyTexture(tex);

    // Frame-rate cap. Games drive their loop from a timer (e.g. Dragon Fire asks for
    // 10ms = 100fps), but real MediaTek phones couldn't sustain that and ran these
    // 240x320 titles at ~20-30fps; movement is a fixed step per timer fire, so it was
    // tuned to that slow rate. Uncapped we'd fire once per host frame (~60fps) and the
    // game feels ~2x too fast. Capping the frame time throttles the game-step rate to
    // match device feel. Override with MRE_FPS (0 = uncapped).
    const target_fps: u32 = blk: {
        if (c.SDL_getenv("MRE_FPS")) |s| break :blk std.fmt.parseInt(u32, std.mem.span(s), 10) catch 30;
        break :blk 30;
    };
    const frame_ms: u32 = if (target_fps == 0) 0 else 1000 / target_fps;
    var last: u64 = c.SDL_GetTicks();
    var frame: u64 = 0;
    var pace_t0: u64 = last;
    var pace_f0: u64 = 0;
    var pace_fires0: u32 = 0;
    // Synthesize a minimum key-hold: deliver DOWN immediately, then auto-release a
    // few frames later (regardless of physical release). The game polls key state at
    // ~75ms, so a too-fast tap would set+clear the flag between timer fires and be
    // missed; holding ~8 frames guarantees the press spans a poll.
    var held_code: ?i32 = null;
    var release_at: u64 = 0;
    const hold_frames: u64 = 8;
    var running = true;
    while (running) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (ev.key.key == c.SDLK_ESCAPE) {
                        running = false;
                    } else if (!ev.key.repeat) {
                        if (mreKey(ev.key.key)) |code| {
                            // release any held key first
                            if (held_code) |hc| vm.deliverKey(core.vm.VM_KEY_EVENT_UP, hc);
                            vm.deliverKey(core.vm.VM_KEY_EVENT_DOWN, code);
                            held_code = code;
                            release_at = frame + hold_frames;
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => vm.deliverPen(core.vm.VM_PEN_EVENT_TAP, @intFromFloat(ev.button.x / scale), @intFromFloat(ev.button.y / scale)),
                c.SDL_EVENT_MOUSE_BUTTON_UP => vm.deliverPen(core.vm.VM_PEN_EVENT_RELEASE, @intFromFloat(ev.button.x / scale), @intFromFloat(ev.button.y / scale)),
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (ev.motion.state != 0) // a button is held
                        vm.deliverPen(core.vm.VM_PEN_EVENT_MOVE, @intFromFloat(ev.motion.x / scale), @intFromFloat(ev.motion.y / scale));
                },
                else => {},
            }
        }

        // Advance the VM: timers + a repaint.
        const now = c.SDL_GetTicks();
        const delta: u32 = @intCast(@min(now - last, 100));
        last = now;
        // The game's timer callback (its main loop) processes input and redraws
        // itself each tick. We must NOT deliver VM_MSG_PAINT per frame — doing so
        // clobbers the timer-driven menu state and swallows input.
        vm.tick(delta);
        audio_sink.pump();
        // Auto-release the held key after the minimum hold.
        if (held_code) |hc| {
            if (frame >= release_at) {
                vm.deliverKey(core.vm.VM_KEY_EVENT_UP, hc);
                held_code = null;
            }
        }
        frame += 1;
        // Pacing diagnostic: once per real second, report host FPS and game-step
        // (timer-fire) rate. Set MRE_PACE_LOG=1.
        if (c.SDL_getenv("MRE_PACE_LOG") != null) {
            if (now - pace_t0 >= 1000) {
                var active_timers: u32 = 0;
                for (vm.timers) |t| {
                    if (t.active) active_timers += 1;
                }
                std.debug.print("[pace] fps={d} timer_fires/s={d} active_timers={d} delta={d}ms\n", .{ frame - pace_f0, vm.timer_fires - pace_fires0, active_timers, delta });
                pace_t0 = now;
                pace_f0 = frame;
                pace_fires0 = vm.timer_fires;
            }
        }
        // Direct back-buffer only when the game isn't using the layer model.
        if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();

        // Upload RGB565 framebuffer and present.
        _ = c.SDL_UpdateTexture(tex, null, vm.gfx.screen.ptr, w * 2);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, tex, null, null);
        _ = c.SDL_RenderPresent(renderer);
        // Frame limiter: sleep the remainder of the target frame so the game-step
        // rate (one timer fire per frame) matches real-device pacing. `now` was
        // sampled at the top of this iteration.
        if (frame_ms != 0) {
            const work: u64 = c.SDL_GetTicks() - now;
            if (work < frame_ms) c.SDL_Delay(@intCast(frame_ms - work));
        }
    }

    // Dump the final on-screen frame so its state can be inspected after exit.
    dumpPpm(vm, "sdl_final.ppm") catch {};
    // Report which called natives are stubbed/unimplemented.
    vm.bridge.report();
}

fn dumpPpm(vm: *core.Vm, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var hb: [32]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&hb, "P6\n{d} {d}\n255\n", .{ core.gfx.screen_w, core.gfx.screen_h }));
    var row: [core.gfx.screen_w * 3]u8 = undefined;
    var y: u32 = 0;
    while (y < core.gfx.screen_h) : (y += 1) {
        var x: u32 = 0;
        while (x < core.gfx.screen_w) : (x += 1) {
            const px = vm.gfx.screen[y * core.gfx.screen_w + x];
            row[x * 3 + 0] = core.gfx.getRed(px);
            row[x * 3 + 1] = core.gfx.getGreen(px);
            row[x * 3 + 2] = core.gfx.getBlue(px);
        }
        try file.writeAll(&row);
    }
}
