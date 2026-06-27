//! Minimal libretro host: dlopen the core, drive the lifecycle, and verify
//! retro_run renders + retro_serialize/unserialize roundtrips — without RetroArch.
//! Usage: test_host <core.dylib> <game.vxp>
const std = @import("std");

const W = 240;
const H = 320;
var fb: [W * H]u16 = undefined;
var fb_w: c_uint = 0;
var fb_h: c_uint = 0;

fn envCb(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    if (cmd == 10) { // SET_PIXEL_FORMAT
        const fmt: *c_uint = @ptrCast(@alignCast(data.?));
        return fmt.* == 2; // RGB565
    }
    return false;
}
fn videoCb(data: ?*const anyopaque, w: c_uint, h: c_uint, pitch: usize) callconv(.c) void {
    fb_w = w;
    fb_h = h;
    if (data) |d| {
        const src: [*]const u8 = @ptrCast(d);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const row = src[y * pitch ..][0 .. w * 2];
            @memcpy(std.mem.sliceAsBytes(fb[y * w ..][0..w]), row);
        }
    }
}
fn inputPoll() callconv(.c) void {}
fn inputState(_: c_uint, _: c_uint, _: c_uint, _: c_uint) callconv(.c) i16 {
    return 0;
}

const GameInfo = extern struct { path: ?[*:0]const u8, data: ?*const anyopaque, size: usize, meta: ?[*:0]const u8 };

pub fn main() !void {
    var gpa_s: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_s.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 3) return error.Usage;

    var lib = try std.DynLib.open(args[1]);
    defer lib.close();

    const set_env = lib.lookup(*const fn (?*const fn (c_uint, ?*anyopaque) callconv(.c) bool) callconv(.c) void, "retro_set_environment").?;
    const set_video = lib.lookup(*const fn (?*const fn (?*const anyopaque, c_uint, c_uint, usize) callconv(.c) void) callconv(.c) void, "retro_set_video_refresh").?;
    const set_poll = lib.lookup(*const fn (?*const fn () callconv(.c) void) callconv(.c) void, "retro_set_input_poll").?;
    const set_input = lib.lookup(*const fn (?*const fn (c_uint, c_uint, c_uint, c_uint) callconv(.c) i16) callconv(.c) void, "retro_set_input_state").?;
    const init = lib.lookup(*const fn () callconv(.c) void, "retro_init").?;
    const load = lib.lookup(*const fn (?*const GameInfo) callconv(.c) bool, "retro_load_game").?;
    const run = lib.lookup(*const fn () callconv(.c) void, "retro_run").?;
    const ser_size = lib.lookup(*const fn () callconv(.c) usize, "retro_serialize_size").?;
    const ser = lib.lookup(*const fn (?*anyopaque, usize) callconv(.c) bool, "retro_serialize").?;
    const unser = lib.lookup(*const fn (?*const anyopaque, usize) callconv(.c) bool, "retro_unserialize").?;

    set_env(envCb);
    set_video(videoCb);
    set_poll(inputPoll);
    set_input(inputState);
    init();

    const rom = try std.fs.cwd().readFileAlloc(gpa, args[2], 64 << 20);
    defer gpa.free(rom);
    const gi = GameInfo{ .path = null, .data = rom.ptr, .size = rom.len, .meta = null };
    if (!load(&gi)) return error.LoadFailed;
    std.debug.print("[host] loaded {s} ({d} bytes)\n", .{ args[2], rom.len });

    var i: u32 = 0;
    while (i < 60) : (i += 1) run();

    const sz = ser_size();
    const state = try gpa.alloc(u8, sz);
    defer gpa.free(state);
    if (!ser(state.ptr, sz)) return error.SerFailed;
    std.debug.print("[host] serialized: {d} bytes\n", .{sz});

    i = 0;
    while (i < 60) : (i += 1) run();
    var fb1: [W * H]u16 = fb;
    const evolved = !std.mem.eql(u16, &fb1, blk: {
        // compare against the post-restore-frame later; here just note non-black
        break :blk &fb1;
    });
    _ = evolved;
    var nz1: usize = 0;
    for (fb1) |p| {
        if (p != 0) nz1 += 1;
    }

    if (!unser(state.ptr, sz)) return error.UnserFailed;
    i = 0;
    while (i < 60) : (i += 1) run();
    const fb2: [W * H]u16 = fb;

    const match = std.mem.eql(u16, &fb1, &fb2);
    std.debug.print("[host] fb {d}x{d}, non-black={d}\n", .{ fb_w, fb_h, nz1 });
    std.debug.print("[host] ROUNDTRIP fb1==fb2 (after serialize/run/unserialize/run): {}\n", .{match});
    if (!match) return error.RoundtripMismatch;
    std.debug.print("[host] OK\n", .{});
}
