//! Native dispatch by `funcs_407AA2[]` index.
//!
//! Each ExEn class with native methods has a file under `natives/<package>/<Class>.zig`
//! exposing `pub fn handle(vm, idx, frame) Error!void`. The folder structure
//! mirrors the Java package name exactly:
//!   - exen.Graphics      → natives/exen/Graphics.zig
//!   - exen.util.Debug    → natives/exen/util/Debug.zig
//!   - java.lang.String   → natives/java/lang/String.zig
//!   - vm.sys.Runtime     → natives/vm/sys/Runtime.zig
//!   - catalog.Catalog    → natives/catalog/Catalog.zig
//!
//! Single-responsibility: each file owns exactly one class's native
//! handlers, period. No cross-class dispatch logic, no shared switch.
//!
//! Wiring: `core.boot()` initialises the VM with a no-op default
//! dispatcher; the frontend calls `core.setNativeDispatcher(&dispatch)`
//! before any gamelet bytecode runs so all NATIVE method invocations
//! reach this module.

const std = @import("std");
const core = @import("core");
const interp = core.interp;

// Per-class handler imports — kept alphabetical within each package.
const exen_AnimBitmap     = @import("exen/AnimBitmap.zig");
const exen_AnimFlash      = @import("exen/AnimFlash.zig");
const exen_DialogBox      = @import("exen/DialogBox.zig");
const exen_Displayable    = @import("exen/Displayable.zig");
const exen_FX             = @import("exen/FX.zig");
const exen_Gamelet        = @import("exen/Gamelet.zig");
const exen_Graphics       = @import("exen/Graphics.zig");
const exen_Image          = @import("exen/Image.zig");
const exen_List           = @import("exen/List.zig");
const exen_Math           = @import("exen/Math.zig");
const exen_Matrix3D       = @import("exen/Matrix3D.zig");
const exen_PlayField      = @import("exen/PlayField.zig");
const exen_RayCast        = @import("exen/RayCast.zig");
const exen_Resource       = @import("exen/Resource.zig");
const exen_Sms            = @import("exen/Sms.zig");
const exen_Vector3D       = @import("exen/Vector3D.zig");
const exen_util_Debug     = @import("exen/util/Debug.zig");
const java_lang_Class     = @import("java/lang/Class.zig");
const java_lang_Object    = @import("java/lang/Object.zig");
const java_lang_String    = @import("java/lang/String.zig");
const java_lang_StringBuffer = @import("java/lang/StringBuffer.zig");
const vm_sys_Runtime      = @import("vm/sys/Runtime.zig");
const catalog_Catalog     = @import("catalog/Catalog.zig");
const catalog_GameProperty = @import("catalog/GameProperty.zig");

/// Dispatch a native call by its `funcs_407AA2[]` index. The owning
/// class is determined by the contiguous index range each class
/// occupies in that table (see `docs/native_index_map.md`).
pub fn dispatch(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
    return switch (idx) {
        0...14   => exen_Graphics.handle(vm, idx, frame),
        15...29  => exen_Image.handle(vm, idx, frame),
        30...42  => exen_Resource.handle(vm, idx, frame),
        43...45  => exen_AnimBitmap.handle(vm, idx, frame),
        46...53  => exen_PlayField.handle(vm, idx, frame),
        54...64  => exen_AnimFlash.handle(vm, idx, frame),
        65...66  => exen_Displayable.handle(vm, idx, frame),
        67...88  => exen_Gamelet.handle(vm, idx, frame),
        89...100 => exen_Sms.handle(vm, idx, frame),
        101...102 => exen_DialogBox.handle(vm, idx, frame),
        103...108 => exen_FX.handle(vm, idx, frame),
        109      => exen_List.handle(vm, idx, frame),
        110...122 => exen_Math.handle(vm, idx, frame),
        123...128 => exen_Matrix3D.handle(vm, idx, frame),
        129...136 => exen_Vector3D.handle(vm, idx, frame),
        137...146 => exen_RayCast.handle(vm, idx, frame),
        147...150 => exen_util_Debug.handle(vm, idx, frame),
        151...154 => java_lang_Object.handle(vm, idx, frame),
        155...157 => java_lang_Class.handle(vm, idx, frame),
        158...165 => java_lang_String.handle(vm, idx, frame),
        166...174 => java_lang_StringBuffer.handle(vm, idx, frame),
        175...177 => vm_sys_Runtime.handle(vm, idx, frame),
        178...183 => catalog_Catalog.handle(vm, idx, frame),
        184      => catalog_GameProperty.handle(vm, idx, frame),
        else     => interp.Error.UnknownNative,
    };
}

/// Total size of the canonical `funcs_407AA2[]` native table.
pub const NATIVE_COUNT = 185;

/// Every native class module, in one place — the comptime tables below
/// derive from this list, so adding a class file means adding it here
/// (the dispatch `switch` above will remind you anyway).
const all_modules = .{
    exen_AnimBitmap,  exen_AnimFlash,   exen_DialogBox,
    exen_Displayable, exen_FX,          exen_Gamelet,
    exen_Graphics,    exen_Image,       exen_List,
    exen_Math,        exen_Matrix3D,    exen_PlayField,
    exen_RayCast,     exen_Resource,    exen_Sms,
    exen_Vector3D,    exen_util_Debug,  java_lang_Class,
    java_lang_Object, java_lang_String, java_lang_StringBuffer,
    vm_sys_Runtime,   catalog_Catalog,  catalog_GameProperty,
};

// The 24 class ranges must tile 0..NATIVE_COUNT-1 exactly — catches
// first_index/last_index typos at compile time.
comptime {
    var covered = [_]bool{false} ** NATIVE_COUNT;
    for (all_modules) |M| {
        var i: u32 = M.first_index;
        while (i <= M.last_index) : (i += 1) {
            if (covered[i]) @compileError(std.fmt.comptimePrint(
                "native idx {d} covered by two class ranges", .{i}));
            covered[i] = true;
        }
    }
    for (covered, 0..) |c, i| if (!c) @compileError(std.fmt.comptimePrint(
        "native idx {d} not covered by any class range", .{i}));
}

/// Static "is idx really implemented" table, derived at comptime from the
/// same `entries` tuples that generate each class's `handle` dispatcher —
/// so it can never drift from the runtime truth.
///
/// Convention: a class file with real handlers exposes `pub const entries`
/// (the tuple passed to `bridge.canonical`). A class file WITHOUT an
/// `entries` decl is a whole-class stub (its `handle` is
/// `defaultNativeStub` directly), so its idx range stays `false` here.
/// Intra-range gaps (idxs missing from an `entries` list) also stay
/// `false` — those fall through to `defaultNativeStub` inside
/// `bridge.canonical`. Consumed by `tools/coverage_audit.zig`.
pub const bound_natives: [NATIVE_COUNT]bool = blk: {
    var t = [_]bool{false} ** NATIVE_COUNT;
    for (all_modules) |M| {
        if (@hasDecl(M, "entries")) {
            for (M.entries) |e| t[e[0]] = true;
        }
    }
    break :blk t;
};

/// "name" → "Class.name" — unless the method-name portion (before the
/// first '(') already contains a '.', in which case the entry is fully
/// qualified (cross-class alias like "Integer.toString(int)") and is
/// used verbatim.
fn qualifiedName(comptime class: []const u8, comptime name: []const u8) []const u8 {
    const head = if (std.mem.indexOfScalar(u8, name, '(')) |p| name[0..p] else name;
    return if (std.mem.indexOfScalar(u8, head, '.') != null)
        name
    else
        class ++ "." ++ name;
}

/// idx → "Class.method", derived at comptime from the SAME `entries`
/// tuples that build each class's dispatcher (plus `stub_names` for
/// known-but-unported idxs) — it can never drift from dispatch truth.
/// Idxs with no known name render "Class.?N". Injected into core's
/// logging via `exen.setNativeNames` (core cannot import this module).
/// NOTE: the entry name strings are load-bearing for logs — keep them
/// accurate when porting.
pub const native_names: [NATIVE_COUNT][]const u8 = blk: {
    @setEvalBranchQuota(500_000);
    var t: [NATIVE_COUNT][]const u8 = undefined;
    for (all_modules) |M| { // per-class range default fill
        var i: u32 = M.first_index;
        while (i <= M.last_index) : (i += 1)
            t[i] = M.class_name ++ std.fmt.comptimePrint(".?{d}", .{i});
    }
    for (all_modules) |M| {
        if (@hasDecl(M, "entries"))
            for (M.entries) |e| {
                t[e[0]] = qualifiedName(M.class_name, e[1]);
            };
        if (@hasDecl(M, "stub_names"))
            for (M.stub_names) |e| {
                t[e[0]] = qualifiedName(M.class_name, e[1]);
            };
    }
    break :blk t;
};
