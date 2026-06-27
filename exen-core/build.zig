//! Build entry for ExEn 2 Player.
//!
//! Layout:
//!   core/        — frontend-agnostic VM, classfile, exn, codecs
//!   natives/     — one file per ExEn class (185 native handlers)
//!   frontends/   — host shells (sdl, future emscripten/libretro)
//!   tools/       — standalone CLI utilities (disasm, extract_*)
//!   assets/      — embedded binary blobs (font, builtin 4CVP records)
//!   samples/     — gamelet .exn test corpus
//!   reference/   — the reference simulator + reference listings (RE artifacts; not in build)
//!
//! Usage:
//!   zig build                        — default frontend (sdl3)
//!   zig build -Dfrontend=sdl3        — explicit SDL3 frontend
//!   zig build -Dfrontend=emscripten  — placeholder (TODO)
//!   zig build -Dfrontend=libretro    — placeholder (TODO)
//!   zig build tools                  — build standalone CLIs into zig-out/bin/
//!   zig build run                    — build + run with default gamelet
//!   zig build run -- "samples/Crash Bandicoot.exn"
//!     (anything after `--` is passed as argv[1] to the player)

const std = @import("std");

pub const Frontend = enum { sdl3, wasm, emscripten, libretro };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const frontend = b.option(
        Frontend,
        "frontend",
        "Which host shell to build (default: sdl3)",
    ) orelse .sdl3;

    // ── core module: frontend-agnostic VM ────────────────────────────────
    // Exposes everything via core/exen.zig as the umbrella file. Other
    // modules import it as `@import("core")`.
    const core = b.addModule("core", .{
        .root_source_file = b.path("core/exen.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── natives module: per-class ExEn native handlers ───────────────────
    // Imports `core` for Vm/Frame types. Frontends inject it via
    // `core.setNativeDispatcher(&natives.dispatch)` after `core.boot()`.
    const natives = b.addModule("natives", .{
        .root_source_file = b.path("natives/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    natives.addImport("core", core);

    // ── frontend ─────────────────────────────────────────────────────────
    switch (frontend) {
        .sdl3 => buildSdl3Frontend(b, target, optimize, core, natives),
        .wasm => buildWasmFrontend(b, optimize),
        .emscripten => {
            // TODO: Emscripten/WebAssembly host shell. The current TODO:
            //  - Replace SDL3 with a JS-bridged canvas + key event source
            //  - Use std.os.emscripten for filesystem (preload .exn files)
            //  - Wire `--target=wasm32-emscripten`
            std.debug.print("frontend=emscripten not yet implemented\n", .{});
        },
        .libretro => {
            // The libretro core is its own step — build it with `zig build libretro`
            // (defined below), not via -Dfrontend.
            std.debug.print("use `zig build libretro` to build the libretro core\n", .{});
        },
    }

    // ── tools step ───────────────────────────────────────────────────────
    const tools_step = b.step("tools", "Build standalone CLI utilities (disasm, extract_*)");
    inline for (.{ "disasm", "extract_pngs", "extract_strings" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        tools_step.dependOn(&install.step);
    }

    // Coverage audit needs access to the `core` module (registry +
    // methodName table), so it goes through its own step. Run with:
    //   zig build coverage -- samples/wallbreaker.exn [0xCLASSHASH]
    const coverage_exe = b.addExecutable(.{
        .name = "coverage_audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/coverage_audit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        }),
    });
    const coverage_install = b.addInstallArtifact(coverage_exe, .{});
    tools_step.dependOn(&coverage_install.step);

    const coverage_run = b.addRunArtifact(coverage_exe);
    coverage_run.step.dependOn(&coverage_install.step);
    if (b.args) |args| coverage_run.addArgs(args);
    const coverage_step = b.step("coverage", "Run the static coverage audit on a gamelet");
    coverage_step.dependOn(&coverage_run.step);

    // exn_info — gamelet metadata extractor (name + icon). Needs the
    // `core` module for the metadata.zig helper.
    const exn_info_exe = b.addExecutable(.{
        .name = "exn_info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/exn_info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        }),
    });
    const exn_info_install = b.addInstallArtifact(exn_info_exe, .{});
    tools_step.dependOn(&exn_info_install.step);

    // --- native libretro core (retro_* C ABI shared library) ------------------
    // `zig build libretro` -> zig-out/libretro/exen_libretro.{dylib,so,dll}.
    // Pure Zig (no native deps); cross-compiles via -Dtarget.
    {
        const lr_mod = b.createModule(.{
            .root_source_file = b.path("frontends/libretro/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "natives", .module = natives },
            },
        });
        const lr = b.addLibrary(.{ .name = "exen_libretro", .root_module = lr_mod, .linkage = .dynamic });
        const ext = switch (target.result.os.tag) {
            .windows => "dll",
            .macos, .ios, .tvos, .watchos => "dylib",
            else => "so",
        };
        const inst = b.addInstallArtifact(lr, .{
            .dest_dir = .{ .override = .{ .custom = "libretro" } },
            .dest_sub_path = b.fmt("exen_libretro.{s}", .{ext}),
        });
        b.step("libretro", "Build the native libretro core (shared library)").dependOn(&inst.step);
    }
}

fn buildSdl3Frontend(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    natives: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "exen-player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("frontends/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "natives", .module = natives },
            },
        }),
    });

    // SDL3 from Homebrew (macOS) — `brew install sdl3` puts headers in
    // /opt/homebrew/include and the dylib in /opt/homebrew/lib. For other
    // OSes we'd swap in pkg-config or a vendored copy.
    exe.linkLibC();
    exe.linkSystemLibrary("SDL3");
    exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the SDL3 player");
    run_step.dependOn(&run.step);
}

// ── WASM frontend ────────────────────────────────────────────────────────
// Produces a freestanding wasm32 module exposing the read-only catalog
// API (validate / name / icon). JS loads the .wasm, writes a .exn buffer
// into the module's linear memory via `wasm_alloc` + Module.HEAPU8.set(),
// then calls `exn_validate` / `exn_name_into` / `exn_icon_info`.
//
// Build with:  zig build -Dfrontend=wasm
// Output:      zig-out/bin/exen-catalog.wasm
//
// The wasm build re-creates `core` against the wasm32-freestanding
// target rather than reusing the host-target module from the caller,
// because target metadata flows through the dependency graph and
// must match the executable's target.
fn buildWasmFrontend(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // For the WASM catalog API we only need the pure-bytes metadata
    // module; importing the full `core` umbrella drags in vm_state,
    // dispatch tables, audio backend, etc. that don't compile on
    // wasm32-freestanding. `core/wasm_root.zig` re-exports just the
    // freestanding-safe pieces (loader + metadata) so cross-dir
    // imports inside `core/` still work.
    const wasm_core = b.addModule("wasm_core", .{
        .root_source_file = b.path("core/wasm_root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "exen-catalog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("frontends/wasm/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metadata", .module = wasm_core }},
        }),
    });
    exe.entry = .disabled; // no _start in WASI sense; we export functions
    exe.rdynamic = true;   // keep all `export fn` symbols
    b.installArtifact(exe);
}
