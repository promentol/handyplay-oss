//! Unicorn-backed ARM CPU. Thin wrapper over the C API; the rest of the core talks
//! to this `Cpu` type rather than libunicorn directly, so an alternate backend (e.g.
//! a WASM-friendly interpreter) could replace it without touching bridge/loader.
//!
//! This file owns the single `@cImport` of unicorn.h. Other modules use
//! `@import("cpu/unicorn.zig").c` so register/hook constants share one C type set
//! (separate @cImports would produce incompatible opaque types).
const std = @import("std");

pub const c = @cImport(@cInclude("unicorn/unicorn.h"));

pub const Hook = c.uc_hook;
pub const Error = error{ Open, MemMap, MemIo, RegIo, HookAdd };

pub const Cpu = struct {
    uc: *c.uc_engine,

    /// ARM with Thumb default. Interworking still follows the
    /// per-branch address LSB, so an ARM-mode entry runs as ARM.
    pub fn open() Error!Cpu {
        var uc: ?*c.uc_engine = null;
        if (c.uc_open(c.UC_ARCH_ARM, c.UC_MODE_THUMB, &uc) != c.UC_ERR_OK) return Error.Open;
        var self: Cpu = .{ .uc = uc.? };
        // Enable VFP/NEON: grant cp10/cp11 full access (CPACR) and set FPEXC.EN.
        // MRE games compiled with -mfpu use VFP; the default core leaves it off,
        // which surfaces as UC_ERR_INSN_INVALID on the first float op.
        self.writeReg(c.UC_ARM_REG_C1_C0_2, 0x00f00000);
        self.writeReg(c.UC_ARM_REG_FPEXC, 0x40000000);
        return self;
    }

    pub fn close(self: *Cpu) void {
        _ = c.uc_close(self.uc);
    }

    /// Map a host buffer into the guest at `emu_addr` (shared-memory backing).
    pub fn mapPtr(self: *Cpu, emu_addr: u64, size: usize, host: [*]u8) Error!void {
        if (c.uc_mem_map_ptr(self.uc, emu_addr, size, c.UC_PROT_ALL, host) != c.UC_ERR_OK)
            return Error.MemMap;
    }

    pub fn readReg(self: *Cpu, reg: c_int) u32 {
        var v: u32 = 0;
        _ = c.uc_reg_read(self.uc, reg, &v);
        return v;
    }

    pub fn writeReg(self: *Cpu, reg: c_int, val: u32) void {
        var v = val;
        _ = c.uc_reg_write(self.uc, reg, &v);
    }

    pub fn memWrite(self: *Cpu, addr: u64, bytes: []const u8) Error!void {
        if (c.uc_mem_write(self.uc, addr, bytes.ptr, bytes.len) != c.UC_ERR_OK)
            return Error.MemIo;
    }

    pub fn memRead(self: *Cpu, addr: u64, buf: []u8) Error!void {
        if (c.uc_mem_read(self.uc, addr, buf.ptr, buf.len) != c.UC_ERR_OK)
            return Error.MemIo;
    }

    pub fn addCodeHook(
        self: *Cpu,
        cb: *const fn (?*c.uc_engine, u64, u32, ?*anyopaque) callconv(.c) void,
        user: ?*anyopaque,
        begin: u64,
        end: u64,
    ) Error!Hook {
        var h: Hook = undefined;
        if (c.uc_hook_add(self.uc, &h, c.UC_HOOK_CODE, @constCast(@ptrCast(cb)), user, begin, end) != c.UC_ERR_OK)
            return Error.HookAdd;
        return h;
    }

    pub fn addMemInvalidHook(
        self: *Cpu,
        cb: *const fn (?*c.uc_engine, c.uc_mem_type, u64, c_int, i64, ?*anyopaque) callconv(.c) bool,
        user: ?*anyopaque,
    ) Error!Hook {
        var h: Hook = undefined;
        const types: c_int = c.UC_HOOK_MEM_READ_UNMAPPED | c.UC_HOOK_MEM_WRITE_UNMAPPED | c.UC_HOOK_MEM_FETCH_UNMAPPED;
        if (c.uc_hook_add(self.uc, &h, types, @constCast(@ptrCast(cb)), user, @as(u64, 1), @as(u64, 0)) != c.UC_ERR_OK)
            return Error.HookAdd;
        return h;
    }

    /// Returns the raw uc_err so callers can log + recover instead of aborting.
    pub fn emuStart(self: *Cpu, begin: u64, until: u64, timeout: u64, count: usize) c.uc_err {
        return c.uc_emu_start(self.uc, begin, until, timeout, count);
    }

    pub fn emuStop(self: *Cpu) void {
        _ = c.uc_emu_stop(self.uc);
    }

    /// Full register-state snapshot, for save/restore around a *nested* emuStart
    /// (a guest callback invoked from inside a native, which itself runs inside an
    /// outer emuStart). Without this the nested run clobbers the outer LR/CPSR.
    pub const Context = ?*c.uc_context;
    pub fn contextAlloc(self: *Cpu) Context {
        var ctx: ?*c.uc_context = null;
        if (c.uc_context_alloc(self.uc, &ctx) != c.UC_ERR_OK) return null;
        return ctx;
    }
    pub fn contextSave(self: *Cpu, ctx: Context) void {
        _ = c.uc_context_save(self.uc, ctx);
    }
    pub fn contextRestore(self: *Cpu, ctx: Context) void {
        _ = c.uc_context_restore(self.uc, ctx);
    }
    pub fn contextFree(ctx: Context) void {
        _ = c.uc_context_free(ctx);
    }

    pub fn addMemWriteHook(
        self: *Cpu,
        cb: *const fn (?*c.uc_engine, c.uc_mem_type, u64, c_int, i64, ?*anyopaque) callconv(.c) void,
        user: ?*anyopaque,
    ) Error!Hook {
        var h: Hook = undefined;
        if (c.uc_hook_add(self.uc, &h, c.UC_HOOK_MEM_WRITE, @constCast(@ptrCast(cb)), user, @as(u64, 1), @as(u64, 0)) != c.UC_ERR_OK)
            return Error.HookAdd;
        return h;
    }

    pub fn addMemReadHook(
        self: *Cpu,
        cb: *const fn (?*c.uc_engine, c.uc_mem_type, u64, c_int, i64, ?*anyopaque) callconv(.c) void,
        user: ?*anyopaque,
    ) Error!Hook {
        var h: Hook = undefined;
        if (c.uc_hook_add(self.uc, &h, c.UC_HOOK_MEM_READ, @constCast(@ptrCast(cb)), user, @as(u64, 1), @as(u64, 0)) != c.UC_ERR_OK)
            return Error.HookAdd;
        return h;
    }

    pub fn strerror(err: c.uc_err) [*:0]const u8 {
        return c.uc_strerror(err);
    }
};
