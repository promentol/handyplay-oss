//! VM orchestration: wires Memory + Cpu + Bridge, sets up the stack, and drives
//! ARM execution: CPU init, the bridged run / ADS-start entry paths, and app start.
//!
//! The Unicorn hooks capture a `*Vm`, so a Vm must never move after hooks are
//! installed — hence `create`/`destroy` heap-allocate it and pin the address.
const std = @import("std");
const Memory = @import("memory.zig").Memory;
const unicorn = @import("cpu/unicorn.zig");
const Cpu = unicorn.Cpu;
const c = unicorn.c;
const bridge_mod = @import("bridge.zig");
const Bridge = bridge_mod.Bridge;
const armapp = @import("loader/armapp.zig");
const gfx = @import("gfx.zig");
const natives = @import("natives.zig");
const resources_mod = @import("resources.zig");

const stack_size: u32 = 128 * 1024;
pub const max_files: usize = 32;
pub const max_timers: usize = 32;

pub const Timer = struct {
    active: bool = false,
    interval: u32 = 0,
    accum: u32 = 0,
    cb: u32 = 0,
};

/// A file handle that is either host-backed or served from an in-memory buffer
/// (used for the app's own .vxp, which games re-open constantly for resources —
/// memory-backing avoids thousands of slow host opens during resource loading).
pub const VFile = struct {
    file: ?std.fs.File = null,
    data: []const u8 = &.{},
    pos: u64 = 0,

    pub fn read(self: *VFile, buf: []u8) usize {
        if (self.file) |f| return f.read(buf) catch 0;
        const remaining = if (self.pos < self.data.len) self.data.len - self.pos else 0;
        const n = @min(buf.len, remaining);
        @memcpy(buf[0..n], self.data[@intCast(self.pos)..][0..n]);
        self.pos += n;
        return n;
    }
    pub fn seekTo(self: *VFile, p: u64) void {
        if (self.file) |f| {
            f.seekTo(p) catch {};
        } else self.pos = p;
    }
    pub fn seekBy(self: *VFile, off: i64) void {
        if (self.file) |f| {
            f.seekBy(off) catch {};
        } else {
            const np = @as(i64, @intCast(self.pos)) + off;
            self.pos = @intCast(@max(0, np));
        }
    }
    pub fn getPos(self: *VFile) u64 {
        if (self.file) |f| return f.getPos() catch 0;
        return self.pos;
    }
    pub fn getEndPos(self: *VFile) u64 {
        if (self.file) |f| return f.getEndPos() catch 0;
        return self.data.len;
    }
    pub fn close(self: *VFile) void {
        if (self.file) |f| f.close();
    }
};

// Key event types + codes (vmkeypad.h).
pub const VM_KEY_EVENT_UP: u32 = 1;
pub const VM_KEY_EVENT_DOWN: u32 = 2;
// Pen/touch events (vmtouch.h).
pub const VM_PEN_EVENT_TAP: u32 = 1;
pub const VM_PEN_EVENT_RELEASE: u32 = 2;
pub const VM_PEN_EVENT_MOVE: u32 = 3;
pub const Key = enum(i32) {
    up = -1,
    down = -2,
    left = -3,
    right = -4,
    ok = -5,
    left_softkey = -6,
    right_softkey = -7,
    clear = -8,
    num0 = 48,
    num1 = 49,
    num2 = 50,
    num3 = 51,
    num4 = 52,
    num5 = 53,
    num6 = 54,
    num7 = 55,
    num8 = 56,
    num9 = 57,
    star = 42,
    pound = 35,
};

// System event messages (vmpromng.h).
pub const VM_MSG_PAINT: u32 = 1;
pub const VM_MSG_ACTIVE: u32 = 2;
pub const VM_MSG_INACTIVE: u32 = 3;
pub const VM_MSG_CREATE: u32 = 4;
pub const VM_MSG_QUIT: u32 = 5;
pub const VM_MSG_HIDE: u32 = 6;

pub const Vm = struct {
    gpa: std.mem.Allocator,
    mem: *Memory,
    cpu: Cpu,
    bridge: Bridge,
    gfx: gfx.Graphics,
    resources: resources_mod.Resources,
    file: []u8 = &.{}, // owned copy of the .vxp bytes (resource data source)
    stack_emu: u32 = 0,
    app: ?armapp.LoadedApp = null,
    start_ms: i64 = 0,

    // Registered guest callbacks (EMU addresses; 0 = unset).
    cb_sysevt: u32 = 0,
    cb_keyboard: u32 = 0,
    cb_pen: u32 = 0,
    cb_msg_proc: u32 = 0,
    used_screen_buffer: bool = false,
    quit_requested: bool = false, // set by vm_exit_app; frontends should stop

    // File handle table (host-backed) + timers + RNG for the natives.
    files: [max_files]?VFile = [_]?VFile{null} ** max_files,
    timers: [max_timers]Timer = [_]Timer{.{}} ** max_timers,
    rng: u32 = 1,
    clock_ms: u32 = 0, // deterministic tick-count, advanced by tick(delta)
    scratch: u32 = 0, // 512-byte shared scratch (e.g. vm_ucs2_string result)
    trace_writes: bool = false, // debug: log guest mem writes during key handler
    watch_addr: u32 = 0, // debug: log all reads/writes of this guest address + PC

    pub fn create(gpa: std.mem.Allocator, mem: *Memory) !*Vm {
        const self = try gpa.create(Vm);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .mem = mem,
            .cpu = try Cpu.open(),
            .bridge = undefined,
            .gfx = try gfx.Graphics.init(gpa, mem),
            .resources = resources_mod.Resources.init(gpa),
            .start_ms = std.time.milliTimestamp(),
        };

        // Map the whole shared region at EMU 0.
        try self.cpu.mapPtr(0, mem.buf.len, mem.buf.ptr);

        // Stack setup: allocate, SP = top (grows down).
        self.stack_emu = mem.sharedMalloc(stack_size, true, 8);
        if (self.stack_emu == 0) return error.AllocFailed;
        self.cpu.writeReg(c.UC_ARM_REG_SP, self.stack_emu + stack_size);

        // Bridge stub page + dispatch hook (pinned `self`).
        self.scratch = mem.sharedMalloc(512, false, 8);

        self.bridge = try Bridge.init(gpa, self);
        _ = self.bridge.register("vm_get_sym_entry", natVmGetSymEntry);
        natives.registerAll(&self.bridge);

        // Hook the stub page *including* the idle loop. The hook fires on each stub
        // (native dispatch) and on the idle loop, where we uc_emu_stop explicitly —
        // relying on uc_emu_start's `until` alone is unreliable because block
        // chaining can overshoot the stop address into garbage (invalid insn).
        _ = try self.cpu.addCodeHook(
            bridge_mod.hookCode,
            self,
            self.bridge.stub_base,
            self.bridge.stub_base + Bridge.capacity * 2 + 1,
        );
        _ = try self.cpu.addMemInvalidHook(hookMemInvalid, self);

        if (std.posix.getenv("TRACE_PC") != null)
            _ = try self.cpu.addCodeHook(hookTrace, self, 0x100000, 0x200000);
        if (std.posix.getenv("TRACE_WRITES") != null)
            _ = try self.cpu.addMemWriteHook(hookMemWrite, self);
        if (std.posix.getenv("WATCH")) |w| {
            self.watch_addr = std.fmt.parseInt(u32, w, 0) catch 0;
            _ = try self.cpu.addMemWriteHook(hookWatchWrite, self);
            _ = try self.cpu.addMemReadHook(hookWatchRead, self);
        }

        return self;
    }

    pub fn destroy(self: *Vm) void {
        for (&self.files) |*f| if (f.*) |*handle| {
            handle.close();
            f.* = null;
        };
        if (self.app) |*a| a.app_memory.deinit();
        self.resources.deinit();
        if (self.file.len != 0) self.gpa.free(self.file);
        self.gfx.deinit(self.gpa);
        self.bridge.deinit();
        self.cpu.close();
        self.gpa.destroy(self);
    }

    /// Deliver a system event to the registered sysevt callback (App::run).
    pub fn deliverSysEvent(self: *Vm, message: u32, param: u32) void {
        if (self.cb_sysevt == 0) return;
        _ = self.runCpu(self.cb_sysevt, &.{ message, param });
    }

    /// Deliver a key event to the registered keyboard callback
    /// (AppManager::process_keyboard_events -> run(key_handler, event, keycode)).
    pub fn deliverKey(self: *Vm, event: u32, keycode: i32) void {
        if (self.cb_keyboard == 0) return;
        const dbg = std.posix.getenv("LOG_FILES") != null;
        if (dbg) std.debug.print("[key] >>> handler event={d} code={d}\n", .{ event, keycode });
        self.trace_writes = true;
        _ = self.runCpu(self.cb_keyboard, &.{ event, @bitCast(keycode) });
        self.trace_writes = false;
        if (dbg) std.debug.print("[key] <<< handler done\n", .{});
    }

    /// Convenience: press (down) then release (up) a key.
    pub fn pressKey(self: *Vm, key: Key) void {
        self.deliverKey(VM_KEY_EVENT_DOWN, @intFromEnum(key));
        self.deliverKey(VM_KEY_EVENT_UP, @intFromEnum(key));
    }

    /// Deliver a pen/touch event to the registered pen callback
    /// (vm_pen_handler_t = void(event, x, y); events TAP=1/RELEASE=2/MOVE=3).
    pub fn deliverPen(self: *Vm, event: u32, x: i32, y: i32) void {
        if (self.cb_pen == 0) return;
        _ = self.runCpu(self.cb_pen, &.{ event, @bitCast(x), @bitCast(y) });
    }

    /// Advance timers; fire each elapsed timer's callback with its id (Timer::update).
    pub fn tick(self: *Vm, delta_ms: u32) void {
        self.clock_ms +%= delta_ms;
        for (&self.timers, 0..) |*t, id| {
            if (!t.active) continue;
            t.accum += delta_ms;
            if (t.accum >= t.interval) {
                t.accum = 0;
                if (t.cb != 0) {
                    if (std.posix.getenv("LOG_FILES") != null)
                        std.debug.print("[timer] fire handle={d} cb=0x{x:0>8}\n", .{ id + 1, t.cb });
                    // Pass the 1-based handle the callback was told at create time.
                    _ = self.runCpu(t.cb, &.{@intCast(id + 1)});
                }
            }
        }
    }

    /// Read a guest UCS2-LE path into `out` as UTF-8-ish bytes (ASCII low bytes),
    /// returning the slice. Non-ASCII chars are dropped to their low byte.
    pub fn readUcs2(self: *Vm, emu: u32, out: []u8) []const u8 {
        if (emu == 0) return out[0..0];
        var n: usize = 0;
        var p = emu;
        while (n < out.len - 1) {
            const ch = self.mem.readU16(p);
            if (ch == 0) break;
            out[n] = @intCast(ch & 0xFF);
            n += 1;
            p += 2;
        }
        out[n] = 0;
        return out[0..n];
    }

    // --- ARM ABI helpers (read_arg / write_ret / stack) ----------------------

    pub fn arg(self: *Vm, ind: u32) u32 {
        if (ind < 4) return self.cpu.readReg(c.UC_ARM_REG_R0 + @as(c_int, @intCast(ind)));
        const sp = self.cpu.readReg(c.UC_ARM_REG_SP);
        return self.mem.readU32(sp + 4 * (ind - 4));
    }

    pub fn setRet(self: *Vm, val: u32) void {
        self.cpu.writeReg(c.UC_ARM_REG_R0, val);
    }

    fn pushWord(self: *Vm, val: u32) void {
        const sp = self.cpu.readReg(c.UC_ARM_REG_SP) - 4;
        self.cpu.writeReg(c.UC_ARM_REG_SP, sp);
        self.mem.writeU32(sp, val);
    }

    /// Null-terminated guest string -> host slice into the shared buffer.
    pub fn readCStr(self: *Vm, emu: u32) []const u8 {
        if (emu == 0 or emu >= self.mem.buf.len) return "";
        const rest = self.mem.buf[emu..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return rest[0..end];
    }

    // --- execution -----------------------------------------------------------

    pub fn runCpu(self: *Vm, adr: u32, args: []const u32) u32 {
        std.debug.assert(args.len <= 4);
        for (args, 0..) |a, i| self.cpu.writeReg(c.UC_ARM_REG_R0 + @as(c_int, @intCast(i)), a);
        self.cpu.writeReg(c.UC_ARM_REG_LR, self.bridge.idle_p);

        // Set CPSR.T (Thumb) from the target address bit 0; uc_emu_start does not
        // reset it, so a stale T-bit from a prior Thumb return (e.g. the idle loop)
        // would otherwise run an ARM callback as Thumb -> invalid instruction.
        var cpsr = self.cpu.readReg(c.UC_ARM_REG_CPSR);
        if (adr & 1 != 0) cpsr |= (1 << 5) else cpsr &= ~@as(u32, 1 << 5);
        self.cpu.writeReg(c.UC_ARM_REG_CPSR, cpsr);

        const err = self.cpu.emuStart(adr, self.bridge.idle_p & ~@as(u32, 1), 0, 0);
        if (err != c.UC_ERR_OK) {
            std.debug.print("[vm] uc_emu_start @0x{x:0>8} -> {d} ({s})\n", .{ adr, err, Cpu.strerror(err) });
            self.dumpRegs();
        }
        return self.cpu.readReg(c.UC_ARM_REG_R0);
    }

    /// ADS bootstrap. `data_base` = offset_mem + mem_size + 0x100.
    pub fn adsStart(self: *Vm, entry: u32, vm_get_sym_entry_p: u32, data_base: u32) u32 {
        var base_it = data_base - 0x80;
        self.cpu.writeReg(c.UC_ARM_REG_R9, data_base);

        self.pushWord(self.bridge.idle_p);
        self.pushWord(0);

        const words = [_]u32{
            self.cpu.readReg(c.UC_ARM_REG_SP),
            vm_get_sym_entry_p,
            data_base + 1024,
            data_base + 1024 + 2 * 1024,
            3 * 1024,
        };
        for (words) |w| {
            self.mem.writeU32(base_it, w);
            base_it += 4;
        }
        return self.runCpu(entry, &.{});
    }

    pub fn loadAndStart(self: *Vm, file: []const u8) !void {
        self.file = try self.gpa.dupe(u8, file);
        self.app = try armapp.load(self.gpa, self.mem, file);
        const app = self.app.?;
        if (app.res_size != 0)
            self.resources.scan(self.file, app.res_offset, app.res_size) catch {};
        const sym_p = self.bridge.getSymEntry("vm_get_sym_entry");
        if (app.is_ads) {
            _ = self.adsStart(app.entry_point, sym_p, app.offset_mem + app.mem_size + 0x100);
        } else {
            _ = self.runCpu(app.entry_point, &.{ sym_p, 0, 0 });
        }

        // Boot sequence: the app registered its sysevt callback during start; now
        // deliver CREATE then PAINT (matching AppManager::launch_apps). The SDL
        // frontend additionally drives ACTIVE + continuous ticks.
        self.deliverSysEvent(VM_MSG_CREATE, 0);
        self.deliverSysEvent(VM_MSG_PAINT, 0);
    }

    fn dumpRegs(self: *Vm) void {
        const names = [_]struct { n: []const u8, r: c_int }{
            .{ .n = "R0", .r = c.UC_ARM_REG_R0 },   .{ .n = "R1", .r = c.UC_ARM_REG_R1 },
            .{ .n = "R2", .r = c.UC_ARM_REG_R2 },    .{ .n = "R3", .r = c.UC_ARM_REG_R3 },
            .{ .n = "R9", .r = c.UC_ARM_REG_R9 },    .{ .n = "SP", .r = c.UC_ARM_REG_SP },
            .{ .n = "LR", .r = c.UC_ARM_REG_LR },    .{ .n = "PC", .r = c.UC_ARM_REG_PC },
            .{ .n = "CPSR", .r = c.UC_ARM_REG_CPSR },
        };
        for (names) |x| std.debug.print("  {s}=0x{x:0>8}\n", .{ x.n, self.cpu.readReg(x.r) });
    }
};

// --- native handlers --------------------------------------------------------

fn natVmGetSymEntry(vm: *Vm) void {
    const name = vm.readCStr(vm.arg(0));
    vm.setRet(vm.bridge.getSymEntry(name));
}

// --- diagnostics hook -------------------------------------------------------

fn hookTrace(uc: ?*c.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.c) void {
    _ = uc;
    _ = user;
    if (std.posix.getenv("TRACE_PC") != null)
        std.debug.print("PC 0x{x:0>8} (sz {d})\n", .{ address, size });
}

fn hookMemWrite(uc: ?*c.uc_engine, kind: c.uc_mem_type, address: u64, size: c_int, value: i64, user: ?*anyopaque) callconv(.c) void {
    _ = uc;
    _ = kind;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    if (!vm.trace_writes) return;
    // Skip stack writes (noise) — only log data-region writes the handler makes.
    if (address >= vm.stack_emu and address < vm.stack_emu + stack_size) return;
    std.debug.print("[write] @0x{x:0>8} sz={d} val=0x{x}\n", .{ address, size, @as(u64, @bitCast(value)) & 0xFFFFFFFF });
}

fn hookWatchWrite(uc: ?*c.uc_engine, kind: c.uc_mem_type, address: u64, size: c_int, value: i64, user: ?*anyopaque) callconv(.c) void {
    _ = kind;
    _ = size;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    if (vm.watch_addr == 0 or address != vm.watch_addr) return;
    var pc: u32 = 0;
    _ = c.uc_reg_read(uc, c.UC_ARM_REG_PC, &pc);
    std.debug.print("[watch] WRITE 0x{x} = 0x{x} (pc=0x{x})\n", .{ address, @as(u64, @bitCast(value)) & 0xFFFFFFFF, pc });
}
fn hookWatchRead(uc: ?*c.uc_engine, kind: c.uc_mem_type, address: u64, size: c_int, value: i64, user: ?*anyopaque) callconv(.c) void {
    _ = kind;
    _ = size;
    _ = value;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    if (vm.watch_addr == 0 or address != vm.watch_addr) return;
    var pc: u32 = 0;
    _ = c.uc_reg_read(uc, c.UC_ARM_REG_PC, &pc);
    std.debug.print("[watch] READ  0x{x} (pc=0x{x})\n", .{ address, pc });
}

fn hookMemInvalid(
    uc: ?*c.uc_engine,
    kind: c.uc_mem_type,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.c) bool {
    _ = uc;
    _ = value;
    _ = user;
    std.debug.print("[vm] unmapped access kind={d} @0x{x:0>8} size={d}\n", .{ kind, address, size });
    return false; // let Unicorn raise the error; run_cpu reports it
}
