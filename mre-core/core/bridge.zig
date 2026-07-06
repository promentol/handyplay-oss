//! ARM↔native bridge: the trampoline mechanism for guest→native calls.
//!
//! A page of 2-byte `BX LR` Thumb stubs lives in shared memory. `vm_get_sym_entry`
//! hands the guest the EMU address of stub `i` (Thumb-tagged). When the guest BL's
//! into it, a UC_HOOK_CODE fires, we map the address back to slot `i`, run the native
//! handler (which reads args from R0-R3/stack and writes the result to R0), and the
//! `BX LR` then returns to the caller.
const std = @import("std");
const unicorn = @import("cpu/unicorn.zig");
const Vm = @import("vm.zig").Vm;

const bxlr = [2]u8{ 0x70, 0x47 }; // thumb: BX LR
const idle_bin = [2]u8{ 0xfe, 0xe7 }; // thumb: b . (infinite idle)

pub const NativeFn = *const fn (*Vm) void;

const Entry = struct {
    name: []const u8,
    handler: ?NativeFn, // null => unimplemented stub (auto-added, returns 0)
    owned: bool, // name was duped and must be freed
    logged: bool = false, // stub call already reported once
    placeholder: bool = false, // registered but a no-op/constant-return stub
    calls: u32 = 0, // how many times invoked this run
};

pub const Bridge = struct {
    gpa: std.mem.Allocator,
    stub_base: u32 = 0, // EMU offset of slot 0
    idle_p: u32 = 0, // EMU idle addr, Thumb-tagged
    entries: []Entry,
    count: usize = 0,
    log_calls: bool = true,
    log_all: bool = false,

    pub const capacity: u32 = 1024;

    pub fn init(gpa: std.mem.Allocator, vm: *Vm) !Bridge {
        const page = vm.mem.sharedMalloc(capacity * 2 + 2, false, 2);
        if (page == 0) return error.AllocFailed;

        // Fill every slot with BX LR; trailing idle loop after the last slot.
        var i: u32 = 0;
        while (i < capacity) : (i += 1) {
            vm.mem.buf[page + i * 2] = bxlr[0];
            vm.mem.buf[page + i * 2 + 1] = bxlr[1];
        }
        vm.mem.buf[page + capacity * 2] = idle_bin[0];
        vm.mem.buf[page + capacity * 2 + 1] = idle_bin[1];

        return .{
            .gpa = gpa,
            .stub_base = page,
            .idle_p = (page + capacity * 2) | 1,
            .entries = try gpa.alloc(Entry, capacity),
            .log_all = std.posix.getenv("LOG_NATIVES") != null,
        };
    }

    pub fn deinit(self: *Bridge) void {
        for (self.entries[0..self.count]) |e| if (e.owned) self.gpa.free(e.name);
        self.gpa.free(self.entries);
    }

    /// Register a real native by static name. Returns its slot index.
    pub fn register(self: *Bridge, name: []const u8, handler: NativeFn) usize {
        const idx = self.count;
        self.entries[idx] = .{ .name = name, .handler = handler, .owned = false };
        self.count += 1;
        return idx;
    }

    /// Register a placeholder (no-op / constant-return) native — counts as "stubbed"
    /// for the run report even though it has a handler.
    pub fn registerStub(self: *Bridge, name: []const u8, handler: NativeFn) usize {
        const idx = self.register(name, handler);
        self.entries[idx].placeholder = true;
        return idx;
    }

    /// Resolve a symbol name to a Thumb-tagged stub address, allocating a new
    /// (stubbed) slot on first sight. Mirrors `vm_get_sym_entry`.
    pub fn getSymEntry(self: *Bridge, name: []const u8) u32 {
        for (self.entries[0..self.count], 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return self.slotAddr(i);
        }
        if (self.count >= capacity) {
            std.debug.print("[bridge] symbol table full, dropping '{s}'\n", .{name});
            return 0;
        }
        const dup = self.gpa.dupe(u8, name) catch return 0;
        const idx = self.count;
        self.entries[idx] = .{ .name = dup, .handler = null, .owned = true };
        self.count += 1;
        std.debug.print("[bridge] vm_get_sym_entry({s}) -> 0x{x:0>8} (stub)\n", .{ name, self.slotAddr(idx) });
        return self.slotAddr(idx);
    }

    fn slotAddr(self: *Bridge, idx: usize) u32 {
        return (self.stub_base + @as(u32, @intCast(idx)) * 2) | 1;
    }

    /// EMU address of the idle loop (untagged), reached when a run returns to LR.
    pub fn idleAddr(self: *Bridge) u32 {
        return self.stub_base + capacity * 2;
    }

    /// Called from the code hook with the trapped stub address.
    pub fn dispatch(self: *Bridge, vm: *Vm, address: u64) void {
        // Reaching the idle loop means the current run_cpu has returned; stop
        // emulation explicitly (block chaining can overshoot uc_emu_start `until`).
        if (address >= self.idleAddr()) {
            vm.cpu.emuStop();
            return;
        }
        const idx: usize = @intCast((address - self.stub_base) / 2);
        if (idx >= self.count) {
            std.debug.print("[bridge] dispatch to unregistered slot {d}\n", .{idx});
            vm.setRet(0);
            return;
        }
        self.entries[idx].calls += 1;
        const e = self.entries[idx];
        if (self.log_all) std.debug.print("[native] {s}\n", .{e.name});
        if (e.handler) |h| {
            // A placeholder has a handler but only returns a constant / does nothing.
            // Log the first call so gaps surface in the logs even without the
            // end-of-run report (e.g. the libretro core, which never exits).
            if (e.placeholder and self.log_calls and !e.logged) {
                std.debug.print("[bridge] STUBBED call: {s} (placeholder/constant-return — needs a real impl)\n", .{e.name});
                self.entries[idx].logged = true;
            }
            h(vm);
        } else {
            if (self.log_calls and !e.logged) {
                std.debug.print("[bridge] UNIMPLEMENTED call: {s} (no handler, returned 0 — needs implementing)\n", .{e.name});
                self.entries[idx].logged = true;
            }
            vm.setRet(0);
        }
    }

    /// Print a per-run summary of natives the game called that are NOT fully
    /// implemented: auto-stubbed (unknown) symbols and registered placeholders.
    pub fn report(self: *Bridge) void {
        const p = std.debug.print;
        var missing: u32 = 0;
        var placeholder: u32 = 0;
        for (self.entries[0..self.count]) |e| {
            if (e.calls == 0) continue;
            if (e.handler == null) missing += 1 else if (e.placeholder) placeholder += 1;
        }
        p("\n=== native coverage (this run) ===\n", .{});
        if (missing > 0) {
            p("UNIMPLEMENTED ({d}) — no handler, returned 0:\n", .{missing});
            for (self.entries[0..self.count]) |e| {
                if (e.calls > 0 and e.handler == null) p("  {s}  (x{d})\n", .{ e.name, e.calls });
            }
        }
        if (placeholder > 0) {
            p("STUBBED ({d}) — placeholder/constant-return:\n", .{placeholder});
            for (self.entries[0..self.count]) |e| {
                if (e.calls > 0 and e.handler != null and e.placeholder) p("  {s}  (x{d})\n", .{ e.name, e.calls });
            }
        }
        if (missing == 0 and placeholder == 0) p("all called natives are implemented\n", .{});
    }
};

/// UC_HOOK_CODE callback over the stub page. `user` is the owning `*Vm`.
pub fn hookCode(uc: ?*unicorn.c.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.c) void {
    _ = uc;
    _ = size;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    vm.bridge.dispatch(vm, address);
}
