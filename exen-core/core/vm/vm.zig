//! `Vm` — the bytecode interpreter's main state container. Holds the
//! shared operand slab, class-object table, heap, and host bindings.
//!
//! Method invocation goes through `invokeMethodInfo`, which dispatches
//! to either `native_fn` (set by the host frontend via
//! `core.setNativeDispatcher`) or `runFrame` (looping `handlers[op]`
//! from `opcodes.zig`).

const std = @import("std");
const cr = @import("../classfile/registry.zig");
const gfx = @import("../gfx.zig");
const dbg = @import("../debug/names.zig");

const err_mod = @import("error.zig");
const log_fmt = @import("log_fmt.zig");
const frame_mod = @import("frame.zig");
const classobj_mod = @import("classobj.zig");
const heap_mod = @import("heap.zig");
const opcodes = @import("opcodes/mod.zig");
const natives_legacy = @import("natives_legacy.zig");

const log = std.log.scoped(.interp);
const classStr = log_fmt.classStr;
const methodStr = log_fmt.methodStr;

pub const Error = err_mod.Error;
pub const Frame = frame_mod.Frame;
pub const ClassObject = classobj_mod.ClassObject;
pub const Heap = heap_mod.Heap;
pub const Instance = heap_mod.Instance;

/// Well-known class hashes used by `INVOKESPECIAL` and the static
/// fallback chain in `INVOKESTATIC`. Both verified via CRC-32 of the
/// class name string (see `debug/names.zig`).
pub const EXEN_GAMELET: u32 = 0xE127B0E1;
pub const JAVA_LANG_OBJECT: u32 = 0x4161C4A6;

pub const NativeFn = *const fn (vm: *Vm, idx: u32, frame: *Frame) Error!void;

pub const Vm = struct {
    allocator: std.mem.Allocator,
    registry: *const cr.Registry,
    slab: []u32,
    slab_top: u32 = 0,
    class_objects: std.AutoHashMap(u32, *ClassObject),
    heap: Heap,
    native_fn: NativeFn = natives_legacy.defaultNativeStub,
    halted: bool = false,
    halt_reason: HaltReason = .never_ran,
    /// Set by `Gamelet.exitVm()` (idx 73, sub_424FD2). Mirrors the
    /// canonical's `*(dword_45FF3C + 36) = 1` flag write. The frontend
    /// is expected to poll this between ticks and gracefully shut down
    /// the player when seen. Does NOT halt the VM directly — the
    /// gamelet may still complete the current tick first, matching
    /// canonical behavior (the flag is checked at the device main-loop
    /// boundary, not mid-execution).
    exit_requested: bool = false,
    /// Deterministic millisecond clock, advanced by `exen.tick(delta_ms)`. Replaces
    /// wall-clock time as the source for `Gamelet.getTimerTickCount`, so execution is
    /// reproducible (a prerequisite for save-states / rewind — same reason mre uses a
    /// tick-driven clock). Captured in the save-state via the Vm struct snapshot.
    clock_ms: u64 = 0,
    /// Gamelet PRNG state (exen.Math random/setRandSeed). On the Vm — not a module
    /// global — so save-states capture it and replay/rewind reproduce the same
    /// sequence. Canonical pair-state PRNG; seed defaults match the boot pool.
    rng_a: u32 = 0xCAFE_BABE,
    rng_b: u32 = 0,
    /// Pointer to the host's simulated LCD framebuffer. Set by
    /// `exen.bootstrapGamelet` so the Graphics natives can blit
    /// directly into it. Optional — when null, draw natives are
    /// silently dropped (e.g. headless tests).
    framebuffer: ?*gfx.Framebuffer = null,
    /// Borrowed slice of the loaded .exn's raw bytes — set by
    /// `exen.loadExn` after parsing. The `Resource.*` native handlers
    /// dereference this directly: each Resource carries
    /// `(base_offset, length, position)` and reads from
    /// `exn_raw[base + pos]`.
    exn_raw: ?[]const u8 = null,

    pub const HaltReason = union(enum) {
        never_ran,
        normal_return,
        unknown_opcode: struct { op: u8, pc: u32, method_hash: u32 },
        unknown_native: struct { idx: u32 },
        host_aborted,
        null_pointer,
        method_not_found: u32,
        /// Canonical's "non-catchable Internal Exception" path —
        /// when NPE/etc. propagates with no handler in any frame,
        /// canonical's `sub_407A13` sets state==2 and the outer loop
        /// resumes on the next tick. We mirror that here: tick()
        /// catches the propagated error, logs, and the next
        /// `Bootstrap.tick` runs from a clean state. The u32 is the
        /// canonical exception code (910855525 = 0x36430125 for NPE).
        internal_exception: u32,
    };

    /// Canonical exception code for "null receiver" (sub_40C304 sets
    /// `dword_51F900 + 28 = 910855525`). We tag halts with this so
    /// logs match canonical's `aInternalExcept` trace shape.
    pub const EX_NULL_POINTER: u32 = 910855525;

    /// Canonical fault helper — mirrors ref's two-step pattern
    /// of `sub_434771(tag); sub_407A13();` that native handlers call
    /// before returning when they detect a non-catcheable invariant
    /// violation (null target, OOM, etc.). Tags the current tick for
    /// abort; native should `return 0` (or whatever push count it
    /// would normally have) right after this call.
    pub fn signalFault(self: *Vm, code: u32, tag: []const u8) void {
        std.log.scoped(.interp).warn(
            "Non-Catcheable Internal Exception: {s} (code=0x{x:0>8})",
            .{ tag, code },
        );
        self.halt_reason = .{ .internal_exception = code };
        self.halted = true;
    }

    pub fn init(allocator: std.mem.Allocator, heap_alloc: std.mem.Allocator, registry: *const cr.Registry, slab_size: u32) !Vm {
        // `allocator` backs the slab + class statics; `heap_alloc` backs the object
        // heap so the GC can reclaim it. Today exen.zig passes the same freeing gpa for
        // both — the params stay separate so a future ThreadX pool can take over just
        // the object heap. The save-state serializes slab + statics + object heap
        // explicitly (no allocator-blob dump). See exen.zig.
        const slab = try allocator.alloc(u32, slab_size);
        if (!palette_state_init) {
            palette_state = std.AutoHashMap(u32, PaletteState).init(heap_alloc);
            palette_state_init = true;
        }
        return .{
            .allocator = allocator,
            .registry = registry,
            .slab = slab,
            .class_objects = std.AutoHashMap(u32, *ClassObject).init(allocator),
            .heap = Heap.init(heap_alloc),
        };
    }

    /// Conservative mark-sweep GC. Roots = every class's statics + class handle, the
    /// live operand slab, and the bootstrap gamelet; from each marked object we follow
    /// any field / array slot whose u32 value is itself a live handle. Run between ticks
    /// (slab quiescent). Conservative: an int equal to a live handle over-retains but we
    /// never free a reachable object — so a gamelet can't crash from a missed reference.
    pub fn collectGarbage(self: *Vm) void {
        const A = self.heap.allocator;
        var cit = self.heap.instances.valueIterator();
        while (cit.next()) |p| p.*.gc_seen = false;

        var work: std.ArrayListUnmanaged(u32) = .{};
        defer work.deinit(A);
        const mark = struct {
            fn f(vm: *Vm, w: *std.ArrayListUnmanaged(u32), a: std.mem.Allocator, h: u32) void {
                if (h == 0) return;
                const inst = vm.heap.instances.get(h) orelse return;
                if (inst.gc_seen) return;
                inst.gc_seen = true;
                w.append(a, h) catch {};
            }
        }.f;

        // Roots: every class's statics + class handle …
        var co_it = self.class_objects.valueIterator();
        while (co_it.next()) |co| {
            for (co.*.statics) |v| mark(self, &work, A, v);
            mark(self, &work, A, co.*.class_handle);
        }
        // … the LIVE operand region only (`slab[0..slab_top]`). GC runs between ticks
        // with the frame stack unwound, so slab_top is at its baseline and everything
        // above it is dead memory from popped frames — next tick's frames start at
        // slab_top and overwrite it, so nothing above is ever read. Scanning the full
        // 256K-word slab every tick (262K hashmap lookups) was the dominant per-tick
        // cost and made stale handle-valued ints in dead slots falsely retain objects.
        for (self.slab[0..self.slab_top]) |v| mark(self, &work, A, v);
        // … and the bootstrap gamelet (pinned; it may be held only by this global).
        mark(self, &work, A, bootstrap_gamelet_handle);

        // Transitive: follow any field / array slot that's a live handle.
        while (work.pop()) |h| {
            const inst = self.heap.instances.get(h) orelse continue;
            for (inst.fields) |v| mark(self, &work, A, v);
            if (inst.field_map_init) {
                var fit = inst.field_map.valueIterator();
                while (fit.next()) |v| mark(self, &work, A, v.*);
            }
            if (inst.ints) |arr| for (arr) |v| mark(self, &work, A, v);
        }

        // Sweep — gather dead handles first, then free (don't mutate the map mid-scan).
        var dead: std.ArrayListUnmanaged(u32) = .{};
        defer dead.deinit(A);
        var sit = self.heap.instances.iterator();
        while (sit.next()) |e| if (!e.value_ptr.*.gc_seen) dead.append(A, e.key_ptr.*) catch {};
        for (dead.items) |h| {
            _ = palette_state.remove(h);
            self.heap.freeOne(h);
        }
    }

    pub fn deinit(self: *Vm, allocator: std.mem.Allocator) void {
        var it = self.class_objects.valueIterator();
        while (it.next()) |co| allocator.destroy(co.*);
        self.class_objects.deinit();
        self.heap.deinit();
        allocator.free(self.slab);
        if (palette_state_init) {
            palette_state.deinit();
            palette_state_init = false;
        }
    }

    /// Side-table for Image palette state — keyed by Image handle.
    /// Image.getPalette/setPalette/transformToSystemPalette work on
    /// this without touching `Instance` (which broke memory layout
    /// when fields were added there directly). Each entry owns its
    /// 256-byte palette buffer; cursor tracks the next setPalette
    /// byte; cleared by getPalette.
    pub var palette_state: std.AutoHashMap(u32, PaletteState) = undefined;
    pub var palette_state_init: bool = false;

    pub const PaletteState = struct {
        bytes: [256]u8 = [_]u8{0} ** 256,
        cursor: u32 = 0,
    };

    /// Resolve a method by walking the actual super-class chain
    /// recovered from each class record's byte-+40 super-index. Mirrors
    /// `sub_40DF05` (the simulator's virtual dispatcher).
    pub fn resolveVirtual(self: *const Vm, recv_class_hash: u32, method_hash: u32) ?cr.MethodInfo {
        return self.registry.resolveVirtual(recv_class_hash, method_hash);
    }

    /// Get-or-create the class object for `class_hash`. Mirrors
    /// `sub_40E006` + lazy `sub_40E359` allocation: the FIRST time a
    /// class is touched we also run its `<clinit>` (if present) so
    /// static-field singletons get initialised. Re-entrancy is fine —
    /// the ClassObject is inserted before clinit runs, so nested
    /// ensureClassObject calls for the same class won't re-trigger
    /// initialisation.
    pub fn ensureClassObject(self: *Vm, class_hash: u32) Error!*ClassObject {
        const gop = try self.class_objects.getOrPut(class_hash);
        if (gop.found_existing) return gop.value_ptr.*;

        const co = try self.allocator.create(ClassObject);
        co.* = .{ .hash = class_hash };
        gop.value_ptr.* = co;

        // Run <clinit> if the class record advertises one.
        if (self.registry.lookup(class_hash)) |rec| {
            if (rec.clinit()) |mi_clinit| {
                log.debug("→ <clinit> {s}::{s} body_offset=0x{x:0>4}", .{
                    classStr(class_hash), methodStr(class_hash, mi_clinit.hash), mi_clinit.body_offset,
                });
                // Save/restore halted/halt_reason so a clinit's normal
                // RETURN doesn't appear as the VM's terminal state.
                const saved_halt = self.halted;
                const saved_reason = self.halt_reason;
                self.halted = false;
                self.invokeMethodInfo(mi_clinit, null, &.{}) catch |e| {
                    log.warn("  <clinit> for 0x{x:0>8} failed: {s}", .{ class_hash, @errorName(e) });
                };
                self.halted = saved_halt;
                self.halt_reason = saved_reason;
            }
        }
        return co;
    }

    pub fn invokeStatic(self: *Vm, class_hash: u32, method_hash: u32) Error!void {
        const mi = self.registry.findMethod(class_hash, method_hash) orelse return Error.MethodNotFound;
        try self.invokeMethodInfo(mi, null, &.{});
    }

    /// Invoke a method. `caller` is the frame that issued the invoke;
    /// `args` are the values to place into `locals[0..args.len]`.
    pub fn invokeMethodInfo(self: *Vm, mi: cr.MethodInfo, caller: ?*Frame, args: []const u32) Error!void {
        if (mi.isNative()) {
            const idx = mi.nativeIndex();
            // Structural-only label — no guessed names. `native_idx` and
            // `sub_*` are 100% reliable (read from method.body_offset bytes
            // and funcs_407AA2[idx] respectively). Class hash maps to a
            // canonical class name when present (built-in class), "?" for
            // gamelet-local classes (.exn records are name-stripped).
            // Method name appears only when verified (see dbg.methodName
            // docstring). Unverified hashes show as bare 0xHHHHHHHH so an
            // unknown name never silently lies via positional drift.
            log.info("→ NATIVE [{d}] {s}  {s} method={s} class=0x{x:0>8} hash=0x{x:0>8} args={d}", .{
                idx,
                dbg.nativeSubName(idx),
                dbg.className(mi.class.hash) orelse "?",
                methodStr(mi.class.hash, mi.hash),
                mi.class.hash,
                mi.hash,
                args.len,
            });
            // Make args visible to the native handler by parking them
            // in the fake frame's slab as if they were locals.
            const native_slab = self.slab[self.slab_top..];
            const arg_count: u32 = @intCast(@min(args.len, native_slab.len));
            for (0..arg_count) |i| native_slab[i] = args[i];
            var fake: Frame = .{
                .caller = caller,
                .method = mi,
                .class_hash = mi.class.hash,
                .bytecode = mi.class.bytes,
                .slab = native_slab,
                .locals_count = arg_count,
                .sp = arg_count,
                .pc = 0,
            };
            try self.native_fn(self, idx, &fake);
            // Propagate the native's return value (if any) to the caller.
            if (caller) |c| {
                if (fake.ret_slots >= 1) try c.push(fake.ret_value[0]);
                if (fake.ret_slots >= 2) try c.push(fake.ret_value[1]);
            }
            return;
        }

        const max_stack = mi.maxStack();
        const locals_count = mi.localsCount();
        // Per-frame safety margin. Canonical sub_40E02C uses +13, but
        // Terminator's class-0x2eb36ef0 method 0x3f52d41c (and friends)
        // genuinely under-declare max_stack in the .exn header — they
        // say max_stack=7 yet push 20+ operand-stack items via deeply
        // nested NEW/INVOKE sequences during level loading.
        //
        // Per-frame safety margin: gives extra slots per frame to absorb
        // the under-declaration. Some Terminator methods on class
        // 0x2eb36ef0 (e.g. 0x9118b171, 0x3f52d41c) have list-walking
        // loops where each iteration leaks ~10 operand-stack slots
        // without popping. Canonical sub_40A01A (and other push sites)
        // have NO per-push bounds check — they silently overrun into
        // the parent frame's slab tail. We model this with a generous
        // per-frame margin instead, since our frame.push has a hard
        // bound check.
        //
        // +2000 absorbs even pathological under-declarations. We need
        // this margin because some methods (e.g. Terminator's
        // 0x2eb36ef0 class) genuinely under-declare max_stack by 20+
        // and push without popping in inner loops. With our 2MB slab,
        // frames use ~2010 words each → ~1040 frame depth — XMasTales's
        // level-load tree-walk fits comfortably.
        const FRAME_MARGIN: u32 = 2000;
        if (self.slab_top + locals_count + max_stack + FRAME_MARGIN > self.slab.len) return Error.StackOverflow;

        // The simulator allocates `locals + max_stack + 13` u32 slots
        // per frame (see sub_40E02C:12124 where the bounds check uses
        // `4*(locals + max_stack + 13)`). That extra 13 slots is the
        // frame header / safety margin; ExEn bytecode appears to rely
        // on it (some methods push beyond their declared max_stack
        // briefly during expression evaluation). Match it here.
        const frame_start = self.slab_top;
        const frame_end = frame_start + locals_count + max_stack + FRAME_MARGIN;
        self.slab_top = frame_end;

        // Initialise locals: copy args into locals[0..args.len], zero the rest.
        const n_args: u32 = @intCast(@min(args.len, locals_count));
        for (0..n_args) |i| self.slab[frame_start + i] = args[i];
        for (self.slab[frame_start + n_args .. frame_start + locals_count]) |*v| v.* = 0;

        var frame: Frame = .{
            .caller = caller,
            .method = mi,
            .class_hash = mi.class.hash,
            // The full class record IS the bytecode buffer — opcodes
            // index into it absolutely (e.g. 2-byte operand is an
            // offset within this same buffer).
            .bytecode = mi.class.bytes,
            // Combined locals + operand stack region; sp starts at
            // locals_count so pop/push touch only the operand-stack
            // portion (and DUP_X1's `sp-2` access can dip into locals
            // exactly like the simulator does).
            .slab = self.slab[frame_start..frame_end],
            .locals_count = locals_count,
            .sp = locals_count,
            .pc = mi.body_offset + 6, // skip 6-byte method header
        };

        log.debug("→ BYTECODE {s}::{s}  locals={d} max_stack={d} pc=0x{x:0>4}", .{
            classStr(mi.class.hash), methodStr(mi.class.hash, mi.hash), locals_count, max_stack, frame.pc,
        });

        try self.runFrame(&frame);
        self.slab_top = frame_start;
        // Propagate the return value (if any) onto the caller's stack.
        // IRETURN / ARETURN push 1 slot; LRETURN / DRETURN push 2.
        if (caller) |c| {
            if (frame.ret_slots >= 1) try c.push(frame.ret_value[0]);
            if (frame.ret_slots >= 2) try c.push(frame.ret_value[1]);
        }
    }

    /// When true, log every opcode dispatched (very noisy — for tracing).
    pub var trace: bool = false;

    /// One-shot trace burst — when > 0, force `trace` on and decrement
    /// per opcode until it hits 0, then auto-disable. Lets callers
    /// (e.g. the keypress dispatcher) capture a focused window of
    /// bytecode execution without flooding the entire run log.
    pub var trace_burst_remaining: u32 = 0;

    /// When non-zero, restricts `trace` / `trace_burst_remaining` to fire
    /// only inside frames whose `method.hash` matches. Useful for
    /// surgical disassembly of a single method (e.g. inspecting which
    /// IFEQ branch a hot loop takes) without flooding with neighbour
    /// methods' opcodes.
    pub var trace_only_method_hash: u32 = 0;

    /// Globally accessible handle for the freshly-allocated gamelet
    /// instance. Set by `exen.bootstrapGamelet` before invoking
    /// `vm.sys.Bootstrap.init`. Allows the
    /// `java.lang.Class.newInstance` native stub to return the SAME
    /// instance the host already constructed, so Bootstrap.statics[0]
    /// ends up pointing to it.
    pub var bootstrap_gamelet_handle: u32 = 0;

    /// Per-tick instruction budget. The real simulator has none — it
    /// runs Bootstrap.tick to its natural RETURN every WM_TIMER fire.
    /// We keep a generous cap as an infinite-loop safety net: 50M ops
    /// is enough for the heaviest level-load tick we've measured
    /// (Crash's PlayField populate at ~4K setCellTile + draws) while
    /// still firing before a real infinite loop locks up the SDL
    /// event pump. Earlier the cap was 200K which silently truncated
    /// legitimate level-load work on Pikubi and Ice-Racer, leaving
    /// the VM in a half-initialised state for the next tick.
    pub var instr_budget_used: u64 = 0;
    pub const INSTR_BUDGET_PER_TICK: u64 = 50_000_000;

    fn runFrame(self: *Vm, frame: *Frame) Error!void {
        const handlers = comptime opcodes.buildOpTable();
        while (!self.halted and !frame.returning) {
            if (frame.pc >= frame.bytecode.len) {
                self.halt_reason = .normal_return;
                return;
            }
            instr_budget_used += 1;
            if (instr_budget_used > INSTR_BUDGET_PER_TICK) {
                self.halted = true;
                self.halt_reason = .normal_return;
                return;
            }
            const op = frame.bytecode[frame.pc];
            const opc_pc = frame.pc;
            frame.pc += 1;
            // Burst trace overrides the steady-state `trace` flag —
            // any caller that wants a focused window can set
            // `trace_burst_remaining = N` to log the next N opcodes
            // and then auto-disable.
            const burst_on = trace_burst_remaining > 0;
            if (burst_on) trace_burst_remaining -= 1;
            const method_match = trace_only_method_hash == 0 or
                frame.method.hash == trace_only_method_hash;
            if ((trace or burst_on) and method_match) log.debug("    {s} (0x{x:0>2}) @ PC=0x{x:0>4} in {s}", .{
                opcodes.opName(op), op, opc_pc, classStr(frame.class_hash),
            });
            handlers[op](self, frame, op) catch |e| {
                log.warn("{s} (0x{x:0>2}) at PC=0x{x:0>4} failed: {s}", .{
                    opcodes.opName(op), op, opc_pc, @errorName(e),
                });
                self.halted = true;
                return e;
            };
        }
    }
};
