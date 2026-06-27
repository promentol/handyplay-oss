//! The VM: Unicorn ARM core + flat guest memory + the ARM<->native bridge.
//!
//! Owns the guest memory map and boot sequence, plus the two pointer-table
//! trampolines, dispatch, runCode, the lifecycle, and every native handler.
//!
//! Trampoline model: a pointer table is allocated in guest memory; each function
//! slot has its *own address* written into it, and a UC_HOOK_CODE is registered
//! over the table's address range. When the dsm engine loads a function pointer
//! from the table and branches to it, PC lands inside the range, the hook fires,
//! we dispatch to the matching native (args in R0-R3 / stack, result in R0), then
//! set PC = LR to return.
const std = @import("std");
const unicorn = @import("cpu/unicorn.zig");
const c = unicorn.c;
const mem = @import("memory.zig");
const gfxmod = @import("gfx.zig");
const fsmod = @import("fs.zig");
const netmod = @import("net.zig");

const Memory = mem.Memory;
const Cpu = unicorn.Cpu;

const log = std.log.scoped(.mrp);

pub const DSM_VERSION: i32 = 20210701;
pub const MR_SUCCESS: i32 = 0;
pub const MR_FAILED: i32 = -1;

// dsm.h event codes (passed as the inner event_t.code).
const DSM_INIT: i32 = -100;
const MR_START_DSM: i32 = -99;
const MR_PAUSEAPP: i32 = -98;
const MR_RESUMEAPP: i32 = -97;
const MR_TIMER: i32 = -96;
const MR_EVENT: i32 = -95;

const FLAG_USE_UTF8_FS: i32 = 1 << 0;

// DSM_REQUIRE_FUNCS: 51 function pointers (0x00..0xC8) then `flags` at 0xCC.
const DSM_FUNCS_FLAGS_OFF: u32 = 0xCC;
const DSM_FUNCS_SIZE: u32 = 0xD0;

// --- bridge table description ----------------------------------------------
const MapType = enum { data, func };
const NativeFn = *const fn (*Vm) void;
const InitFn = *const fn (*Vm, u32) void;

const Entry = struct {
    pos: u32,
    mtype: MapType,
    name: []const u8,
    func: ?NativeFn = null,
    init: ?InitFn = null,
};

inline fn F(pos: u32, name: []const u8, func: ?NativeFn) Entry {
    return .{ .pos = pos, .mtype = .func, .name = name, .func = func };
}
inline fn FI(pos: u32, name: []const u8, func: NativeFn, init: InitFn) Entry {
    return .{ .pos = pos, .mtype = .func, .name = name, .func = func, .init = init };
}
inline fn D(pos: u32, name: []const u8) Entry {
    return .{ .pos = pos, .mtype = .data, .name = name };
}

/// Host integration points the frontend can override (timer scheduling, the
/// interactive edit box). Defaults make the headless runner self-contained.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    timerStart: ?*const fn (ctx: ?*anyopaque, ms: u16) void = null,
    timerStop: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    mem: Memory,
    cpu: Cpu,
    gfx: gfxmod.Gfx = .{},
    fs: fsmod.FileSystem,
    net: netmod.Net,
    host: Host = .{},

    // bridge runtime state
    dispatch: std.AutoHashMapUnmanaged(u32, *const Entry) = .{},
    unimpl: std.StringHashMapUnmanaged(u32) = .{},
    mr_table_addr: u32 = 0,
    dsm_funcs_addr: u32 = 0,
    mr_extHelper_addr: u32 = 0,
    mr_c_function_P: u32 = 0,
    mr_c_event: u32 = 0,
    dsm_event: u32 = 0,
    mr_start_dsm_param: u32 = 0,
    readdir_shared: u32 = 0,
    edit_text_addr: u32 = 0,

    uptime_base: i64 = 0,
    /// Deterministic ms clock (advanced by the frontend each frame via
    /// `advanceClock`). Source for `mr_getUptime` instead of wall-clock, so
    /// replay / save-states are reproducible. Captured in the save-state.
    clock_ms: u64 = 0,
    rng: u32 = 0x12345678,
    quit_requested: bool = false,
    halted: bool = false,

    pub fn create(gpa: std.mem.Allocator) !*Vm {
        const self = try gpa.create(Vm);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .mem = try Memory.init(gpa),
            .cpu = try Cpu.open(),
            .fs = fsmod.FileSystem.init(gpa),
            .net = netmod.Net.init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Vm) void {
        self.dispatch.deinit(self.gpa);
        self.unimpl.deinit(self.gpa);
        self.net.deinit();
        self.fs.deinit();
        self.cpu.close();
        self.mem.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // --- register / memory helpers ----------------------------------------
    inline fn reg(self: *Vm, r: c_int) u32 {
        return self.cpu.readReg(r);
    }
    inline fn setReg(self: *Vm, r: c_int, v: u32) void {
        self.cpu.writeReg(r, v);
    }
    /// Nth ABI argument (0-based). 0..3 in R0..R3, rest on the stack.
    fn arg(self: *Vm, n: u32) u32 {
        if (n <= 3) return self.reg(c.UC_ARM_REG_R0 + @as(c_int, @intCast(n)));
        const sp = self.reg(c.UC_ARM_REG_SP);
        return self.mem.read32(sp + (n - 4) * 4);
    }
    inline fn setRet(self: *Vm, v: anytype) void {
        const u: u32 = switch (@typeInfo(@TypeOf(v))) {
            .int, .comptime_int => @bitCast(@as(i32, @intCast(v))),
            .bool => @intFromBool(v),
            else => @compileError("bad ret"),
        };
        self.setReg(c.UC_ARM_REG_R0, u);
    }
    /// Host slice of guest memory.
    inline fn hostSlice(self: *Vm, addr: u32, n: usize) []u8 {
        return self.mem.slice(addr, n);
    }
    /// Host pointer for a guest address.
    inline fn hostPtr(self: *Vm, addr: u32) [*]u8 {
        return self.mem.ptr(addr);
    }
    /// NUL-terminated guest C string as a Zig slice (no terminator).
    fn cstr(self: *Vm, addr: u32) []const u8 {
        const p = self.hostPtr(addr);
        return std.mem.sliceTo(p[0..0x10000], 0);
    }

    // --- bootstrap (init + start) -----------------------------------------
    /// Map memory, install hooks, build bridge tables, load the dsm engine,
    /// run ext_init + dsm_init, then start the given dsm package.
    pub fn start(self: *Vm, ext_path: []const u8, filename: []const u8, ext_name: []const u8) !void {
        try self.cpu.mapPtr(mem.START_ADDRESS, mem.TOTAL_MEMORY, self.mem.buf.ptr);
        self.setReg(c.UC_ARM_REG_SP, mem.STACK_ADDRESS + mem.STACK_SIZE);
        _ = try self.cpu.addMemInvalidHook(hookMemInvalid, self);
        // Code hooks are registered per table range inside hooksInit — not one
        // global hook (some Unicorn builds mishandle a single wide range).

        try self.bridgeInit();
        try self.loadCode(ext_path);
        try self.bridgeExtInit();

        const ver = self.bridgeMrEvent(DSM_INIT, self.dsm_funcs_addr, 0);
        if (ver != DSM_VERSION) {
            log.err("dsm_init version mismatch: got {d}, want {d}", .{ ver, DSM_VERSION });
            return error.DsmVersionMismatch;
        }
        log.info("dsm_init OK (ver {d})", .{ver});

        const ret = self.startDsm(filename, ext_name, null);
        log.info("start_dsm('{s}','{s}') -> 0x{x}", .{ filename, ext_name, ret });
    }

    fn loadCode(self: *Vm, path: []const u8) !void {
        const buf = try std.fs.cwd().readFileAlloc(self.gpa, path, mem.CODE_SIZE);
        defer self.gpa.free(buf);
        @memcpy(self.hostSlice(mem.CODE_ADDRESS, buf.len), buf);
        log.info("loaded {s} ({d} bytes) @ 0x{x}", .{ path, buf.len, mem.CODE_ADDRESS });
    }

    fn bridgeInit(self: *Vm) !void {
        self.uptime_base = std.time.milliTimestamp();
        self.mr_table_addr = try self.hooksInit(&mr_table, 4 * mr_table.len);
        self.dsm_funcs_addr = try self.hooksInit(&dsm_funcs, DSM_FUNCS_SIZE);
        self.mem.write32(self.dsm_funcs_addr + DSM_FUNCS_FLAGS_OFF, @bitCast(FLAG_USE_UTF8_FS));

        self.mr_c_event = self.mem.mallocExt0(12); // sizeof(event_t)
        self.dsm_event = self.mem.mallocExt0(12);
        self.mr_start_dsm_param = self.mem.mallocExt0(12); // sizeof(start_t)
    }

    /// Allocate the table, write self-pointers for func
    /// slots (or call their initFn), and index every func slot for dispatch.
    fn hooksInit(self: *Vm, table: []const Entry, size: u32) !u32 {
        const start_addr = self.mem.mallocExt0(size);
        if (start_addr == 0) return error.AllocFailed;
        _ = self.cpu.addCodeHook(hookCode, self, start_addr, start_addr + size) catch return error.HookAdd;
        for (table) |*e| {
            const addr = start_addr + e.pos;
            if (e.init) |ini| {
                ini(self, addr);
            } else if (e.mtype == .func) {
                self.mem.write32(addr, addr); // slot points at itself
            }
            if (e.mtype == .func) try self.dispatch.put(self.gpa, addr, e);
        }
        return start_addr;
    }

    // --- runCode + lifecycle ----------------------------------------------
    /// Run guest code from `start_addr`, returning when PC reaches `stop_addr`
    /// (LR is primed with stop so the top-level return lands there).
    fn runCode(self: *Vm, start_addr: u32, stop_addr: u32, thumb: bool) void {
        self.setReg(c.UC_ARM_REG_LR, stop_addr);
        const begin: u32 = if (thumb) start_addr | 1 else start_addr;
        const err = self.cpu.emuStart(begin, stop_addr, 0, 0);
        if (err != c.UC_ERR_OK and !self.halted) {
            log.err("emu_start error: {s} (pc=0x{x})", .{ Cpu.strerror(err), self.reg(c.UC_ARM_REG_PC) });
        }
    }

    fn bridgeExtInit(self: *Vm) !void {
        self.mem.write32(mem.CODE_ADDRESS, self.mr_table_addr); // CODE[0] = mr_table
        self.setReg(c.UC_ARM_REG_R0, 1); // use mr_extHelper (does screen refresh)
        self.runCode(mem.CODE_ADDRESS + 8, mem.CODE_ADDRESS, false); // mr_c_function_load
        if (self.mr_c_function_P == 0) return error.ExtInitFailed;
    }

    /// `mr_extHelper(P, code, input, input_len)` -> return value (R0).
    fn mrExtHelper(self: *Vm, code: u32, input: u32, input_len: u32) i32 {
        self.setReg(c.UC_ARM_REG_R0, self.mr_c_function_P);
        self.setReg(c.UC_ARM_REG_R1, code);
        self.setReg(c.UC_ARM_REG_R2, input);
        self.setReg(c.UC_ARM_REG_R3, input_len);
        self.runCode(self.mr_extHelper_addr, mem.CODE_ADDRESS, false);
        return @bitCast(self.reg(c.UC_ARM_REG_R0));
    }

    /// `mr_event(code, p0, p1)`: fill mr_c_event and invoke extHelper command 1.
    fn bridgeMrEvent(self: *Vm, code: i32, p0: u32, p1: u32) i32 {
        self.mem.write32(self.mr_c_event + 0, @bitCast(code));
        self.mem.write32(self.mr_c_event + 4, p0);
        self.mem.write32(self.mr_c_event + 8, p1);
        return self.mrExtHelper(1, self.mr_c_event, 12);
    }

    fn startDsm(self: *Vm, filename: []const u8, ext_name: []const u8, entry: ?[]const u8) i32 {
        const fn_addr = self.mem.copyStrToGuest(filename);
        const ext_addr = self.mem.copyStrToGuest(ext_name);
        const entry_addr = if (entry) |e| self.mem.copyStrToGuest(e) else 0;
        self.mem.write32(self.mr_start_dsm_param + 0, fn_addr);
        self.mem.write32(self.mr_start_dsm_param + 4, ext_addr);
        self.mem.write32(self.mr_start_dsm_param + 8, entry_addr);
        const v = self.bridgeMrEvent(MR_START_DSM, self.mr_start_dsm_param, 0);
        self.mem.freeExt(fn_addr);
        self.mem.freeExt(ext_addr);
        if (entry_addr != 0) self.mem.freeExt(entry_addr);
        return v;
    }

    /// Deliver a periodic timer tick (MR_TIMER) — called by the frontend after the
    /// interval requested via timerStart elapses.
    pub fn timer(self: *Vm) i32 {
        if (self.halted) return MR_FAILED;
        return self.bridgeMrEvent(MR_TIMER, 0, 0);
    }

    /// Deliver an input/system event (MR_EVENT wrapping dsm_event{code,p0,p1}).
    pub fn event(self: *Vm, code: i32, p0: i32, p1: i32) i32 {
        if (self.halted) return MR_FAILED;
        self.mem.write32(self.dsm_event + 0, @bitCast(code));
        self.mem.write32(self.dsm_event + 4, @bitCast(p0));
        self.mem.write32(self.dsm_event + 8, @bitCast(p1));
        return self.bridgeMrEvent(MR_EVENT, self.dsm_event, 0);
    }

    pub fn pauseApp(self: *Vm) i32 {
        return self.bridgeMrEvent(MR_PAUSEAPP, 0, 0);
    }
    pub fn resumeApp(self: *Vm) i32 {
        return self.bridgeMrEvent(MR_RESUMEAPP, 0, 0);
    }

    // --- dispatch ----------------------------------------------------------
    fn dispatchAt(self: *Vm, address: u64) void {
        const addr: u32 = @intCast(address);
        const e = self.dispatch.get(addr) orelse return; // not a bridge slot: ordinary code
        if (e.func) |h| {
            h(self);
        } else {
            const gop = self.unimpl.getOrPut(self.gpa, e.name) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
                log.warn("unimplemented native: {s} @0x{x}", .{ e.name, addr });
            }
            gop.value_ptr.* += 1;
            self.setRet(0);
        }
        // Return from the bridged call: PC = LR.
        self.setReg(c.UC_ARM_REG_PC, self.reg(c.UC_ARM_REG_LR));
    }

    pub fn report(self: *Vm) void {
        if (self.unimpl.count() == 0) {
            log.info("all called natives implemented", .{});
            return;
        }
        log.info("unimplemented natives called this run:", .{});
        var it = self.unimpl.iterator();
        while (it.next()) |kv| log.info("  {s} (x{d})", .{ kv.key_ptr.*, kv.value_ptr.* });
    }
};

// ===========================================================================
// UC hook callbacks
// ===========================================================================
fn hookCode(uc: ?*c.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.c) void {
    _ = uc;
    _ = size;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    vm.dispatchAt(address);
}

fn hookMemInvalid(uc: ?*c.uc_engine, mtype: c.uc_mem_type, address: u64, size: c_int, value: i64, user: ?*anyopaque) callconv(.c) bool {
    _ = uc;
    _ = value;
    const vm: *Vm = @ptrCast(@alignCast(user.?));
    log.err("mem_invalid type={d} addr=0x{x} size={d} pc=0x{x}", .{ @as(u32, @intCast(mtype)), address, size, vm.reg(c.UC_ARM_REG_PC) });
    vm.halted = true;
    vm.cpu.emuStop();
    return false; // abort the access
}

// ===========================================================================
// Native handlers. Args read from R0-R3/stack, result -> R0.
// ===========================================================================

fn brMrMalloc(vm: *Vm) void {
    const len = vm.arg(0);
    vm.setRet(@as(i32, @bitCast(vm.mem.mallocExt(len))));
}
fn brMrFree(vm: *Vm) void {
    const p = vm.arg(0);
    vm.mem.freeExt(p);
}
fn brMemcpy(vm: *Vm) void {
    const dst = vm.arg(0);
    const src = vm.arg(1);
    const n = vm.arg(2);
    std.mem.copyForwards(u8, vm.hostSlice(dst, n), vm.hostSlice(src, n));
    vm.setRet(@as(i32, @bitCast(dst)));
}
fn brMemset(vm: *Vm) void {
    const dst = vm.arg(0);
    const val: u8 = @truncate(vm.arg(1));
    const n = vm.arg(2);
    @memset(vm.hostSlice(dst, n), val);
    vm.setRet(@as(i32, @bitCast(dst)));
}

/// _mr_c_function_new(f, len): record the ext helper entry and allocate the
/// mr_c_function_P descriptor, storing its address at CODE[4].
fn brCFunctionNew(vm: *Vm) void {
    const f = vm.arg(0);
    const len = vm.arg(1);
    vm.mr_extHelper_addr = f;
    vm.mr_c_function_P = vm.mem.mallocExt0(len);
    vm.mem.write32(mem.CODE_ADDRESS + 4, vm.mr_c_function_P);
    vm.setRet(MR_SUCCESS);
}

// --- platform funcs (dsm_require_funcs) ------------------------------------
fn brTest(_: *Vm) void {}

fn brLog(vm: *Vm) void {
    const s = vm.cstr(vm.arg(0));
    std.debug.print("{s}\n", .{s});
}

fn brExit(vm: *Vm) void {
    log.info("mythroad exit.", .{});
    vm.quit_requested = true;
    vm.halted = true;
    vm.cpu.emuStop();
}

fn brSrand(vm: *Vm) void {
    vm.rng = vm.arg(0);
}
fn brRand(vm: *Vm) void {
    // xorshift32 — deterministic, seedable (replaces libc rand()).
    var x = vm.rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    vm.rng = x;
    vm.setRet(@as(i32, @bitCast(x & 0x7fffffff)));
}

fn brMemGet(vm: *Vm) void {
    const mem_base = vm.arg(0);
    const mem_len = vm.arg(1);
    const len: u32 = 1024 * 1024 * 4;
    const buffer = vm.mem.mallocExt(len);
    vm.mem.write32(mem_base, buffer);
    vm.mem.write32(mem_len, len);
    vm.setRet(MR_SUCCESS);
}
fn brMemFree(vm: *Vm) void {
    vm.mem.freeExt(vm.arg(0));
    vm.setRet(MR_SUCCESS);
}

fn brTimerStart(vm: *Vm) void {
    const t: u16 = @truncate(vm.arg(0));
    if (vm.host.timerStart) |cb| cb(vm.host.ctx, t);
    vm.setRet(MR_SUCCESS);
}
fn brTimerStop(vm: *Vm) void {
    if (vm.host.timerStop) |cb| cb(vm.host.ctx);
    vm.setRet(MR_SUCCESS);
}

fn brGetUptimeInit(vm: *Vm, addr: u32) void {
    vm.mem.write32(addr, addr); // also a normal func slot
}
fn brGetUptime(vm: *Vm) void {
    // Deterministic clock (advanced per frame by the frontend), not wall-clock.
    vm.setRet(@as(i32, @intCast(vm.clock_ms & 0x7FFF_FFFF)));
}

fn brGetDatetime(vm: *Vm) void {
    const addr = vm.arg(0);
    const secs: u64 = @intCast(std.time.timestamp());
    const eday = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = eday.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = eday.getDaySeconds();
    // mr_datetime: u16 year, u8 month, day, hour, minute, second (packed).
    std.mem.writeInt(u16, vm.hostSlice(addr, 2)[0..2], yd.year, .little);
    const b = vm.hostSlice(addr + 2, 5);
    b[0] = md.month.numeric();
    b[1] = md.day_index + 1;
    b[2] = ds.getHoursIntoDay();
    b[3] = ds.getMinutesIntoHour();
    b[4] = ds.getSecondsIntoMinute();
    vm.setRet(MR_SUCCESS);
}

fn brSleep(vm: *Vm) void {
    const ms = vm.arg(0);
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    vm.setRet(MR_SUCCESS);
}

// --- file I/O --------------------------------------------------------------
fn brOpen(vm: *Vm) void {
    const name = vm.cstr(vm.arg(0));
    const mode = vm.arg(1);
    vm.setRet(vm.fs.open(name, mode));
}
fn brClose(vm: *Vm) void {
    vm.setRet(vm.fs.close(@bitCast(vm.arg(0))));
}
fn brRead(vm: *Vm) void {
    const f: i32 = @bitCast(vm.arg(0));
    const p = vm.arg(1);
    const l = vm.arg(2);
    vm.setRet(vm.fs.read(f, vm.hostSlice(p, l)));
}
fn brWrite(vm: *Vm) void {
    const f: i32 = @bitCast(vm.arg(0));
    const p = vm.arg(1);
    const l = vm.arg(2);
    vm.setRet(vm.fs.write(f, vm.hostSlice(p, l)));
}
fn brSeek(vm: *Vm) void {
    const f: i32 = @bitCast(vm.arg(0));
    const pos: i32 = @bitCast(vm.arg(1));
    const method = vm.arg(2);
    vm.setRet(vm.fs.seek(f, pos, method));
}
fn brInfo(vm: *Vm) void {
    vm.setRet(vm.fs.info(vm.cstr(vm.arg(0))));
}
fn brRemove(vm: *Vm) void {
    vm.setRet(vm.fs.remove(vm.cstr(vm.arg(0))));
}
fn brRename(vm: *Vm) void {
    const a = vm.cstr(vm.arg(0));
    const b = vm.cstr(vm.arg(1));
    vm.setRet(vm.fs.rename(a, b));
}
fn brMkDir(vm: *Vm) void {
    vm.setRet(vm.fs.mkDir(vm.cstr(vm.arg(0))));
}
fn brRmDir(vm: *Vm) void {
    vm.setRet(vm.fs.rmDir(vm.cstr(vm.arg(0))));
}
fn brGetLen(vm: *Vm) void {
    vm.setRet(vm.fs.getLen(vm.cstr(vm.arg(0))));
}
fn brOpendir(vm: *Vm) void {
    vm.setRet(vm.fs.opendir(vm.cstr(vm.arg(0))));
}
fn brReaddirInit(vm: *Vm, addr: u32) void {
    vm.readdir_shared = vm.mem.mallocExt0(128);
    vm.mem.write32(addr, addr);
}
fn brReaddir(vm: *Vm) void {
    const f: i32 = @bitCast(vm.arg(0));
    if (vm.fs.readdir(f)) |name| {
        const n = @min(name.len, 127);
        @memcpy(vm.hostSlice(vm.readdir_shared, n), name[0..n]);
        vm.hostSlice(vm.readdir_shared + n, 1)[0] = 0;
        vm.setRet(@as(i32, @bitCast(vm.readdir_shared)));
    } else {
        vm.setRet(0);
    }
}
fn brClosedir(vm: *Vm) void {
    vm.setRet(vm.fs.closedir(@bitCast(vm.arg(0))));
}

// --- graphics --------------------------------------------------------------
fn brDrawBitmap(vm: *Vm) void {
    const bmp = vm.arg(0);
    const x: i32 = @bitCast(vm.arg(1));
    const y: i32 = @bitCast(vm.arg(2));
    const w: i32 = @bitCast(vm.arg(3));
    const h: i32 = @bitCast(vm.arg(4)); // 5th arg on the stack (SP+0)
    const npix = gfxmod.screen_w * gfxmod.screen_h;
    const bytes = vm.hostSlice(bmp, npix * 2);
    const pix: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, bytes));
    vm.gfx.drawBitmap(pix, x, y, w, h);
}

// --- network (net.zig) -----------------------------------------------------
fn brInitNetwork(vm: *Vm) void {
    vm.setRet(vm.net.initNetwork());
}
fn brCloseNetwork(vm: *Vm) void {
    vm.setRet(vm.net.closeNetwork());
}
fn brSocket(vm: *Vm) void {
    vm.setRet(vm.net.socket(@bitCast(vm.arg(0)), @bitCast(vm.arg(1))));
}
fn brConnect(vm: *Vm) void {
    vm.setRet(vm.net.connect(@bitCast(vm.arg(0)), vm.arg(1), @truncate(vm.arg(2)), @bitCast(vm.arg(3))));
}
fn brGetSocketState(vm: *Vm) void {
    vm.setRet(vm.net.getSocketState(@bitCast(vm.arg(0))));
}
fn brCloseSocket(vm: *Vm) void {
    vm.setRet(vm.net.closeSocket(@bitCast(vm.arg(0))));
}
fn brSend(vm: *Vm) void {
    const s: i32 = @bitCast(vm.arg(0));
    const buf = vm.arg(1);
    const len = vm.arg(2);
    vm.setRet(vm.net.send(s, vm.hostSlice(buf, len)));
}
fn brRecv(vm: *Vm) void {
    const s: i32 = @bitCast(vm.arg(0));
    const buf = vm.arg(1);
    const len = vm.arg(2);
    vm.setRet(vm.net.recv(s, vm.hostSlice(buf, len)));
}
fn brSendto(vm: *Vm) void {
    const s: i32 = @bitCast(vm.arg(0));
    const buf = vm.arg(1);
    const len = vm.arg(2);
    const ip = vm.arg(3);
    const port: u16 = @truncate(vm.arg(4));
    vm.setRet(vm.net.sendto(s, vm.hostSlice(buf, len), ip, port));
}
fn brRecvfrom(vm: *Vm) void {
    const s: i32 = @bitCast(vm.arg(0));
    const buf = vm.arg(1);
    const len = vm.arg(2);
    const ip_addr = vm.arg(3);
    const port_addr = vm.arg(4);
    var ip: u32 = 0;
    var port: u16 = 0;
    const r = vm.net.recvfrom(s, vm.hostSlice(buf, len), &ip, &port);
    if (r >= 0) {
        vm.mem.write32(ip_addr, ip);
        std.mem.writeInt(u16, vm.hostSlice(port_addr, 2)[0..2], port, .little);
    }
    vm.setRet(r);
}
fn brGetHostByName(vm: *Vm) void {
    // (name, cb, userData) — we resolve synchronously and ignore the callback.
    vm.setRet(vm.net.getHostByName(vm.cstr(vm.arg(0))));
}

// --- sound / shake (no-op success natively; the player frontend wires audio) --
fn brPlaySound(vm: *Vm) void {
    vm.setRet(MR_SUCCESS);
}
fn brStopSound(vm: *Vm) void {
    vm.setRet(MR_SUCCESS);
}
fn brStartShake(vm: *Vm) void {
    vm.setRet(MR_SUCCESS);
}
fn brStopShake(vm: *Vm) void {
    vm.setRet(MR_SUCCESS);
}

// --- dialog / text / edit (native: MR_FAILED; UI is wired by the frontend) --
fn brDialogCreate(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brDialogRelease(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brDialogRefresh(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brTextCreate(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brTextRelease(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brTextRefresh(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brEditCreate(vm: *Vm) void {
    vm.setRet(MR_FAILED);
}
fn brEditRelease(vm: *Vm) void {
    vm.setRet(MR_SUCCESS);
}
fn brEditGetText(vm: *Vm) void {
    vm.setRet(0); // NULL
}

// ===========================================================================
// Bridge tables (mr_table + dsm_require_funcs). Offsets are sequential ×4, laid
// out so the dsm engine's pointer-table reads land on the right native.
// ===========================================================================
const mr_table = [_]Entry{
    F(0x0, "mr_malloc", brMrMalloc),
    F(0x4, "mr_free", brMrFree),
    F(0x8, "mr_realloc", null),
    F(0xC, "memcpy", brMemcpy),
    F(0x10, "memmove", null),
    F(0x14, "strcpy", null),
    F(0x18, "strncpy", null),
    F(0x1C, "strcat", null),
    F(0x20, "strncat", null),
    F(0x24, "memcmp", null),
    F(0x28, "strcmp", null),
    F(0x2C, "strncmp", null),
    F(0x30, "strcoll", null),
    F(0x34, "memchr", null),
    F(0x38, "memset", brMemset),
    F(0x3C, "strlen", null),
    F(0x40, "strstr", null),
    F(0x44, "sprintf", null),
    F(0x48, "atoi", null),
    F(0x4C, "strtoul", null),
    F(0x50, "rand", null),
    D(0x54, "reserve0"),
    D(0x58, "reserve1"),
    D(0x5C, "_mr_c_internal_table"),
    D(0x60, "_mr_c_port_table"),
    F(0x64, "_mr_c_function_new", brCFunctionNew),
    F(0x68, "mr_printf", null),
    F(0x6C, "mr_mem_get", null),
    F(0x70, "mr_mem_free", null),
    F(0x74, "mr_drawBitmap", null),
    F(0x78, "mr_getCharBitmap", null),
    F(0x7C, "mr_timerStart", null),
    F(0x80, "mr_timerStop", null),
    F(0x84, "mr_getTime", null),
    F(0x88, "mr_getDatetime", null),
    F(0x8C, "mr_getUserInfo", null),
    F(0x90, "mr_sleep", null),
    F(0x94, "mr_plat", null),
    F(0x98, "mr_platEx", null),
    F(0x9C, "mr_ferrno", null),
    F(0xA0, "mr_open", null),
    F(0xA4, "mr_close", null),
    F(0xA8, "mr_info", null),
    F(0xAC, "mr_write", null),
    F(0xB0, "mr_read", null),
    F(0xB4, "mr_seek", null),
    F(0xB8, "mr_getLen", null),
    F(0xBC, "mr_remove", null),
    F(0xC0, "mr_rename", null),
    F(0xC4, "mr_mkDir", null),
    F(0xC8, "mr_rmDir", null),
    F(0xCC, "mr_findStart", null),
    F(0xD0, "mr_findGetNext", null),
    F(0xD4, "mr_findStop", null),
    F(0xD8, "mr_exit", null),
    F(0xDC, "mr_startShake", null),
    F(0xE0, "mr_stopShake", null),
    F(0xE4, "mr_playSound", null),
    F(0xE8, "mr_stopSound", null),
    F(0xEC, "mr_sendSms", null),
    F(0xF0, "mr_call", null),
    F(0xF4, "mr_getNetworkID", null),
    F(0xF8, "mr_connectWAP", null),
    F(0xFC, "mr_menuCreate", null),
    F(0x100, "mr_menuSetItem", null),
    F(0x104, "mr_menuShow", null),
    D(0x108, "reserve"),
    F(0x10C, "mr_menuRelease", null),
    F(0x110, "mr_menuRefresh", null),
    F(0x114, "mr_dialogCreate", null),
    F(0x118, "mr_dialogRelease", null),
    F(0x11C, "mr_dialogRefresh", null),
    F(0x120, "mr_textCreate", null),
    F(0x124, "mr_textRelease", null),
    F(0x128, "mr_textRefresh", null),
    F(0x12C, "mr_editCreate", null),
    F(0x130, "mr_editRelease", null),
    F(0x134, "mr_editGetText", null),
    F(0x138, "mr_winCreate", null),
    F(0x13C, "mr_winRelease", null),
    F(0x140, "mr_getScreenInfo", null),
    F(0x144, "mr_initNetwork", null),
    F(0x148, "mr_closeNetwork", null),
    F(0x14C, "mr_getHostByName", null),
    F(0x150, "mr_socket", null),
    F(0x154, "mr_connect", null),
    F(0x158, "mr_closeSocket", null),
    F(0x15C, "mr_recv", null),
    F(0x160, "mr_recvfrom", null),
    F(0x164, "mr_send", null),
    F(0x168, "mr_sendto", null),
    D(0x16C, "mr_screenBuf"),
    D(0x170, "mr_screen_w"),
    D(0x174, "mr_screen_h"),
    D(0x178, "mr_screen_bit"),
    D(0x17C, "mr_bitmap"),
    D(0x180, "mr_tile"),
    D(0x184, "mr_map"),
    D(0x188, "mr_sound"),
    D(0x18C, "mr_sprite"),
    D(0x190, "pack_filename"),
    D(0x194, "start_filename"),
    D(0x198, "old_pack_filename"),
    D(0x19C, "old_start_filename"),
    D(0x1A0, "mr_ram_file"),
    D(0x1A4, "mr_ram_file_len"),
    D(0x1A8, "mr_soundOn"),
    D(0x1AC, "mr_shakeOn"),
    D(0x1B0, "LG_mem_base"),
    D(0x1B4, "LG_mem_len"),
    D(0x1B8, "LG_mem_end"),
    D(0x1BC, "LG_mem_left"),
    D(0x1C0, "mr_sms_cfg_buf"),
    F(0x1C4, "mr_md5_init", null),
    F(0x1C8, "mr_md5_append", null),
    F(0x1CC, "mr_md5_finish", null),
    F(0x1D0, "_mr_load_sms_cfg", null),
    F(0x1D4, "_mr_save_sms_cfg", null),
    F(0x1D8, "_DispUpEx", null),
    F(0x1DC, "_DrawPoint", null),
    F(0x1E0, "_DrawBitmap", null),
    F(0x1E4, "_DrawBitmapEx", null),
    F(0x1E8, "DrawRect", null),
    F(0x1EC, "_DrawText", null),
    F(0x1F0, "_BitmapCheck", null),
    F(0x1F4, "_mr_readFile", null),
    F(0x1F8, "mr_wstrlen", null),
    F(0x1FC, "mr_registerAPP", null),
    F(0x200, "_DrawTextEx", null),
    F(0x204, "_mr_EffSetCon", null),
    F(0x208, "_mr_TestCom", null),
    F(0x20C, "_mr_TestCom1", null),
    F(0x210, "c2u", null),
    F(0x214, "_mr_div", null),
    F(0x218, "_mr_mod", null),
    D(0x21C, "LG_mem_min"),
    D(0x220, "LG_mem_top"),
    D(0x224, "mr_updcrc"),
    D(0x228, "start_fileparameter"),
    D(0x22C, "mr_sms_return_flag"),
    D(0x230, "mr_sms_return_val"),
    D(0x234, "mr_unzip"),
    D(0x238, "mr_exit_cb"),
    D(0x23C, "mr_exit_cb_data"),
    D(0x240, "mr_entry"),
    F(0x244, "mr_platDrawChar", null),
};

const dsm_funcs = [_]Entry{
    F(0x0, "test", brTest),
    F(0x4, "log", brLog),
    F(0x8, "exit", brExit),
    F(0xC, "srand", brSrand),
    F(0x10, "rand", brRand),
    F(0x14, "mem_get", brMemGet),
    F(0x18, "mem_free", brMemFree),
    F(0x1C, "timerStart", brTimerStart),
    F(0x20, "timerStop", brTimerStop),
    FI(0x24, "get_uptime_ms", brGetUptime, brGetUptimeInit),
    F(0x28, "getDatetime", brGetDatetime),
    F(0x2C, "sleep", brSleep),
    F(0x30, "open", brOpen),
    F(0x34, "close", brClose),
    F(0x38, "read", brRead),
    F(0x3C, "write", brWrite),
    F(0x40, "seek", brSeek),
    F(0x44, "info", brInfo),
    F(0x48, "remove", brRemove),
    F(0x4C, "rename", brRename),
    F(0x50, "mkDir", brMkDir),
    F(0x54, "rmDir", brRmDir),
    F(0x58, "opendir", brOpendir),
    FI(0x5C, "readdir", brReaddir, brReaddirInit),
    F(0x60, "closedir", brClosedir),
    F(0x64, "getLen", brGetLen),
    F(0x68, "drawBitmap", brDrawBitmap),
    F(0x6C, "getHostByName", brGetHostByName),
    F(0x70, "initNetwork", brInitNetwork),
    F(0x74, "mr_closeNetwork", brCloseNetwork),
    F(0x78, "mr_socket", brSocket),
    F(0x7C, "mr_connect", brConnect),
    F(0x80, "mr_getSocketState", brGetSocketState),
    F(0x84, "mr_closeSocket", brCloseSocket),
    F(0x88, "mr_recv", brRecv),
    F(0x8C, "mr_send", brSend),
    F(0x90, "mr_recvfrom", brRecvfrom),
    F(0x94, "mr_sendto", brSendto),
    F(0x98, "mr_startShake", brStartShake),
    F(0x9C, "mr_stopShake", brStopShake),
    F(0xA0, "mr_playSound", brPlaySound),
    F(0xA4, "mr_stopSound", brStopSound),
    F(0xA8, "mr_dialogCreate", brDialogCreate),
    F(0xAC, "mr_dialogRelease", brDialogRelease),
    F(0xB0, "mr_dialogRefresh", brDialogRefresh),
    F(0xB4, "mr_textCreate", brTextCreate),
    F(0xB8, "mr_textRelease", brTextRelease),
    F(0xBC, "mr_textRefresh", brTextRefresh),
    F(0xC0, "mr_editCreate", brEditCreate),
    F(0xC4, "mr_editRelease", brEditRelease),
    F(0xC8, "mr_editGetText", brEditGetText),
};
