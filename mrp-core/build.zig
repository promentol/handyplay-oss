const std = @import("std");

// Vendored Unicorn (CPU emulator), shared by the mre/mrp cores in ../vendor/unicorn.
// The static archive (../vendor/unicorn/build/libunicorn.a) was produced out-of-band
// via CMake; here we only link it and expose its C header. We bind the C API directly
// with @cImport rather than via the bundled Zig bindings (which use `usingnamespace`,
// removed in Zig 0.15).
const unicorn_root = "../vendor/unicorn";

/// Attach Unicorn include/lib/link to a module so every consumer inherits it.
fn addUnicorn(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = unicorn_root ++ "/include" });
    mod.addLibraryPath(.{ .cwd_relative = unicorn_root ++ "/build" });
    mod.linkSystemLibrary("unicorn", .{});
}

fn addSdl(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("SDL3", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- core module (frontend-agnostic VM + loader + memory + bridge) --------
    // The core embeds the Unicorn-backed CPU, so it carries Unicorn linkage.
    const core = b.addModule("core", .{
        .root_source_file = b.path("core/mrp.zig"),
        .target = target,
        .optimize = optimize,
    });
    addUnicorn(core);

    // helper to make a tool exe that imports core
    const Tool = struct {
        fn add(bb: *std.Build, cmod: *std.Build.Module, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, name: []const u8, src: []const u8, step_name: []const u8, desc: []const u8) void {
            const mod = bb.createModule(.{ .root_source_file = bb.path(src), .target = t, .optimize = o });
            mod.addImport("core", cmod);
            const exe = bb.addExecutable(.{ .name = name, .root_module = mod });
            bb.installArtifact(exe);
            const run = bb.addRunArtifact(exe);
            if (bb.args) |args| run.addArgs(args);
            bb.step(step_name, desc).dependOn(&run.step);
        }
    };

    // --- headless runner ------------------------------------------------------
    Tool.add(b, core, target, optimize, "run", "tools/run.zig", "run", "Boot the dsm engine + a package, headless");

    // --- SDL3 live window -----------------------------------------------------
    const sdl_mod = b.createModule(.{ .root_source_file = b.path("frontends/sdl/main.zig"), .target = target, .optimize = optimize });
    sdl_mod.addImport("core", core);
    addSdl(sdl_mod);
    const sdl_exe = b.addExecutable(.{ .name = "mrp-sdl", .root_module = sdl_mod });
    b.installArtifact(sdl_exe);
    const run_sdl = b.addRunArtifact(sdl_exe);
    if (b.args) |args| run_sdl.addArgs(args);
    b.step("run-sdl", "Run the MRP launcher/game in an SDL3 window").dependOn(&run_sdl.step);

    // --- Phase 0 smoke: run a tiny ARM blob through Unicorn -------------------
    const smoke_mod = b.createModule(.{ .root_source_file = b.path("tools/uc_smoke.zig"), .target = target, .optimize = optimize });
    addUnicorn(smoke_mod);
    const uc_smoke = b.addExecutable(.{ .name = "uc-smoke", .root_module = smoke_mod });
    b.installArtifact(uc_smoke);
    b.step("smoke", "Run the Unicorn smoke test").dependOn(&b.addRunArtifact(uc_smoke).step);

    // --- unit tests -----------------------------------------------------------
    // Test the pure-logic modules directly (no Unicorn dependency): the Unicorn
    // cImport contains a C union with an opaque member that refAllDecls can't analyze.
    const test_step = b.step("test", "Run core unit tests");
    for ([_][]const u8{"core/memory.zig"}) |root| {
        const tmod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tmod })).step);
    }

    // --- native libretro core (retro_* C ABI shared library) ------------------
    // `zig build libretro` -> zig-out/libretro/mrp_libretro.{dylib,so,dll}.
    // Native (or cross via -Dtarget).
    {
        const lr_mod = b.createModule(.{
            .root_source_file = b.path("frontends/libretro/core.zig"),
            .target = target,
            .optimize = optimize,
        });
        lr_mod.addImport("core", core);
        addUnicorn(lr_mod);
        const lr = b.addLibrary(.{ .name = "mrp_libretro", .root_module = lr_mod, .linkage = .dynamic });
        const ext = switch (target.result.os.tag) {
            .windows => "dll",
            .macos, .ios, .tvos, .watchos => "dylib",
            else => "so",
        };
        const inst = b.addInstallArtifact(lr, .{
            .dest_dir = .{ .override = .{ .custom = "libretro" } },
            .dest_sub_path = b.fmt("mrp_libretro.{s}", .{ext}),
        });
        b.step("libretro", "Build the native libretro core (shared library)").dependOn(&inst.step);
    }
}
