//! Save-state serialization for the MRP VM (libretro `retro_serialize` primitive,
//! also reusable from the WASM frontend).
//!
//! Like mre-player: guest RAM is a flat region addressed by guest address
//! (position-independent), so it's dumped/reloaded wholesale. The architectural ARM
//! registers come through Unicorn (the JIT/TCI cache is derived from memory, never
//! saved). The remaining host state is small and explicit — note that the LG
//! allocator keeps two *mutable* host scalars (`left`, `head_next`) beside its
//! in-guest free-list nodes, so those must be captured or allocation breaks on
//! restore. The one-shot timer is frontend state and is appended by the libretro
//! core, not here.
const std = @import("std");
const Vm = @import("vm.zig").Vm;
const cpu_mod = @import("cpu/unicorn.zig");
const c = cpu_mod.c;

const MAGIC: u32 = 0x4D525053; // "MRPS"
const VERSION: u32 = 1;

const REGS = [_]c_int{
    c.UC_ARM_REG_R0,  c.UC_ARM_REG_R1,  c.UC_ARM_REG_R2,  c.UC_ARM_REG_R3,
    c.UC_ARM_REG_R4,  c.UC_ARM_REG_R5,  c.UC_ARM_REG_R6,  c.UC_ARM_REG_R7,
    c.UC_ARM_REG_R8,  c.UC_ARM_REG_R9,  c.UC_ARM_REG_R10, c.UC_ARM_REG_R11,
    c.UC_ARM_REG_R12, c.UC_ARM_REG_SP,  c.UC_ARM_REG_LR,  c.UC_ARM_REG_PC,
    c.UC_ARM_REG_CPSR,
};

pub fn size(vm: *Vm) usize {
    // guest RAM + framebuffer (240x320x2) + scalars, with margin.
    return vm.mem.buf.len + @sizeOf(@TypeOf(vm.gfx.screen)) + 4096;
}

const Cursor = struct {
    buf: []u8,
    pos: usize = 0,
    fn bytes(self: *Cursor, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn u32v(self: *Cursor, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    fn val(self: *Cursor, v: anytype) void {
        self.bytes(std.mem.asBytes(&v));
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    fn bytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }
    fn u32v(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.bytes(4))[0..4], .little);
    }
    fn val(self: *Reader, comptime T: type) !T {
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), try self.bytes(@sizeOf(T)));
        return v;
    }
};

pub fn save(vm: *Vm, out: []u8) !usize {
    var w = Cursor{ .buf = out };
    w.u32v(MAGIC);
    w.u32v(VERSION);

    // guest RAM (flat, position-independent — includes the LG free-list nodes)
    w.u32v(@intCast(vm.mem.buf.len));
    w.bytes(vm.mem.buf);

    // LG allocator host scalars (base/len constant; left/head_next mutable)
    w.u32v(vm.mem.base);
    w.u32v(vm.mem.len);
    w.u32v(vm.mem.left);
    w.u32v(vm.mem.head_next);

    // architectural ARM registers
    for (REGS) |reg| w.u32v(vm.cpu.readReg(reg));

    // bridge / dsm entry-point addresses (guest addresses, set during boot)
    w.u32v(vm.mr_table_addr);
    w.u32v(vm.dsm_funcs_addr);
    w.u32v(vm.mr_extHelper_addr);
    w.u32v(vm.mr_c_function_P);
    w.u32v(vm.mr_c_event);
    w.u32v(vm.dsm_event);
    w.u32v(vm.mr_start_dsm_param);
    w.u32v(vm.readdir_shared);
    w.u32v(vm.edit_text_addr);

    // misc host scalars + gfx
    w.val(vm.uptime_base);
    w.val(vm.clock_ms);
    w.u32v(vm.rng);
    w.u32v(@intFromBool(vm.quit_requested));
    w.u32v(@intFromBool(vm.halted));
    w.u32v(@intFromBool(vm.gfx.dirty));
    w.bytes(std.mem.asBytes(&vm.gfx.screen));

    return w.pos;
}

pub fn load(vm: *Vm, in: []const u8) !void {
    var r = Reader{ .buf = in };
    if (try r.u32v() != MAGIC) return error.BadMagic;
    if (try r.u32v() != VERSION) return error.BadVersion;

    const ram_len = try r.u32v();
    if (ram_len != vm.mem.buf.len) return error.RamSizeMismatch;
    @memcpy(vm.mem.buf, try r.bytes(ram_len));

    vm.mem.base = try r.u32v();
    vm.mem.len = try r.u32v();
    vm.mem.left = try r.u32v();
    vm.mem.head_next = try r.u32v();

    for (REGS) |reg| vm.cpu.writeReg(reg, try r.u32v());

    vm.mr_table_addr = try r.u32v();
    vm.dsm_funcs_addr = try r.u32v();
    vm.mr_extHelper_addr = try r.u32v();
    vm.mr_c_function_P = try r.u32v();
    vm.mr_c_event = try r.u32v();
    vm.dsm_event = try r.u32v();
    vm.mr_start_dsm_param = try r.u32v();
    vm.readdir_shared = try r.u32v();
    vm.edit_text_addr = try r.u32v();

    vm.uptime_base = try r.val(i64);
    vm.clock_ms = try r.val(u64);
    vm.rng = try r.u32v();
    vm.quit_requested = (try r.u32v()) != 0;
    vm.halted = (try r.u32v()) != 0;
    vm.gfx.dirty = (try r.u32v()) != 0;
    @memcpy(std.mem.asBytes(&vm.gfx.screen), try r.bytes(@sizeOf(@TypeOf(vm.gfx.screen))));
}
