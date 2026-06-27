//! Headless runner: chdir into the asset root, boot the dsm engine + a dsm
//! package, pump a few timer ticks, then print the native-coverage report.
//!
//!   zig build run -- [assets_dir] [package.mrp] [ext_name]
//!
//! Defaults: assets/, mythroad/dsm_gm.mrp, start.mr.
const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const assets = if (args.len > 1) args[1] else "assets";
    const pkg = if (args.len > 2) args[2] else "dsm_gm.mrp";
    const ext_name = if (args.len > 3) args[3] else "start.mr";

    try std.posix.chdir(assets);
    std.debug.print("[run] cwd={s} pkg={s} ext={s}\n", .{ assets, pkg, ext_name });

    const vm = try core.Vm.create(gpa);
    defer vm.destroy();

    vm.start("cfunction.ext", pkg, ext_name) catch |e| {
        std.debug.print("[run] start error: {s}\n", .{@errorName(e)});
        vm.report();
        return e;
    };

    // Pump a handful of timer ticks so the launcher advances past its first frame.
    var i: u32 = 0;
    while (i < 30 and !vm.quit_requested and !vm.halted) : (i += 1) {
        _ = vm.timer();
    }

    std.debug.print("[run] gfx dirty={}, ticks={d}\n", .{ vm.gfx.dirty, i });
    vm.report();
}
