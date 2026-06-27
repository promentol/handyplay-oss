//! JNI-style typed bridge between the ExEn 2 bytecode VM and Zig
//! native handlers, built entirely on Zig's comptime reflection. Each
//! per-class file under `natives/` can declare its handlers as plain
//! Zig functions with normal types — `i32`, `bool`, `Handle`, `*Vm`,
//! etc. — and `bridge.wrap` synthesises the frame-marshalling shim at
//! comptime. The compiler inlines the marshalling away, so the runtime
//! cost is identical to hand-written `nativeArg(frame, N)` chains.
//!
//! Usage pattern (see natives/exen/Gamelet.zig for a worked example):
//!
//!     const bridge = @import("core").bridge;
//!     const Vm = @import("core").interp.Vm;
//!     const Handle = bridge.Handle;
//!
//!     fn isColor() i32 { return 1; }
//!     fn getScreenWidth(vm: *Vm) i32 {
//!         return if (vm.framebuffer) |fb| @intCast(fb.width) else 101;
//!     }
//!     fn screenUpdate(vm: *Vm, this: Handle, x: i32, y: i32) void {
//!         // ... real work
//!     }
//!
//!     pub const handle = bridge.dispatcher(.{
//!         .{ 67, "isColor",        isColor },
//!         .{ 70, "getScreenWidth", getScreenWidth },
//!         .{ 72, "screenUpdate",   screenUpdate },
//!     });
//!
//! Supported argument types (after any leading `*Vm` / `*Frame`
//! injection params):
//!
//!     Handle (=u32), u32, i32, bool       — 1 slot
//!     u64, i64                            — 2 slots (lo + hi)
//!     ?[]const u8                         — 1 slot (heap handle → bytes)
//!
//! Supported return types:
//!
//!     void                                — ret_slots = 0
//!     Handle, u32, i32, bool              — ret_slots = 1
//!     u64, i64                            — ret_slots = 2
//!     E!T                                 — unwrapped; on error VM
//!                                           halts via Error propagation
//!
//! Anything outside these tables produces a `@compileError` at the call
//! site so signature mistakes are caught the moment you build.

const std = @import("std");
const interp = @import("vm/interp.zig");

/// Heap-handle alias — same underlying u32 as `interp.Vm` uses, but
/// distinguished in the type system so signatures stay readable.
pub const Handle = u32;

/// Wrap a Zig function with normal types as an `interp.NativeFn` that
/// pulls args out of `frame.slab[...]` and packs the return value back
/// into `frame.ret_value` / `frame.ret_slots`. All marshalling is
/// comptime-inlined.
pub fn wrap(comptime f: anytype) interp.NativeFn {
    const F = @TypeOf(f);
    const info = @typeInfo(F).@"fn";

    return struct {
        fn call(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
            _ = idx;
            var args: std.meta.ArgsTuple(F) = undefined;
            comptime var slot_idx: u32 = 0;
            inline for (info.params, 0..) |p, i| {
                const T = p.type.?;
                if (T == *interp.Vm) {
                    args[i] = vm;
                } else if (T == *interp.Frame) {
                    args[i] = frame;
                } else if (T == u32 or T == Handle) {
                    args[i] = frame.slab[slot_idx];
                    slot_idx += 1;
                } else if (T == i32) {
                    args[i] = @as(i32, @bitCast(frame.slab[slot_idx]));
                    slot_idx += 1;
                } else if (T == bool) {
                    args[i] = frame.slab[slot_idx] != 0;
                    slot_idx += 1;
                } else if (T == u64) {
                    const lo: u64 = frame.slab[slot_idx];
                    const hi: u64 = frame.slab[slot_idx + 1];
                    args[i] = (hi << 32) | lo;
                    slot_idx += 2;
                } else if (T == i64) {
                    const lo: u64 = frame.slab[slot_idx];
                    const hi: u64 = frame.slab[slot_idx + 1];
                    args[i] = @as(i64, @bitCast((hi << 32) | lo));
                    slot_idx += 2;
                } else if (T == ?[]const u8) {
                    const h = frame.slab[slot_idx];
                    args[i] = if (vm.heap.get(h)) |inst| inst.bytes else null;
                    slot_idx += 1;
                } else {
                    @compileError("bridge.wrap: unsupported arg type '" ++ @typeName(T) ++
                        "' for native " ++ @typeName(F));
                }
            }

            const R = info.return_type.?;
            const ret_info = @typeInfo(R);
            if (ret_info == .error_union) {
                const inner = try @call(.auto, f, args);
                packReturn(ret_info.error_union.payload, inner, frame);
            } else {
                const result = @call(.auto, f, args);
                packReturn(R, result, frame);
            }
        }
    }.call;
}

fn packReturn(comptime T: type, value: T, frame: *interp.Frame) void {
    if (T == void) {
        frame.ret_slots = 0;
        return;
    }
    if (T == u32 or T == Handle) {
        frame.ret_value[0] = value;
        frame.ret_slots = 1;
        return;
    }
    if (T == i32) {
        frame.ret_value[0] = @as(u32, @bitCast(value));
        frame.ret_slots = 1;
        return;
    }
    if (T == bool) {
        frame.ret_value[0] = if (value) 1 else 0;
        frame.ret_slots = 1;
        return;
    }
    if (T == u64) {
        frame.ret_value[0] = @truncate(value);
        frame.ret_value[1] = @truncate(value >> 32);
        frame.ret_slots = 2;
        return;
    }
    if (T == i64) {
        const u: u64 = @bitCast(value);
        frame.ret_value[0] = @truncate(u);
        frame.ret_value[1] = @truncate(u >> 32);
        frame.ret_slots = 2;
        return;
    }
    @compileError("bridge: unsupported return type '" ++ @typeName(T) ++ "'");
}

/// Build a `NativeFn` that dispatches by `idx` among the provided
/// entries. Each entry is a tuple `.{ <idx:u32>, <name:string>, <fn> }`.
/// Indices not matched fall through to `interp.defaultNativeStub` so
/// the legacy catch-all behaviour (sentinel handles, return-0) still
/// applies until every per-class native is fully migrated.
///
/// The name is currently used only for trace logging via comptime
/// reflection later; even if you don't wire it up yet, you get a
/// human-readable mapping you can grep for.
pub fn dispatcher(comptime entries: anytype) interp.NativeFn {
    // Compile-time validation: every entry must be `.{ u32, []const u8, fn }`
    // and the function must be wrap-able.
    comptime {
        for (entries) |e| {
            const Tup = @TypeOf(e);
            const ti = @typeInfo(Tup).@"struct";
            if (ti.fields.len != 3) @compileError("bridge.dispatcher: each entry must be .{ idx, name, fn }");
        }
    }

    return struct {
        fn call(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
            inline for (entries) |e| {
                if (idx == e[0]) return wrap(e[2])(vm, idx, frame);
            }
            return interp.defaultNativeStub(vm, idx, frame);
        }
    }.call;
}

// ────────────────────────────────────────────────────────────────────
// Canonical-exact bridge — mirrors ref's funcs_407AA2 ABI.
//
// Canonical native signature (per `sub_407A94` + caller `sub_40E02C`):
//
//     __int16 __cdecl sub_xxx(BOOL *a1)
//     {
//         // a1[0] = receiver (`this`) for instance methods
//         // a1[1..argc] = explicit args
//         type x = a1[1];
//         ...
//         a1[0] = computed_value;        // optional: write return
//         return push_count;             // 0, 1, or 2 — slots to push
//     }
//
// Dispatcher does `SP += 4 * push_count` so whatever the native wrote at
// a1[0..push_count] becomes the new operand-stack top.
//
// Our Zig mirror: native takes (vm, args: ArgFrame) and returns i16.
// `ArgFrame` is a typed view over the slab slots; native reads args via
// `args.i32(N)` etc., writes return via `args.setReturn(v)`, and returns
// the push count directly. Faults are reported via `vm.signalFault(...)`.
//
// Use `bridge.canonical(.{...})` instead of `bridge.dispatcher(.{...})`
// for natives written in this style.

/// Typed view of the canonical arg-slot region (= ref's BOOL *a1).
/// Slot 0 is the receiver `this` for instance methods (or first arg for
/// statics) AND the return-value write target. Slots 1..argc are
/// explicit args.
pub const ArgFrame = struct {
    ptr: [*]u32,

    // — read args (canonical's a1[N]) —
    pub inline fn raw(self: ArgFrame, n: usize) u32 { return self.ptr[n]; }
    pub inline fn this(self: ArgFrame) Handle { return self.ptr[0]; }
    pub inline fn handle(self: ArgFrame, n: usize) Handle { return self.ptr[n]; }
    pub inline fn getU32(self: ArgFrame, n: usize) u32 { return self.ptr[n]; }
    pub inline fn getI32(self: ArgFrame, n: usize) i32 { return @bitCast(self.ptr[n]); }
    pub inline fn getBool(self: ArgFrame, n: usize) bool { return self.ptr[n] != 0; }
    pub inline fn getLong(self: ArgFrame, lo: usize) u64 {
        return (@as(u64, self.ptr[lo + 1]) << 32) | @as(u64, self.ptr[lo]);
    }

    // — write return value (canonical's *a1 = v) —
    pub inline fn setReturn(self: ArgFrame, v: u32) void { self.ptr[0] = v; }
    pub inline fn setReturnI32(self: ArgFrame, v: i32) void { self.ptr[0] = @bitCast(v); }
    pub inline fn setReturnBool(self: ArgFrame, v: bool) void { self.ptr[0] = if (v) 1 else 0; }
    pub inline fn setReturnLong(self: ArgFrame, v: u64) void {
        self.ptr[0] = @truncate(v);
        self.ptr[1] = @truncate(v >> 32);
    }
};

/// Canonical-shape native handler — mirrors ref's
/// `__int16 sub_xxx(BOOL *a1)`. Returns the push count (0/1/2).
pub const CanonicalFn = *const fn (vm: *interp.Vm, args: ArgFrame) i16;

/// Build a `NativeFn` that dispatches by idx among canonical-shape
/// handlers. Each entry is `.{ idx: u32, name: []const u8, fn: CanonicalFn }`.
///
/// After the native returns, the bridge propagates `frame.slab[0..push]`
/// into `frame.ret_value` so the existing INVOKE post-processing
/// (which pushes ret_value back onto caller's stack) works unchanged.
pub fn canonical(comptime entries: anytype) interp.NativeFn {
    comptime {
        for (entries) |e| {
            const Tup = @TypeOf(e);
            const ti = @typeInfo(Tup).@"struct";
            if (ti.fields.len != 3) @compileError("bridge.canonical: each entry must be .{ idx, name, fn }");
        }
    }

    return struct {
        fn call(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
            inline for (entries) |e| {
                if (idx == e[0]) {
                    const args = ArgFrame{ .ptr = frame.slab.ptr };
                    const push: i16 = e[2](vm, args);
                    // Negative push counts are canonical's error sentinel
                    // (e.g. -2 from drawImage error branch). The tick is
                    // dying via signalFault → just push 0 slots.
                    const push_u: u8 = if (push < 0) 0 else @intCast(push);
                    frame.ret_slots = push_u;
                    if (push_u >= 1) frame.ret_value[0] = frame.slab[0];
                    if (push_u >= 2) frame.ret_value[1] = frame.slab[1];
                    return;
                }
            }
            return interp.defaultNativeStub(vm, idx, frame);
        }
    }.call;
}
