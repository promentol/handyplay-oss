//! Phase 3 validation: load a .vxp, start the VM, and let the ARM code run. The
//! bridge logs vm_get_sym_entry resolutions and stub calls, revealing the real
//! native-call sequence. (Reaching a rendered frame is a later phase.)
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        std.debug.print("usage: run <file.vxp>\n", .{});
        return error.BadArgs;
    }

    const file = try std.fs.cwd().readFileAlloc(gpa, args[1], 64 * 1024 * 1024);
    defer gpa.free(file);

    // Mirror the .vxp into the emulated filesystem so the game can re-open itself
    // for resources (vm_get_exec_filename -> "C:\app.vxp" -> ./fs/c/app.vxp).
    std.fs.cwd().makePath("fs/c") catch {};
    std.fs.cwd().makePath("fs/d") catch {};
    std.fs.cwd().makePath("fs/e") catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = "fs/c/app.vxp", .data = file });

    var mem = try core.Memory.init(gpa, 32 * 1024 * 1024);
    defer mem.deinit();

    const vm = try core.Vm.create(gpa, &mem);
    defer vm.destroy();

    std.debug.print("[run] starting {s}\n", .{args[1]});
    try vm.loadAndStart(file);
    std.debug.print("[run] start returned (idle); used_screen_buffer={}\n", .{vm.used_screen_buffer});

    if (std.posix.getenv("DUMP_CODE") != null) {
        if (vm.app) |app| {
            const region = mem.slice(app.offset_mem, app.segments_size);
            try std.fs.cwd().writeFile(.{ .sub_path = "loaded.bin", .data = region });
            std.debug.print("[run] dumped loaded.bin ({d} bytes @ base 0x{x})\n", .{ region.len, app.offset_mem });
        }
    }

    // Drive the game's main loop via timer ticks. The game redraws itself from its
    // timer callback (the reference delivers PAINT once at launch, not per frame).
    const paint_each = std.posix.getenv("PAINT_EACH") != null;
    const tick_ms: u32 = if (std.posix.getenv("TICKMS")) |t| (std.fmt.parseInt(u32, t, 10) catch 33) else 33;
    const ticks: u32 = if (std.posix.getenv("TICKS")) |t| (std.fmt.parseInt(u32, t, 10) catch 30) else 30;
    var i: u32 = 0;
    while (i < ticks) : (i += 1) {
        vm.tick(tick_ms);
        if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
    }

    // Optional synthetic input: KEYS="down,down,ok" presses keys with a tick+paint
    // between each, to verify input drives the game (e.g. menu navigation).
    if (std.posix.getenv("KEYS")) |keys| {
        var it = std.mem.splitScalar(u8, keys, ',');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "w")) { // "w" = wait ~1s between presses
                var k: u32 = 0;
                while (k < 30) : (k += 1) {
                    vm.tick(tick_ms);
                    if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
                }
                continue;
            }
            const key = parseKey(tok) orelse continue;
            std.debug.print("[keys] press {s}\n", .{tok});
            // Hold the key down across several timer ticks (the game's main loop
            // polls key state at ~75ms), then release.
            vm.deliverKey(core.vm.VM_KEY_EVENT_DOWN, @intFromEnum(key));
            const hold: u32 = if (std.posix.getenv("HOLD")) |h| (std.fmt.parseInt(u32, h, 10) catch 6) else 6;
            var k: u32 = 0;
            while (k < hold) : (k += 1) {
                vm.tick(tick_ms);
                if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
            }
            vm.deliverKey(core.vm.VM_KEY_EVENT_UP, @intFromEnum(key));
            k = 0;
            while (k < 6) : (k += 1) {
                vm.tick(tick_ms);
                if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
            }
        }
    }

    // Optional synthetic tap: TAP="x,y" delivers a pen TAP at (x,y), holds, releases.
    if (std.posix.getenv("TAP")) |tap| {
        var it = std.mem.splitScalar(u8, tap, ',');
        const x = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
        std.debug.print("[tap] at {d},{d}\n", .{ x, y });
        vm.deliverPen(core.vm.VM_PEN_EVENT_TAP, x, y);
        var k: u32 = 0;
        while (k < 6) : (k += 1) vm.tick(tick_ms);
        vm.deliverPen(core.vm.VM_PEN_EVENT_RELEASE, x, y);
        k = 0;
        while (k < 6) : (k += 1) vm.tick(tick_ms);
    }

    // Optional second tap: TAP2="x,y" fires after TAP (e.g. tap a menu item once a
    // prior tap opened the menu). If TAP2_HELD is set, frame.ppm is dumped WHILE the
    // pen is still held — capturing transient press-down highlight that a
    // post-release dump would miss.
    if (std.posix.getenv("TAP2")) |tap| {
        var it = std.mem.splitScalar(u8, tap, ',');
        const x = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
        // Let the prior screen transition settle before tapping (TAP2_DELAY ticks).
        var d: u32 = if (std.posix.getenv("TAP2_DELAY")) |t| (std.fmt.parseInt(u32, t, 10) catch 40) else 40;
        while (d > 0) : (d -= 1) {
            vm.tick(tick_ms);
            if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
        }
        std.debug.print("[tap2] at {d},{d}\n", .{ x, y });
        vm.deliverPen(core.vm.VM_PEN_EVENT_TAP, x, y);
        var k: u32 = 0;
        while (k < 3) : (k += 1) {
            vm.tick(tick_ms);
            if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
        }
        // Emulate a finger settling on the item (drag/hover) — some touch menus
        // highlight the item under a MOVE, not a bare down.
        if (std.posix.getenv("TAP2_MOVE") != null) vm.deliverPen(core.vm.VM_PEN_EVENT_MOVE, x, y);
        k = 0;
        while (k < 3) : (k += 1) {
            vm.tick(tick_ms);
            if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
        }
        if (std.posix.getenv("TAP2_HELD") != null) {
            if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();
            try dumpPpm(vm, "frame_held.ppm");
            std.debug.print("[tap2] dumped frame_held.ppm (pen still down)\n", .{});
        }
        vm.deliverPen(core.vm.VM_PEN_EVENT_RELEASE, x, y);
        k = 0;
        while (k < 6) : (k += 1) vm.tick(tick_ms);
    }

    // Optional post-tap key sequence: KEYS2="down,down" presses keys AFTER the taps
    // (e.g. D-pad navigation once a tap opened the menu). If KEYS2_HELD is set, a frame
    // is dumped to frame_held.ppm while the last key is still down.
    if (std.posix.getenv("KEYS2")) |keys| {
        const held_dump = std.posix.getenv("KEYS2_HELD") != null;
        var sd: u32 = if (std.posix.getenv("KEYS2_DELAY")) |t| (std.fmt.parseInt(u32, t, 10) catch 60) else 60;
        while (sd > 0) : (sd -= 1) {
            vm.tick(tick_ms);
            if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
        }
        var it = std.mem.splitScalar(u8, keys, ',');
        while (it.next()) |tok| {
            const key = parseKey(tok) orelse continue;
            std.debug.print("[keys2] press {s}\n", .{tok});
            vm.deliverKey(core.vm.VM_KEY_EVENT_DOWN, @intFromEnum(key));
            var k: u32 = 0;
            while (k < 8) : (k += 1) {
                vm.tick(tick_ms);
                if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
            }
            if (held_dump) {
                if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();
                try dumpPpm(vm, "frame_held.ppm");
                std.debug.print("[keys2] dumped frame_held.ppm (key still down)\n", .{});
            }
            vm.deliverKey(core.vm.VM_KEY_EVENT_UP, @intFromEnum(key));
            k = 0;
            while (k < 6) : (k += 1) {
                vm.tick(tick_ms);
                if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
            }
        }
    }

    // Optional extra run time after input (POSTTICKS=n), e.g. to let a level load.
    if (std.posix.getenv("POSTTICKS")) |t| {
        var extra = std.fmt.parseInt(u32, t, 10) catch 0;
        while (extra > 0) : (extra -= 1) {
            vm.tick(tick_ms);
            if (paint_each) vm.deliverSysEvent(core.vm.VM_MSG_PAINT, 0);
        }
    }

    // Diagnostics: where did content land? (gated)
    if (std.posix.getenv("DIAG") != null) {
        const g = &vm.gfx;
        var scr: usize = 0;
        for (g.screen) |p| {
            if (p != 0) scr += 1;
        }
        std.debug.print("[diag] screen[]={d} base1={d} base2={d} layers={d}\n", .{
            scr, countBuf(vm, g.base_buf1), countBuf(vm, g.base_buf2), g.layer_count,
        });
        var li: usize = 0;
        while (li < g.layer_count) : (li += 1)
            std.debug.print("[diag]  layer {d}: buf=0x{x} {d}x{d} nonzero={d}\n", .{ li, g.layers[li].buf, g.layers[li].w, g.layers[li].h, countBuf(vm, g.layers[li].buf) });
    }

    // DUMP_LAYERS: write each layer's raw buffer to layerN.ppm to inspect what
    // content lives on each layer (independent of compositing).
    if (std.posix.getenv("DUMP_LAYERS") != null) {
        var li: usize = 0;
        while (li < vm.gfx.layer_count) : (li += 1) {
            var nb: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&nb, "layer{d}.ppm", .{li});
            dumpBufPpm(vm, vm.gfx.layers[li].buf, @intCast(vm.gfx.layers[li].w), @intCast(vm.gfx.layers[li].h), path) catch {};
            std.debug.print("[run] dumped {s}\n", .{path});
        }
    }

    // DUMP_CANVAS="addr,w,h" (addr hex/dec): dump an arbitrary canvas pixel buffer.
    if (std.posix.getenv("DUMP_CANVAS")) |spec| {
        var it = std.mem.splitScalar(u8, spec, ',');
        const addr = std.fmt.parseInt(u32, it.next() orelse "0", 0) catch 0;
        const w = std.fmt.parseInt(u32, it.next() orelse "0", 0) catch 0;
        const h = std.fmt.parseInt(u32, it.next() orelse "0", 0) catch 0;
        if (addr != 0 and w != 0 and h != 0) {
            dumpBufPpm(vm, addr, w, h, "canvas.ppm") catch {};
            std.debug.print("[run] dumped canvas.ppm ({d}x{d} @ 0x{x})\n", .{ w, h, addr });
        }
    }

    // Present the direct back-buffer only for games that don't use layers; layer
    // games composite into screen[] via flush_layer and present() would clobber it.
    if (vm.used_screen_buffer and vm.gfx.layer_count == 0) vm.gfx.present();
    try dumpPpm(vm, "frame.ppm");
    const nonzero = countNonzero(vm);
    std.debug.print("[run] wrote frame.ppm ({d}/{d} non-black pixels)\n", .{ nonzero, vm.gfx.screen.len });

    // Report which called natives are stubbed/unimplemented.
    vm.bridge.report();
}

fn dumpBufPpm(vm: *core.Vm, px: u32, w: u32, h: u32, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var hb: [32]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&hb, "P6\n{d} {d}\n255\n", .{ w, h }));
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const c = vm.mem.readU16(px + (y * w + x) * 2);
            const row = [3]u8{ core.gfx.getRed(c), core.gfx.getGreen(c), core.gfx.getBlue(c) };
            try file.writeAll(&row);
        }
    }
}

fn parseKey(name: []const u8) ?core.vm.Key {
    const map = .{
        .{ "up", core.vm.Key.up },        .{ "down", core.vm.Key.down },
        .{ "left", core.vm.Key.left },    .{ "right", core.vm.Key.right },
        .{ "ok", core.vm.Key.ok },        .{ "lsk", core.vm.Key.left_softkey },
        .{ "rsk", core.vm.Key.right_softkey }, .{ "clear", core.vm.Key.clear },
        .{ "0", core.vm.Key.num0 },       .{ "1", core.vm.Key.num1 },
        .{ "2", core.vm.Key.num2 },       .{ "3", core.vm.Key.num3 },
        .{ "5", core.vm.Key.num5 },       .{ "star", core.vm.Key.star },
        .{ "pound", core.vm.Key.pound },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

fn countBuf(vm: *core.Vm, px: u32) usize {
    if (px == 0) return 0;
    var n: usize = 0;
    var i: u32 = 0;
    const total = core.gfx.screen_w * core.gfx.screen_h;
    while (i < total) : (i += 1) {
        if (vm.mem.readU16(px + i * 2) != 0) n += 1;
    }
    return n;
}

fn countNonzero(vm: *core.Vm) usize {
    var n: usize = 0;
    for (vm.gfx.screen) |p| {
        if (p != 0) n += 1;
    }
    return n;
}

fn dumpPpm(vm: *core.Vm, path: []const u8) !void {
    const g = &vm.gfx;
    const w = core.gfx.screen_w;
    const h = core.gfx.screen_h;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ w, h });
    try file.writeAll(header);
    var row: [core.gfx.screen_w * 3]u8 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const c = g.screen[y * w + x];
            row[x * 3 + 0] = core.gfx.getRed(c);
            row[x * 3 + 1] = core.gfx.getGreen(c);
            row[x * 3 + 2] = core.gfx.getBlue(c);
        }
        try file.writeAll(&row);
    }
}
