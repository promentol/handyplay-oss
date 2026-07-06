//! Save-state serialization for the MRE VM (the libretro `retro_serialize` /
//! `retro_unserialize` primitive, also exposed through the WASM ABI).
//!
//! What makes this tractable: guest RAM is a flat EMU-offset region (no host
//! pointers baked into guest memory — `fromEmu(e) = buf.ptr + e`), so it's fully
//! position-independent: dump it and reload it at any host address. The only other
//! mutable state is the architectural CPU registers (read/written through Unicorn —
//! the JIT/TCI translation cache is *derived* from memory, so it's never saved) and
//! a small, explicit host-side struct (allocator free-list, timers, callbacks as EMU
//! addresses, rng, deterministic clock, gfx layer metadata, composite framebuffer).
//!
//! Snapshots are taken between frames (the CPU is parked at the bridge idle loop and
//! no native handler is mid-flight), so there is no transient pipeline state.
const std = @import("std");
const Vm = @import("vm.zig").Vm;
const gfx = @import("gfx.zig");
const cpu_mod = @import("cpu/unicorn.zig");
const c = cpu_mod.c;
const audio = @import("audio.zig");

const MAGIC: u32 = 0x4D524553; // "MRES"
const VERSION: u32 = 1;

// Architectural ARM registers captured/restored. R0–R15 + CPSR is sufficient for
// the user/system-mode execution these gamelets run in (banked regs are a documented
// v1 limitation). The VFP control regs are constant (set at Cpu.open), so omitted.
const REGS = [_]c_int{
    c.UC_ARM_REG_R0,  c.UC_ARM_REG_R1,  c.UC_ARM_REG_R2,  c.UC_ARM_REG_R3,
    c.UC_ARM_REG_R4,  c.UC_ARM_REG_R5,  c.UC_ARM_REG_R6,  c.UC_ARM_REG_R7,
    c.UC_ARM_REG_R8,  c.UC_ARM_REG_R9,  c.UC_ARM_REG_R10, c.UC_ARM_REG_R11,
    c.UC_ARM_REG_R12, c.UC_ARM_REG_SP,  c.UC_ARM_REG_LR,  c.UC_ARM_REG_PC,
    c.UC_ARM_REG_CPSR,
};

/// A stable upper bound for `retro_serialize_size`. The full guest region dominates;
/// the 1 MB headroom covers the allocator free-list + host struct + framebuffer.
/// (The region is mostly zeros, so the *stored* blob is compressed downstream — in
/// the console frame before IndexedDB, and by RetroArch itself for libretro states.)
pub fn size(vm: *Vm) usize {
    return vm.mem.buf.len + (1 << 20);
}

const Cursor = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeBytes(self: *Cursor, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn writeU32(self: *Cursor, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    fn writeVal(self: *Cursor, v: anytype) void {
        self.writeBytes(std.mem.asBytes(&v));
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const s = self.buf[self.pos..][0..n];
        self.pos += n;
        return s;
    }
    fn readU32(self: *Reader) !u32 {
        const s = try self.readBytes(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }
    fn readVal(self: *Reader, comptime T: type) !T {
        const s = try self.readBytes(@sizeOf(T));
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), s);
        return v;
    }
};

/// Serialize the full VM state into `out` (must be >= `size(vm)`). Returns the
/// number of bytes written.
pub fn save(vm: *Vm, out: []u8) !usize {
    var w = Cursor{ .buf = out };
    w.writeU32(MAGIC);
    w.writeU32(VERSION);

    // --- guest RAM (position-independent EMU-offset region) ---
    w.writeU32(@intCast(vm.mem.buf.len));
    w.writeBytes(vm.mem.buf);

    // --- allocator free-list (Manager) ---
    const m = &vm.mem.shared;
    w.writeU32(m.start);
    w.writeU32(m.size);
    w.writeU32(m.free_size);
    w.writeU32(m.protected_size);
    w.writeU32(@intCast(m.regions.items.len));
    for (m.regions.items) |r| {
        w.writeU32(r.adr);
        w.writeU32(r.size);
    }

    // --- architectural CPU registers ---
    for (REGS) |reg| w.writeU32(vm.cpu.readReg(reg));

    // --- host-side VM scalars ---
    w.writeU32(vm.stack_emu);
    w.writeU32(vm.cb_sysevt);
    w.writeU32(vm.cb_keyboard);
    w.writeU32(vm.cb_pen);
    w.writeU32(vm.cb_msg_proc);
    w.writeU32(@intFromBool(vm.used_screen_buffer));
    w.writeU32(@intFromBool(vm.quit_requested));
    w.writeU32(vm.rng);
    w.writeU32(vm.clock_ms);
    w.writeU32(vm.scratch);

    // --- timers (plain data) ---
    w.writeVal(vm.timers);

    // --- open-file table: tag + position per slot. The app .vxp is mem-backed
    //     (reconstructable from vm.file); host-backed handles are a v1 limitation. ---
    for (&vm.files) |slot| {
        if (slot) |f| {
            const tag: u32 = if (f.file != null) 2 else 1;
            w.writeU32(tag);
            w.writeU32(@intCast(f.pos));
        } else {
            w.writeU32(0);
            w.writeU32(0);
        }
    }

    // --- gfx: layer metadata + composite framebuffer ---
    const g = &vm.gfx;
    w.writeU32(g.base_buf1);
    w.writeU32(g.base_buf2);
    w.writeU32(@intCast(g.layer_count));
    w.writeU32(@intCast(g.active_layer));
    w.writeU32(g.global_color);
    w.writeVal(g.clip);
    w.writeVal(g.layers);
    w.writeBytes(std.mem.sliceAsBytes(g.screen));

    return w.pos;
}

/// Restore VM state previously written by `save`. The guest RAM is rewritten in
/// place (so existing Unicorn mem mapping stays valid) and registers reloaded.
pub fn load(vm: *Vm, in: []const u8) !void {
    var r = Reader{ .buf = in };
    if (try r.readU32() != MAGIC) return error.BadMagic;
    if (try r.readU32() != VERSION) return error.BadVersion;

    // --- guest RAM (overwrite in place; mapping/base unchanged) ---
    const ram_len = try r.readU32();
    if (ram_len != vm.mem.buf.len) return error.RamSizeMismatch;
    @memcpy(vm.mem.buf, try r.readBytes(ram_len));

    // --- allocator free-list ---
    const m = &vm.mem.shared;
    m.start = try r.readU32();
    m.size = try r.readU32();
    m.free_size = try r.readU32();
    m.protected_size = try r.readU32();
    const n_regions = try r.readU32();
    m.regions.clearRetainingCapacity();
    try m.regions.ensureTotalCapacity(m.gpa, n_regions);
    var i: u32 = 0;
    while (i < n_regions) : (i += 1) {
        m.regions.appendAssumeCapacity(.{ .adr = try r.readU32(), .size = try r.readU32() });
    }

    // --- CPU registers ---
    for (REGS) |reg| vm.cpu.writeReg(reg, try r.readU32());

    // --- host-side scalars ---
    vm.stack_emu = try r.readU32();
    vm.cb_sysevt = try r.readU32();
    vm.cb_keyboard = try r.readU32();
    vm.cb_pen = try r.readU32();
    vm.cb_msg_proc = try r.readU32();
    vm.used_screen_buffer = (try r.readU32()) != 0;
    vm.quit_requested = (try r.readU32()) != 0;
    vm.rng = try r.readU32();
    vm.clock_ms = try r.readU32();
    vm.scratch = try r.readU32();

    // --- timers ---
    vm.timers = try r.readVal(@TypeOf(vm.timers));

    // --- file table ---
    for (&vm.files) |*slot| {
        const tag = try r.readU32();
        const pos = try r.readU32();
        if (slot.*) |*f| f.close();
        slot.* = switch (tag) {
            1 => .{ .file = null, .data = vm.file, .pos = pos }, // app .vxp, mem-backed
            else => null, // 0 = empty; 2 = host-backed (not restored in v1)
        };
    }

    // --- gfx ---
    const g = &vm.gfx;
    g.base_buf1 = try r.readU32();
    g.base_buf2 = try r.readU32();
    g.layer_count = try r.readU32();
    g.active_layer = try r.readU32();
    g.global_color = @intCast(try r.readU32());
    g.clip = try r.readVal(@TypeOf(g.clip));
    g.layers = try r.readVal(@TypeOf(g.layers));
    @memcpy(std.mem.sliceAsBytes(g.screen), try r.readBytes(g.screen.len * 2));

    // Audio state is not serialized (v1): drop any voices from the pre-load
    // world so stale music doesn't play over the restored state. The game
    // restarts audio from its own scene logic.
    audio.reset();
}
