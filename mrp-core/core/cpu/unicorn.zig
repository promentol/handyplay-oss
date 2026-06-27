//! Unicorn-backed ARM CPU. Thin wrapper over the C API; the rest of the core talks
//! to this `Cpu` type rather than libunicorn directly.
//!
//! This file owns the single `@cImport` of unicorn.h. Other modules use
//! `@import("cpu/unicorn.zig").c` so register/hook constants share one C type set
//! (separate @cImports would produce incompatible opaque types).
//!
//! The dsm engine (`cfunction.ext`) runs in ARM mode (UC_MODE_ARM), with ARM/Thumb
//! interworking driven by the per-branch address LSB.
const std = @import("std");

pub const c = @cImport(@cInclude("unicorn/unicorn.h"));

pub const Hook = c.uc_hook;
pub const Error = error{ Open, MemMap, MemIo, RegIo, HookAdd };

pub const Cpu = struct {
    uc: *c.uc_engine,

    /// ARM mode (`uc_open(UC_ARCH_ARM, UC_MODE_ARM)`). Interworking still follows
    /// the branch-target LSB, so a Thumb entry point (addr | 1) runs as Thumb.
    pub fn open() Error!Cpu {
        var uc: ?*c.uc_engine = null;
        if (c.uc_open(c.UC_ARCH_ARM, c.UC_MODE_ARM, &uc) != c.UC_ERR_OK) return Error.Open;
        return .{ .uc = uc.? };
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

    /// Read a little-endian u32 from guest memory.
    pub fn read32(self: *Cpu, addr: u64) u32 {
        var v: u32 = 0;
        _ = c.uc_mem_read(self.uc, addr, &v, 4);
        return v;
    }

    /// Write a little-endian u32 to guest memory.
    pub fn write32(self: *Cpu, addr: u64, val: u32) void {
        var v = val;
        _ = c.uc_mem_write(self.uc, addr, &v, 4);
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

    pub fn strerror(err: c.uc_err) [*:0]const u8 {
        return c.uc_strerror(err);
    }
};
