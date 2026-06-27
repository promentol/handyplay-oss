//! Phase 2 validation: load a .vxp and report format / entry / segment sizes.
const std = @import("std");
const core = @import("core");
const Memory = core.Memory;
const armapp = core.loader.armapp;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        std.debug.print("usage: loadtest <file.vxp>\n", .{});
        return error.BadArgs;
    }

    const file = try std.fs.cwd().readFileAlloc(gpa, args[1], 64 * 1024 * 1024);
    defer gpa.free(file);

    std.debug.print("file: {s} ({d} bytes)\n", .{ args[1], file.len });
    std.debug.print("format sniff: {s}\n", .{@tagName(armapp.sniff(file))});

    var mem = try Memory.init(gpa, 32 * 1024 * 1024);
    defer mem.deinit();

    var app = try armapp.load(gpa, &mem, file);
    defer app.app_memory.deinit();

    std.debug.print(
        \\loaded:
        \\  is_ads        = {}
        \\  offset_mem    = 0x{x:0>8}
        \\  mem_size      = {d} ({d} KB)
        \\  segments_size = {d}
        \\  entry_point   = 0x{x:0>8}
        \\  resources     = off=0x{x} size={d}
        \\
    , .{
        app.is_ads,        app.offset_mem, app.mem_size, app.mem_size / 1024,
        app.segments_size, app.entry_point, app.res_offset, app.res_size,
    });

    // Show the first 16 bytes of loaded code (entry).
    const code = mem.slice(app.entry_point, 16);
    std.debug.print("  entry bytes   =", .{});
    for (code) |b| std.debug.print(" {x:0>2}", .{b});
    std.debug.print("\n", .{});
}
