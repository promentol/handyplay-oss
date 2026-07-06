//! SDL3 ExEn demo: 128x141 window with menus exposed via SDL3's tray API
//! (SDL3 has no native window menu-bar API; the tray icon's menu is the
//! closest equivalent on macOS — it lives in the system menu bar at top
//! right and opens a real native dropdown).
//!
//! The menu structure mirrors the Win32 simulator (decoded from WinMain
//! at ref:34810 and the WM_COMMAND dispatcher sub_43A073 at 35369).
//!
//! Build (macOS, Homebrew SDL3):
//!   zig build-exe sdl_demo.zig -lc -lSDL3 \
//!     -I/opt/homebrew/include -L/opt/homebrew/lib
//! Run:
//!   ./sdl_demo
//!
//! Keyboard:
//!   Esc      quit

const std = @import("std");
const exen = @import("core");
const natives = @import("natives");
const audio = @import("audio.zig");
const haptic = @import("haptic.zig");
const bios = @import("bios");

// Required firmware (by MD5), user-supplied (set HANDYPLAY_BIOS) — not bundled.
// Located + installed to the cwd paths exen.boot reads; missing = hard error.
const BIOS_REQ = [_]bios.Req{
    .{ .md5 = "870bef21d6f269e3e3d91943c66de8e8", .dst = "assets/unk_4494F0.bin" },
    .{ .md5 = "79fda67fa42bf40a12c94c0d7fc82f87", .dst = "assets/off_454498.bin" },
};

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h");
});

// Simulated-device dimensions. Set from the [Manuf.NNN] profile after
// exen.boot() returns. Sensible default = TRIUM M6B (128×141) so the
// constants are defined for use before boot completes.
var exen_w: c_int = 128;
var exen_h: c_int = 141;

const State = struct {
    grid: bool = false,
    memory: bool = false,
    vmmemory: bool = false,
    statistics: bool = false,
    capture: bool = false,
    log: bool = false,
    log_exen: bool = false,
    log_manuf: bool = false,
    timer_manual: bool = false, // false = Auto
    quit: bool = false,
    last_tick_ms: u64 = 0,
    frame_count: u64 = 0,

    // Tray entry handles, so callbacks can update check state.
    grid_entry: ?*c.SDL_TrayEntry = null,
    memory_entry: ?*c.SDL_TrayEntry = null,
    vmmemory_entry: ?*c.SDL_TrayEntry = null,
    statistics_entry: ?*c.SDL_TrayEntry = null,
    capture_entry: ?*c.SDL_TrayEntry = null,
    log_entry: ?*c.SDL_TrayEntry = null,
    log_exen_entry: ?*c.SDL_TrayEntry = null,
    log_manuf_entry: ?*c.SDL_TrayEntry = null,
    timer_auto_entry: ?*c.SDL_TrayEntry = null,
    timer_manual_entry: ?*c.SDL_TrayEntry = null,

    // Device switcher: tray-callback signals via `device_pending`; the
    // main loop performs the heavy work (shutdown/boot/reload + SDL
    // texture rebuild) because the callback may fire on a non-main
    // thread on macOS.
    device_pending: ?u32 = null,
    device_entries: [16]?*c.SDL_TrayEntry = [_]?*c.SDL_TrayEntry{null} ** 16,
};

var g_state: State = .{};

// Shared with the Device tray callback so the main loop can reload.
var g_ini_path: []const u8 = "reference/simulator.ini";
var g_exn_path: []const u8 = "samples/TheTerminator.exn";

// Synthetic-key injection for headless verification. Set via
// `--auto-key=DOWN@8000,FIRE@10000` — comma-separated KEY@MS pairs.
// Each entry fires once at the specified offset from boot; release
// follows 200ms later. Keys: UP|DOWN|LEFT|RIGHT|FIRE.
const AutoKey = struct {
    code: i32,
    fire_at: u64,
    fired: bool = false,
    release_at: u64 = 0,
};
var g_auto_keys: [8]AutoKey = [_]AutoKey{.{ .code = 0, .fire_at = 0 }} ** 8;
var g_auto_keys_count: u32 = 0;
var g_boot_ms: u64 = 0;
// ── Catalog host (exen.setCatalogHost) ─────────────────────────────────────
// launchGame: consult <flashDir>/catalog_games.ini (lines "id=path.exn");
// a hit stashes the path for the main loop to apply at the tick boundary
// (the native runs INSIDE exen.tick — swapping the gamelet immediately
// would deinit the classes the VM is executing). editBox: request SDL
// text input; the event loop collects chars until Return and delivers
// via exen.catalogEditBoxResult.
var g_launch_path_buf: [512]u8 = undefined;
var g_launch_pending: ?[]const u8 = null;
var g_editbox_active: bool = false;
var g_editbox_max: u8 = 6;
var g_editbox_buf: [16]u8 = undefined;
var g_editbox_len: usize = 0;
var g_editbox_started: bool = false;

fn catalogLaunchGame(id: u16) bool {
    var path_buf: [512]u8 = undefined;
    const ini_path = std.fmt.bufPrint(&path_buf, "{s}catalog_games.ini", .{exen.flashDir()}) catch return false;
    const f = std.fs.cwd().openFile(ini_path, .{}) catch {
        std.debug.print("[catalog] no {s} — cannot map game id {d}\n", .{ ini_path, id });
        return false;
    };
    defer f.close();
    var data: [4096]u8 = undefined;
    const n = f.readAll(&data) catch return false;
    var it = std.mem.splitScalar(u8, data[0..n], '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_id = std.fmt.parseInt(u16, std.mem.trim(u8, line[0..eq], " \t"), 10) catch continue;
        if (key_id != id) continue;
        const path = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (path.len == 0 or path.len > g_launch_path_buf.len) return false;
        @memcpy(g_launch_path_buf[0..path.len], path);
        g_launch_pending = g_launch_path_buf[0..path.len];
        std.debug.print("[catalog] launch id {d} → {s} (applied at tick boundary)\n", .{ id, path });
        return true;
    }
    std.debug.print("[catalog] game id {d} not in catalog_games.ini\n", .{id});
    return false;
}

fn catalogEditBox(prompt: []const u8, max_len: u8) void {
    g_editbox_active = true;
    g_editbox_max = @min(max_len, @as(u8, @intCast(g_editbox_buf.len)));
    g_editbox_len = 0;
    std.debug.print("[catalog] edit box open (prompt=\"{s}\", max {d} chars, type + Return)\n", .{ prompt, g_editbox_max });
}

// Scheduled framebuffer captures: --screenshot-at=NAME@MS,NAME2@MS2.
// Fires once at the given elapsed ms, writes a BMP. Useful for headless
// verification of gameplay rendering without manual key input.
const Capture = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    fire_at: u64,
    fired: bool = false,
};
var g_captures: [8]Capture = [_]Capture{.{ .fire_at = 0 }} ** 8;
var g_captures_count: u32 = 0;

// `--quit-at=MS` — request a clean quit at the given elapsed ms (0 = disabled).
// Runs the normal shutdown path (`defer exen.shutdown()`), so DebugAllocator's
// leak report fires — the headless acceptance test for the allocator work.
var g_quit_at_ms: u64 = 0;

// `--savestate-at=MS` — one-shot in-place save→load round-trip (0 = disabled).
// Exercises the FBA-free serialization (slab + class statics + object heap tables)
// against a live booted gamelet, and checks the framebuffer is bit-identical after
// the reload. Acceptance test for the save-state rewrite.
var g_savestate_at_ms: u64 = 0;
var g_savestate_done: bool = false;

fn cbToggle(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    const flag: *bool = @ptrCast(@alignCast(userdata));
    flag.* = !flag.*;
    if (entry) |e| c.SDL_SetTrayEntryChecked(e, flag.*);
}

fn cbDevice(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = entry;
    const idx: u32 = @intCast(@intFromPtr(userdata));
    g_state.device_pending = idx;
}

fn refreshDeviceChecks(active: u32) void {
    for (g_state.device_entries, 1..) |entry_opt, idx| {
        if (entry_opt) |e| {
            c.SDL_SetTrayEntryChecked(e, @as(u32, @intCast(idx)) == active);
        }
    }
}

fn cbTimerAuto(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    g_state.timer_manual = false;
    if (g_state.timer_auto_entry) |e| c.SDL_SetTrayEntryChecked(e, true);
    if (g_state.timer_manual_entry) |e| c.SDL_SetTrayEntryChecked(e, false);
}

fn cbTimerManual(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    g_state.timer_manual = true;
    if (g_state.timer_auto_entry) |e| c.SDL_SetTrayEntryChecked(e, false);
    if (g_state.timer_manual_entry) |e| c.SDL_SetTrayEntryChecked(e, true);
}

fn cbResetEeprom(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    std.debug.print("[menu] Reset EEPROM\n", .{});
}

fn cbReset(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    std.debug.print("[menu] Reset\n", .{});
}

fn cbOpen(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    std.debug.print("[menu] Open... (TODO)\n", .{});
}

fn cbQuit(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = userdata;
    _ = entry;
    g_state.quit = true;
}

const BUTTON = c.SDL_TRAYENTRY_BUTTON;
const CHECKBOX = c.SDL_TRAYENTRY_CHECKBOX;
const SUBMENU = c.SDL_TRAYENTRY_SUBMENU;

fn buildTrayMenu(tray: *c.SDL_Tray) void {
    const root = c.SDL_CreateTrayMenu(tray) orelse return;

    // File
    const file_entry = c.SDL_InsertTrayEntryAt(root, -1, "File", SUBMENU);
    if (file_entry) |fe| {
        if (c.SDL_CreateTraySubmenu(fe)) |file| {
            if (c.SDL_InsertTrayEntryAt(file, -1, "Open...", BUTTON)) |e|
                c.SDL_SetTrayEntryCallback(e, cbOpen, null);
            if (c.SDL_InsertTrayEntryAt(file, -1, "Reset", BUTTON)) |e|
                c.SDL_SetTrayEntryCallback(e, cbReset, null);
            if (c.SDL_InsertTrayEntryAt(file, -1, "Reset EEPROM", BUTTON)) |e|
                c.SDL_SetTrayEntryCallback(e, cbResetEeprom, null);
            _ = c.SDL_InsertTrayEntryAt(file, -1, null, BUTTON); // separator
            if (c.SDL_InsertTrayEntryAt(file, -1, "Quit", BUTTON)) |e|
                c.SDL_SetTrayEntryCallback(e, cbQuit, null);
        }
    }

    // Device (one entry per populated [Manuf.NNN])
    if (c.SDL_InsertTrayEntryAt(root, -1, "Device", SUBMENU)) |de| {
        if (c.SDL_CreateTraySubmenu(de)) |device| {
            const active = exen.currentManufIndex();
            var label_storage: [16][80:0]u8 = undefined;
            var i: u32 = 1;
            while (i <= 16) : (i += 1) {
                const name = exen.deviceName(i) orelse continue;
                const w = exen.deviceWidth(i) orelse 0;
                const h = exen.deviceHeight(i) orelse 0;
                const buf = &label_storage[i - 1];
                const label = std.fmt.bufPrintZ(buf, "{d} - {s} ({d}x{d})", .{ i, name, w, h }) catch continue;
                if (c.SDL_InsertTrayEntryAt(device, -1, label.ptr, CHECKBOX)) |e| {
                    g_state.device_entries[i - 1] = e;
                    c.SDL_SetTrayEntryCallback(e, cbDevice, @ptrFromInt(@as(usize, i)));
                    c.SDL_SetTrayEntryChecked(e, i == active);
                }
            }
        }
    }

    // View
    if (c.SDL_InsertTrayEntryAt(root, -1, "View", SUBMENU)) |ve| {
        if (c.SDL_CreateTraySubmenu(ve)) |view| {
            const toggles = .{
                .{ "Grid", &g_state.grid, &g_state.grid_entry },
                .{ "Memory", &g_state.memory, &g_state.memory_entry },
                .{ "VM Memory", &g_state.vmmemory, &g_state.vmmemory_entry },
                .{ "Statistics", &g_state.statistics, &g_state.statistics_entry },
                .{ "Capture", &g_state.capture, &g_state.capture_entry },
                .{ "Log", &g_state.log, &g_state.log_entry },
                .{ "Log ExEn", &g_state.log_exen, &g_state.log_exen_entry },
                .{ "Log Manuf", &g_state.log_manuf, &g_state.log_manuf_entry },
            };
            inline for (toggles) |t| {
                if (c.SDL_InsertTrayEntryAt(view, -1, t[0], CHECKBOX)) |e| {
                    t[2].* = e;
                    c.SDL_SetTrayEntryCallback(e, cbToggle, @ptrCast(t[1]));
                    c.SDL_SetTrayEntryChecked(e, t[1].*);
                }
            }
        }
    }

    // Timer (radio-like pair: Auto / Manual)
    if (c.SDL_InsertTrayEntryAt(root, -1, "Timer", SUBMENU)) |te| {
        if (c.SDL_CreateTraySubmenu(te)) |timer| {
            if (c.SDL_InsertTrayEntryAt(timer, -1, "Auto", CHECKBOX)) |e| {
                g_state.timer_auto_entry = e;
                c.SDL_SetTrayEntryCallback(e, cbTimerAuto, null);
                c.SDL_SetTrayEntryChecked(e, !g_state.timer_manual);
            }
            if (c.SDL_InsertTrayEntryAt(timer, -1, "Manual", CHECKBOX)) |e| {
                g_state.timer_manual_entry = e;
                c.SDL_SetTrayEntryCallback(e, cbTimerManual, null);
                c.SDL_SetTrayEntryChecked(e, g_state.timer_manual);
            }
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Require BIOS: locate the firmware by MD5 in HANDYPLAY_BIOS (default ./assets,
    // where the dev tree keeps the .bin firmware) and install it; fail clearly if absent.
    const bios_dir = std.posix.getenv("HANDYPLAY_BIOS") orelse "assets";
    bios.install(allocator, bios_dir, &BIOS_REQ) catch |err| {
        std.debug.print("[bios] required firmware not found in '{s}' ({s}).\n" ++
            "  Set HANDYPLAY_BIOS to your firmware dir (needs simulator.ini + builtins by MD5).\n",
            .{ bios_dir, @errorName(err) });
        return err;
    };

    // Register the audio/haptic backends BEFORE boot: the gamelet's init
    // (run inside boot/loadExn) can already call playMelody/playVibrator, so
    // the backend function pointers must be installed first or those early
    // melodies hit a null backend and are silently dropped. register() only
    // installs pointers — the SDL audio device is opened lazily on first play.
    // (The matching deinit() defers live after SDL init below, so they run
    // BEFORE SDL_Quit in the LIFO defer order.)
    audio.register();
    haptic.register();

    // Boot the VM: parse simulator.ini, init state, fire opcode 0x600 (VM_INIT)
    // through the real dispatcher, then optionally load argv[1] (.exn).
    try exen.boot(allocator, g_ini_path);
    defer exen.shutdown();

    // Wire the per-class native dispatcher. Must happen AFTER boot()
    // (which initialises the VM with a default stub) and BEFORE
    // loadExn (which triggers Bootstrap.init → NATIVE invocations).
    exen.setNativeDispatcher(&natives.dispatch);
    exen.setNativeNames(&natives.native_names);
    exen.setCatalogHost(.{ .launchGame = &catalogLaunchGame, .editBox = &catalogEditBox });

    // Pick the .exn path from argv[1], defaulting to TheTerminator.exn.
    // Persist it for the Device tray callback so a device swap can
    // re-load the same gamelet.
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next(); // exe name
        var exn_path_arg: []const u8 = "samples/TheTerminator.exn";
        while (args.next()) |a| {
            // `--trace` / `-t` flips on the per-opcode trace line. Off
            // by default — adds one line per opcode, multiplying the
            // log volume ~50×. Useful for chasing PC alignment / stack
            // corruption bugs.
            if (std.mem.eql(u8, a, "--trace") or std.mem.eql(u8, a, "-t")) {
                exen.interp.Vm.trace = true;
                std.debug.print("[opt] per-opcode trace enabled\n", .{});
                continue;
            }
            // `--trace-method=HEX` — restrict per-opcode trace to one
            // method (matched by method.hash). Useful for inspecting a
            // single hot loop without the whole tick's noise.
            if (std.mem.startsWith(u8, a, "--trace-method=")) {
                const hex = a["--trace-method=".len..];
                const hex_stripped = if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X"))
                    hex[2..]
                else
                    hex;
                const v = std.fmt.parseInt(u32, hex_stripped, 16) catch {
                    std.debug.print("[opt] --trace-method needs a hex hash (got '{s}')\n", .{hex});
                    continue;
                };
                exen.interp.Vm.trace = true;
                exen.interp.Vm.trace_only_method_hash = v;
                std.debug.print("[opt] per-opcode trace enabled, restricted to method=0x{x:0>8}\n", .{v});
                continue;
            }
            // `--auto-key=DOWN@8000,FIRE@10000` → comma-separated
            // KEY@MS pairs, each fired once at the given offset from
            // boot. Lets a headless `gtimeout` run prove key delivery
            // without real SDL events.
            if (std.mem.startsWith(u8, a, "--auto-key=")) {
                var it = std.mem.splitScalar(u8, a["--auto-key=".len..], ',');
                while (it.next()) |spec| {
                    if (spec.len == 0) continue;
                    const at = std.mem.indexOfScalar(u8, spec, '@') orelse {
                        std.debug.print("[opt] --auto-key entry '{s}' needs KEY@MS\n", .{spec});
                        continue;
                    };
                    const key_str = spec[0..at];
                    const ms_str = spec[at + 1 ..];
                    const code: i32 = if (std.mem.eql(u8, key_str, "UP"))    exen.KEY_UP
                        else if (std.mem.eql(u8, key_str, "DOWN"))  exen.KEY_DOWN
                        else if (std.mem.eql(u8, key_str, "LEFT"))  exen.KEY_LEFT
                        else if (std.mem.eql(u8, key_str, "RIGHT")) exen.KEY_RIGHT
                        else if (std.mem.eql(u8, key_str, "FIRE"))  exen.KEY_FIRE
                        else if (std.mem.eql(u8, key_str, "SOFT1")) exen.KEY_SOFT1
                        else if (std.mem.eql(u8, key_str, "SOFT2")) exen.KEY_SOFT2
                        // Single digit / '*' / '#' → raw J2ME key code (ASCII).
                        else if (key_str.len == 1) @as(i32, key_str[0])
                        else 0;
                    const ms: u64 = std.fmt.parseInt(u64, ms_str, 10) catch 0;
                    if (g_auto_keys_count < g_auto_keys.len) {
                        g_auto_keys[g_auto_keys_count] = .{ .code = code, .fire_at = ms };
                        g_auto_keys_count += 1;
                        std.debug.print("[opt] auto-key[{d}]: {s}(code={d}) at +{d}ms\n", .{ g_auto_keys_count - 1, key_str, code, ms });
                    }
                }
                continue;
            }
            // `--screenshot-at=gameplay@15000,end@20000` → comma-separated
            // NAME@MS pairs. Each fires once, writes `NAME.bmp` into cwd.
            if (std.mem.startsWith(u8, a, "--screenshot-at=")) {
                var it = std.mem.splitScalar(u8, a["--screenshot-at=".len..], ',');
                while (it.next()) |spec| {
                    if (spec.len == 0) continue;
                    const at = std.mem.indexOfScalar(u8, spec, '@') orelse continue;
                    const name = spec[0..at];
                    const ms_str = spec[at + 1 ..];
                    const ms: u64 = std.fmt.parseInt(u64, ms_str, 10) catch 0;
                    if (g_captures_count < g_captures.len and name.len < 32) {
                        var cap: Capture = .{ .fire_at = ms };
                        @memcpy(cap.name[0..name.len], name);
                        cap.name_len = @intCast(name.len);
                        g_captures[g_captures_count] = cap;
                        g_captures_count += 1;
                        std.debug.print("[opt] screenshot[{d}]: {s} at +{d}ms\n", .{ g_captures_count - 1, name, ms });
                    }
                }
                continue;
            }
            // `--quit-at=MS` → clean quit at elapsed MS (headless leak-check).
            if (std.mem.startsWith(u8, a, "--quit-at=")) {
                g_quit_at_ms = std.fmt.parseInt(u64, a["--quit-at=".len..], 10) catch 0;
                std.debug.print("[opt] quit-at: +{d}ms\n", .{g_quit_at_ms});
                continue;
            }
            // `--savestate-at=MS` → one-shot save→load round-trip at elapsed MS.
            if (std.mem.startsWith(u8, a, "--savestate-at=")) {
                g_savestate_at_ms = std.fmt.parseInt(u64, a["--savestate-at=".len..], 10) catch 0;
                std.debug.print("[opt] savestate-at: +{d}ms\n", .{g_savestate_at_ms});
                continue;
            }
            exn_path_arg = a;
        }
        g_exn_path = try allocator.dupe(u8, exn_path_arg);
        exen.loadExn(g_exn_path) catch |err| {
            std.debug.print("loadExn({s}) failed: {s}\n", .{ g_exn_path, @errorName(err) });
        };
    }

    // Simulated LCD dimensions come straight from the current
    // [Manuf.NNN] profile (e.g. 101×80 for Manuf.002). Window size
    // matches LCD 1:1 — no zoom.
    exen_w = @intCast(exen.screenWidth());
    exen_h = @intCast(exen.screenHeight());
    std.debug.print("[sdl] simulated LCD: {d}x{d}\n", .{ exen_w, exen_h });

    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // Backends were registered before boot (above); tear their SDL resources
    // down here so these defers run BEFORE `SDL_Quit` (LIFO) — destroying the
    // audio stream after SDL_Quit would segfault.
    defer audio.deinit();
    defer haptic.deinit();

    var title_buf: [80]u8 = undefined;
    const dev_idx = exen.currentManufIndex();
    const dev_name = exen.deviceName(dev_idx) orelse "?";
    const title = try std.fmt.bufPrintZ(&title_buf, "ExEn {d}-{s} ({d}x{d})", .{
        dev_idx, dev_name, exen_w, exen_h,
    });

    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer(
        title.ptr,
        exen_w,
        exen_h,
        c.SDL_WINDOW_RESIZABLE,
        &window,
        &renderer,
    )) {
        std.debug.print("CreateWindowAndRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    }
    defer c.SDL_DestroyRenderer(renderer);
    defer c.SDL_DestroyWindow(window);

    const tray = c.SDL_CreateTray(null, "ExEn Simulator");
    if (tray) |t| {
        buildTrayMenu(t);
    } else {
        std.debug.print("SDL_CreateTray failed: {s}\n", .{c.SDL_GetError()});
    }
    defer if (tray) |t| c.SDL_DestroyTray(t);

    // Wrap the simulated-LCD framebuffer in a streaming SDL texture.
    // We re-upload its pixels every frame (the VM-equivalent of
    // `exen.Gamelet.screenUpdate`). Nearest-neighbor keeps the pixels
    // crisp when the user resizes the window.
    var fb = exen.framebuffer() orelse {
        std.debug.print("[sdl] framebuffer missing — boot() failed?\n", .{});
        return error.NoFramebuffer;
    };
    var lcd_texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(fb.width),
        @intCast(fb.height),
    ) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlTexture;
    };
    defer c.SDL_DestroyTexture(lcd_texture);
    _ = c.SDL_SetTextureScaleMode(lcd_texture, c.SDL_SCALEMODE_NEAREST);
    std.debug.print("[sdl] LCD texture: {d}x{d} streaming ABGR8888\n", .{ fb.width, fb.height });

    // Snapshot the boot screen for debugging — the gamelet's splash
    // and menu transitions play inside the SDL main loop below so
    // the user sees them animate in real-time.
    writeBmp("boot_screenshot.bmp", fb.pixels, fb.width, fb.height) catch |err| {
        std.debug.print("[sdl] writeBmp failed: {s}\n", .{@errorName(err)});
    };
    std.debug.print("[sdl] wrote boot_screenshot.bmp ({d}x{d})\n", .{ fb.width, fb.height });

    g_boot_ms = c.SDL_GetTicks();

    while (!g_state.quit) {
        // Synthetic key injection (--auto-key=…). Each entry fires
        // once with a 200ms release window so the gamelet sees a
        // real down/up cycle rather than a held key.
        {
            const now = c.SDL_GetTicks();
            const elapsed = now - g_boot_ms;
            var i: u32 = 0;
            while (i < g_auto_keys_count) : (i += 1) {
                const ak = &g_auto_keys[i];
                if (ak.code != 0 and !ak.fired and elapsed >= ak.fire_at) {
                    std.debug.print("[auto-key] fire[{d}] code={d} at +{d}ms\n", .{ i, ak.code, elapsed });
                    exen.signalKeypress(ak.code);
                    ak.fired = true;
                    ak.release_at = now + 200;
                }
                if (ak.fired and ak.release_at != 0 and now >= ak.release_at) {
                    std.debug.print("[auto-key] release[{d}] code={d}\n", .{ i, ak.code });
                    exen.signalKeyrelease(ak.code);
                    ak.release_at = 0;
                }
            }
            // Scheduled screenshot captures (--screenshot-at=…).
            var j: u32 = 0;
            while (j < g_captures_count) : (j += 1) {
                const cap = &g_captures[j];
                if (!cap.fired and elapsed >= cap.fire_at) {
                    var path_buf: [64]u8 = undefined;
                    const path = std.fmt.bufPrintZ(&path_buf, "{s}.bmp", .{cap.name[0..cap.name_len]}) catch {
                        cap.fired = true;
                        continue;
                    };
                    writeBmp(path, fb.pixels, fb.width, fb.height) catch |err| {
                        std.debug.print("[screenshot] {s} failed: {s}\n", .{ path, @errorName(err) });
                    };
                    std.debug.print("[screenshot] wrote {s} at +{d}ms\n", .{ path, elapsed });
                    cap.fired = true;
                }
            }
            // One-shot save→load round-trip (--savestate-at=…). Checks the framebuffer
            // is bit-identical after reload — acceptance test for the save-state rewrite.
            if (g_savestate_at_ms != 0 and !g_savestate_done and elapsed >= g_savestate_at_ms) {
                g_savestate_done = true;
                var crc_before: u32 = 0;
                for (fb.pixels) |px| crc_before = crc_before *% 31 +% px;
                const sz = exen.stateSize();
                if (allocator.alloc(u8, sz)) |buf| {
                    defer allocator.free(buf);
                    if (exen.saveState(buf)) |n| {
                        if (exen.loadState(buf[0..n])) |_| {
                            var crc_after: u32 = 0;
                            for (fb.pixels) |px| crc_after = crc_after *% 31 +% px;
                            std.debug.print("[savestate] round-trip OK: {d} bytes, fb crc {s} (0x{x} -> 0x{x})\n", .{ n, if (crc_before == crc_after) "MATCH" else "MISMATCH", crc_before, crc_after });
                        } else |err| std.debug.print("[savestate] loadState FAILED: {s}\n", .{@errorName(err)});
                    } else |err| std.debug.print("[savestate] saveState FAILED: {s}\n", .{@errorName(err)});
                } else |err| std.debug.print("[savestate] alloc FAILED: {s}\n", .{@errorName(err)});
            }
            // Scheduled clean quit (--quit-at=…) — exercises shutdown + leak report.
            if (g_quit_at_ms != 0 and elapsed >= g_quit_at_ms) {
                std.debug.print("[quit-at] elapsed +{d}ms — quitting cleanly\n", .{elapsed});
                g_state.quit = true;
            }
        }

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => g_state.quit = true,
                c.SDL_EVENT_TEXT_INPUT => {
                    // Catalog edit box collecting characters.
                    if (g_editbox_active) {
                        const txt = std.mem.span(event.text.text);
                        for (txt) |ch| {
                            if (g_editbox_len < g_editbox_max) {
                                g_editbox_buf[g_editbox_len] = ch;
                                g_editbox_len += 1;
                            }
                        }
                    }
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (g_editbox_active) {
                        // Edit box swallows keys: Return commits, Backspace
                        // deletes, Escape cancels (empty result).
                        switch (event.key.key) {
                            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                                exen.catalogEditBoxResult(g_editbox_buf[0..g_editbox_len]);
                                g_editbox_active = false;
                                _ = c.SDL_StopTextInput(window);
                            },
                            c.SDLK_BACKSPACE => {
                                if (g_editbox_len > 0) g_editbox_len -= 1;
                            },
                            c.SDLK_ESCAPE => {
                                exen.catalogEditBoxResult(&.{});
                                g_editbox_active = false;
                                _ = c.SDL_StopTextInput(window);
                            },
                            else => {},
                        }
                    } else if (event.key.key == c.SDLK_ESCAPE) {
                        g_state.quit = true;
                    } else if (!event.key.repeat) {
                        // Drop SDL's host-OS key-repeat events (which fire at
                        // ~30 Hz while a key is held). Real ExEn devices send
                        // exactly one keypress per physical press, with the
                        // gamelet driving any auto-repeat via its own tick
                        // counter (e.g. Pikubi's menu cursor re-checks the
                        // keystate field per frame). Forwarding host-repeats
                        // makes menus blast through 10+ items on a single
                        // press and scenes advance through their bytecode
                        // state machine faster than they can render.
                        exen.signalKeypress(mapSdlKey(event.key.key));
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    if (event.key.key != c.SDLK_ESCAPE) {
                        exen.signalKeyrelease(mapSdlKey(event.key.key));
                    }
                },
                else => {},
            }
        }

        // Catalog edit box opened by the native this tick — begin SDL
        // text input (must happen on the loop side, not in the callback).
        if (g_editbox_active and !g_editbox_started) {
            _ = c.SDL_StartTextInput(window);
            g_editbox_started = true;
        } else if (!g_editbox_active) {
            g_editbox_started = false;
        }

        // Service a pending catalog game launch (set by launchGameIfPresent
        // — applied here so the swap happens at a tick boundary, mirroring
        // canonical's pump-consumes-state-5 model).
        if (g_launch_pending) |path| {
            g_launch_pending = null;
            std.debug.print("[catalog] loading {s}\n", .{path});
            exen.loadExn(path) catch |err| {
                std.debug.print("[catalog] loadExn({s}) failed: {s}\n", .{ path, @errorName(err) });
            };
            g_exn_path = path; // static buffer — stays valid for tray reloads
        }

        // Service a pending device switch (set by the Device tray
        // callback). This is a full warm-reboot of the VM with a new
        // [Manuf.NNN] profile, plus an SDL texture/window rebuild.
        if (g_state.device_pending) |new_idx| {
            g_state.device_pending = null;
            std.debug.print("[device] switching to Manuf.{d:0>3}\n", .{new_idx});
            exen.shutdown();
            exen.manuf_override = new_idx;
            exen.boot(allocator, g_ini_path) catch |err| {
                std.debug.print("[device] boot failed: {s}\n", .{@errorName(err)});
                continue;
            };
            exen.loadExn(g_exn_path) catch |err| {
                std.debug.print("[device] reload {s} failed: {s}\n", .{ g_exn_path, @errorName(err) });
            };
            exen_w = @intCast(exen.screenWidth());
            exen_h = @intCast(exen.screenHeight());
            fb = exen.framebuffer() orelse {
                std.debug.print("[device] framebuffer missing after switch\n", .{});
                g_state.quit = true;
                continue;
            };
            c.SDL_DestroyTexture(lcd_texture);
            lcd_texture = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_ABGR8888,
                c.SDL_TEXTUREACCESS_STREAMING,
                @intCast(fb.width),
                @intCast(fb.height),
            ) orelse {
                std.debug.print("[device] SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
                g_state.quit = true;
                continue;
            };
            _ = c.SDL_SetTextureScaleMode(lcd_texture, c.SDL_SCALEMODE_NEAREST);
            _ = c.SDL_SetWindowSize(window, exen_w, exen_h);
            var new_title_buf: [80]u8 = undefined;
            const name = exen.deviceName(new_idx) orelse "?";
            const new_title = std.fmt.bufPrintZ(&new_title_buf, "ExEn {d}-{s} ({d}x{d})", .{
                new_idx, name, exen_w, exen_h,
            }) catch null;
            if (new_title) |t| _ = c.SDL_SetWindowTitle(window, t.ptr);
            refreshDeviceChecks(new_idx);
        }

        // Drive the host's stand-in for the gamelet's draw loop. One
        // invocation of Bootstrap.tick per host frame — matches the
        // real simulator's WM_TIMER path (sub_4393A3 schedules tick
        // every ~16ms via SetTimer + WM_TIMER → sub_438840). Cap
        // the gamelet's requested tick period to `TICK_PERIOD_CEIL_MS`
        // so gameplay runs faster than original phone speed (canonical
        // ~7 Hz feels sluggish on modern displays). Faster gamelets
        // are honoured as-is. The audio backend reads the same
        // constant so tempo scales with the visual speedup.
        const now_ms: u64 = c.SDL_GetTicks();
        const requested: u64 = if (exen.g_timer_period_ms > 0) exen.g_timer_period_ms else 16;
        const period: u64 = @min(requested, @as(u64, exen.TICK_PERIOD_CEIL_MS));
        if (now_ms >= g_state.last_tick_ms + period) {
            g_state.last_tick_ms = now_ms;
            exen.tick(@intCast(period));
            // Honour the gamelet's exit-request flag (set by
            // `Gamelet.exitVm()` idx 73, mirrors canonical
            // `*(dword_45FF3C+36) = 1`). Quitting at tick boundary
            // matches canonical's poll-between-ticks behaviour.
            if (exen.vmExitRequested()) {
                std.debug.print("[sdl] gamelet requested exit via Gamelet.exitVm() — quitting\n", .{});
                g_state.quit = true;
            }
            // Persist the most recent framebuffer state so headless runs
            // (e.g. `gtimeout 10 ./exen-player ...`) leave a viewable
            // image of the last frame rendered before the process is
            // SIGTERMed. Cheap — one BMP write per tick (~15ms cadence).
            writeBmp("last_frame.bmp", fb.pixels, fb.width, fb.height) catch {};
        }

        // Upload the simulated LCD framebuffer to the streaming texture.
        // Host side of `exen.Gamelet.screenUpdate()`.
        const stride: c_int = @as(c_int, @intCast(fb.width)) * 4;
        if (!c.SDL_UpdateTexture(lcd_texture, null, fb.pixels.ptr, stride)) {
            std.debug.print("SDL_UpdateTexture failed: {s}\n", .{c.SDL_GetError()});
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 0x00, 0x00, 0x00, 0xFF);
        _ = c.SDL_RenderClear(renderer);

        // LCD texture covers the current window 1:1 with the pixel
        // grid (user can resize; the texture stretches to fill).
        var cur_w: c_int = 0;
        var cur_h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &cur_w, &cur_h);
        const dst: c.SDL_FRect = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(cur_w),
            .h = @floatFromInt(cur_h),
        };
        _ = c.SDL_RenderTexture(renderer, lcd_texture, null, &dst);

        if (g_state.grid) {
            _ = c.SDL_SetRenderDrawColor(renderer, 0x30, 0x30, 0x40, 0xFF);
            const sx: f32 = @as(f32, @floatFromInt(cur_w)) / @as(f32, @floatFromInt(exen_w));
            const sy: f32 = @as(f32, @floatFromInt(cur_h)) / @as(f32, @floatFromInt(exen_h));
            var gx: c_int = 0;
            while (gx <= exen_w) : (gx += 8) {
                const x: f32 = @as(f32, @floatFromInt(gx)) * sx;
                _ = c.SDL_RenderLine(renderer, x, 0, x, @floatFromInt(cur_h));
            }
            var gy: c_int = 0;
            while (gy <= exen_h) : (gy += 8) {
                const y: f32 = @as(f32, @floatFromInt(gy)) * sy;
                _ = c.SDL_RenderLine(renderer, 0, y, @floatFromInt(cur_w), y);
            }
        }

        _ = c.SDL_RenderPresent(renderer);

        g_state.frame_count += 1;

        c.SDL_Delay(16);
    }
}

/// Minimal 32-bit BGRA BMP writer (top-down via negative height).
/// Map SDL key codes to ExEn key codes. Phone-style keypad:
///   Arrows  → UP/DOWN/LEFT/RIGHT
///   Enter/Space → FIRE/SELECT (center button)
///   Q       → SOFT1 (left soft key, "OK"/"YES" in most games)
///   W       → SOFT2 (right soft key, "BACK"/"CANCEL")
///   0..9, *, # → numeric keypad
fn mapSdlKey(sdl_key: u32) i32 {
    return switch (sdl_key) {
        c.SDLK_UP => exen.KEY_UP,
        c.SDLK_DOWN => exen.KEY_DOWN,
        c.SDLK_LEFT => exen.KEY_LEFT,
        c.SDLK_RIGHT => exen.KEY_RIGHT,
        c.SDLK_RETURN, c.SDLK_SPACE => exen.KEY_FIRE,
        c.SDLK_Q => exen.KEY_SOFT1,
        c.SDLK_W => exen.KEY_SOFT2,
        c.SDLK_0...c.SDLK_9 => @intCast(sdl_key), // '0'..'9' → ASCII codes 48..57 = J2ME KEY_NUM0..9
        c.SDLK_ASTERISK => '*',
        c.SDLK_HASH => '#',
        else => @intCast(sdl_key & 0xFF), // fallback: pass low byte
    };
}

fn writeBmp(path: []const u8, rgba: []const u32, w: u32, h: u32) !void {
    const pixel_bytes: u32 = w * h * 4;
    const pix_off: u32 = 14 + 40;
    const file_size: u32 = pix_off + pixel_bytes;

    var f = try std.fs.cwd().createFile(path, .{});
    defer f.close();

    var header: [54]u8 = undefined;
    header[0] = 'B'; header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], file_size, .little);
    std.mem.writeInt(u32, header[6..10], 0, .little);
    std.mem.writeInt(u32, header[10..14], pix_off, .little);
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], @intCast(w), .little);
    std.mem.writeInt(i32, header[22..26], -@as(i32, @intCast(h)), .little);
    std.mem.writeInt(u16, header[26..28], 1, .little);
    std.mem.writeInt(u16, header[28..30], 32, .little);
    std.mem.writeInt(u32, header[30..34], 0, .little);
    std.mem.writeInt(u32, header[34..38], pixel_bytes, .little);
    std.mem.writeInt(u32, header[38..42], 2835, .little);
    std.mem.writeInt(u32, header[42..46], 2835, .little);
    std.mem.writeInt(u32, header[46..50], 0, .little);
    std.mem.writeInt(u32, header[50..54], 0, .little);
    try f.writeAll(&header);

    var row_buf: [4096]u8 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = rgba[y * w ..][0..w];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const p = row[x];
            row_buf[x * 4 + 0] = @truncate((p >> 16) & 0xFF); // B
            row_buf[x * 4 + 1] = @truncate((p >> 8) & 0xFF);  // G
            row_buf[x * 4 + 2] = @truncate(p & 0xFF);         // R
            row_buf[x * 4 + 3] = @truncate((p >> 24) & 0xFF); // A
        }
        try f.writeAll(row_buf[0 .. @as(usize, w) * 4]);
    }
}
