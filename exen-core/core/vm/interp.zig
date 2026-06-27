//! Bytecode interpreter — umbrella module that re-exports the VM API
//! from the per-responsibility files under `core/vm/`. Keeps the
//! `core.interp.X` import path stable for `natives/**` and external
//! callers while the implementation is split into focused modules:
//!
//!   error.zig          — Error enum
//!   log_fmt.zig        — classStr / methodStr name formatters
//!   frame.zig          — Frame struct (per-method execution state)
//!   classobj.zig       — ClassObject (per-class statics)
//!   heap.zig           — Instance + Heap (handle table)
//!   vm.zig             — Vm struct (init/deinit/invoke/runFrame)
//!   opcodes.zig        — all op* handlers + buildOpTable
//!   natives_legacy.zig — defaultNativeStub catch-all
//!
//! Native-implementation helpers (instField / graphicsTarget /
//! loadResource / FIELD_* hashes) live under `natives/_helpers.zig`
//! since they're consumed exclusively by per-class native files.
//!
//! `core/vm/interp.zig` previously held all of this in a 2700-line
//! god class; the split makes each piece's responsibility explicit
//! without changing any behaviour.

const std = @import("std");
const cr = @import("../classfile/registry.zig");

// ── leaf types ─────────────────────────────────────────────────────────
const err_mod = @import("error.zig");
const frame_mod = @import("frame.zig");
const classobj_mod = @import("classobj.zig");
const heap_mod = @import("heap.zig");
const vm_mod = @import("vm.zig");
const natives_legacy_mod = @import("natives_legacy.zig");

// ── public types ───────────────────────────────────────────────────────
pub const Error = err_mod.Error;
pub const Frame = frame_mod.Frame;
pub const ClassObject = classobj_mod.ClassObject;
pub const Instance = heap_mod.Instance;
pub const Heap = heap_mod.Heap;
pub const Vm = vm_mod.Vm;
pub const NativeFn = vm_mod.NativeFn;

// ── well-known class hashes ────────────────────────────────────────────
pub const EXEN_GAMELET = vm_mod.EXEN_GAMELET;
pub const JAVA_LANG_OBJECT = vm_mod.JAVA_LANG_OBJECT;

// Helpers (instField, graphicsTarget, loadResource, FIELD_*, etc.)
// moved to `natives/_helpers.zig` — they're native-implementation
// utilities, not VM internals. Per-class native files import them
// directly via `@import("../_helpers.zig")`.

// ── legacy native catch-all (delegated to by un-migrated natives) ──────
pub const defaultNativeStub = natives_legacy_mod.defaultNativeStub;

// ── tests ──────────────────────────────────────────────────────────────

test "run vm.sys.Bootstrap.tick to completion" {
    const builtins = std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/unk_4494F0.bin", 1 << 20) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(builtins);

    var reg = cr.Registry.init(std.testing.allocator);
    defer reg.deinit();
    _ = try reg.scanBuffer(builtins, 0, .builtin);

    var vm = try Vm.init(std.testing.allocator, &reg, 4096);
    defer vm.deinit(std.testing.allocator);

    try vm.invokeStatic(cr.CLASS_VM_SYS_BOOTSTRAP, cr.METHOD_TICK);
}
