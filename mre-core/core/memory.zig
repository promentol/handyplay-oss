//! Emulated address space + allocator.
//!
//! A single contiguous host buffer is mapped into
//! Unicorn at EMU address 0 (`uc_mem_map_ptr`), so an EMU address is simply a byte
//! offset into that buffer. That keeps translation trivial and host-pointer-free:
//!   - `toEmu(host_ptr) = host_ptr - buf.ptr`
//!   - `fromEmu(e)      = buf.ptr + e`   (e == 0 is the null sentinel)
//!
//! The `Manager` is a best-fit allocator over a
//! [start, start+size) range with an optional low "protected" reserve. It works in
//! absolute EMU offsets, so a per-app arena is just a `Manager` whose `start` is the
//! EMU offset of the region the shared manager handed it.
const std = @import("std");

pub const Region = struct { adr: u32, size: u32 };

pub const Manager = struct {
    start: u32 = 0,
    size: u32 = 0,
    free_size: u32 = 0,
    protected_size: u32 = 0,
    regions: std.ArrayList(Region) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Manager {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Manager) void {
        self.regions.deinit(self.gpa);
    }

    pub fn setup(self: *Manager, start: u32, size: u32, protected_size: u32) void {
        self.start = start;
        self.size = size;
        self.protected_size = protected_size;
        self.free_size = size;
        self.regions.clearRetainingCapacity();
    }

    /// Returns an absolute EMU offset, or 0 on failure. `align_` must be a power of two.
    pub fn malloc(self: *Manager, size: u32, allow_protected: bool, align_: u32) u32 {
        const reserve: u32 = if (allow_protected) 0 else self.protected_size;
        if (size > self.free_size - reserve) return 0;

        var new_adr: u32 = self.start + reserve;

        for (self.regions.items, 0..) |reg, i| {
            new_adr = alignUp(new_adr, align_);
            // Strict `<` matches the reference (leaves a 1-byte cushion).
            if (new_adr + size < reg.adr) {
                self.regions.insert(self.gpa, i, .{ .adr = new_adr, .size = size }) catch return 0;
                self.free_size -= size;
                return new_adr;
            }
            new_adr = reg.adr + reg.size;
        }

        new_adr = alignUp(new_adr, align_);
        if (new_adr + size < self.start + self.size) {
            self.regions.append(self.gpa, .{ .adr = new_adr, .size = size }) catch return 0;
            self.free_size -= size;
            return new_adr;
        }
        return 0;
    }

    pub fn realloc(self: *Manager, mem: *Memory, addr: u32, size: u32) u32 {
        if (addr == 0) return self.malloc(size, false, 8);
        if (size == 0) {
            self.free(addr);
            return addr;
        }

        const mem_ind: usize = for (self.regions.items, 0..) |reg, i| {
            if (reg.adr == addr) break i;
        } else return self.malloc(size, false, 8);

        const cur = self.regions.items[mem_ind];
        if (size <= cur.size) {
            self.free_size += cur.size - size;
            self.regions.items[mem_ind].size = size;
            return cur.adr;
        }

        // Can we grow in place (up to the next region, or the arena end)?
        var allow_max: u32 = self.size - (cur.adr - self.start);
        if (mem_ind + 1 < self.regions.items.len)
            allow_max = self.regions.items[mem_ind + 1].adr - cur.adr;

        if (allow_max >= size) {
            self.free_size -= size - cur.size;
            self.regions.items[mem_ind].size = size;
            return cur.adr;
        }

        const new_adr = self.malloc(size, false, 8);
        if (new_adr == 0) return 0;
        const old = cur; // free() may reorder regions; copy first
        @memcpy(mem.slice(new_adr, old.size), mem.slice(old.adr, old.size));
        self.free(old.adr);
        return new_adr;
    }

    pub fn free(self: *Manager, addr: u32) void {
        for (self.regions.items, 0..) |reg, i| {
            if (reg.adr == addr) {
                self.free_size += reg.size;
                _ = self.regions.orderedRemove(i);
                return;
            }
        }
    }
};

fn alignUp(v: u32, align_: u32) u32 {
    if (align_ == 0) return v;
    const rem = v % align_;
    return if (rem == 0) v else v + (align_ - rem);
}

pub const Memory = struct {
    buf: []u8,
    shared: Manager,
    gpa: std.mem.Allocator,

    /// 10 MB low reserve, matching `Memory::init`.
    pub const protected_reserve: u32 = 10 * 1024 * 1024;
    /// EMU offset 0 is the null sentinel; reserve a page so it is never allocated.
    pub const null_guard: u32 = 0x1000;

    pub fn init(gpa: std.mem.Allocator, size: u32) !Memory {
        // Page-aligned host buffer; the guest only ever sees EMU offsets, so host
        // alignment beyond a page is irrelevant to correctness.
        const buf = try gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
        @memset(buf, 0);
        var shared = Manager.init(gpa);
        shared.setup(0, size, protected_reserve);
        var self: Memory = .{ .buf = buf, .shared = shared, .gpa = gpa };
        // Pin [0, null_guard) so no allocation is ever returned as EMU 0 (== null).
        _ = self.shared.malloc(null_guard, true, 1);
        return self;
    }

    pub fn deinit(self: *Memory) void {
        self.shared.deinit();
        self.gpa.free(self.buf);
    }

    pub fn sharedMalloc(self: *Memory, size: u32, allow_protected: bool, align_: u32) u32 {
        return self.shared.malloc(size, allow_protected, align_);
    }

    pub fn sharedFree(self: *Memory, addr: u32) void {
        self.shared.free(addr);
    }

    /// EMU offset -> host slice of `len` bytes. Asserts in-bounds.
    pub fn slice(self: *Memory, e: u32, len: u32) []u8 {
        std.debug.assert(@as(u64, e) + len <= self.buf.len);
        return self.buf[e .. e + len];
    }

    /// EMU offset -> raw host pointer; null for the 0 sentinel.
    pub fn fromEmu(self: *Memory, e: u32) ?[*]u8 {
        if (e == 0) return null;
        std.debug.assert(e < self.buf.len);
        return self.buf.ptr + e;
    }

    /// Host pointer -> EMU offset; 0 for null.
    pub fn toEmu(self: *Memory, p: ?[*]const u8) u32 {
        const ptr = p orelse return 0;
        const base = @intFromPtr(self.buf.ptr);
        const adr = @intFromPtr(ptr);
        std.debug.assert(adr >= base and adr < base + self.buf.len);
        return @intCast(adr - base);
    }

    pub fn readU32(self: *Memory, e: u32) u32 {
        return std.mem.readInt(u32, self.buf[e..][0..4], .little);
    }

    pub fn writeU32(self: *Memory, e: u32, v: u32) void {
        std.mem.writeInt(u32, self.buf[e..][0..4], v, .little);
    }

    pub fn readU16(self: *Memory, e: u32) u16 {
        return std.mem.readInt(u16, self.buf[e..][0..2], .little);
    }

    pub fn writeU16(self: *Memory, e: u32, v: u16) void {
        std.mem.writeInt(u16, self.buf[e..][0..2], v, .little);
    }
};

test "translation round-trip" {
    var mem = try Memory.init(std.testing.allocator, 1 << 20);
    defer mem.deinit();

    const e: u32 = 0x4000;
    const p = mem.fromEmu(e).?;
    try std.testing.expectEqual(e, mem.toEmu(p));
    try std.testing.expectEqual(@as(?[*]u8, null), mem.fromEmu(0));
    try std.testing.expectEqual(@as(u32, 0), mem.toEmu(null));
}

test "allocator best-fit, protected reserve, free, realloc" {
    var mem = try Memory.init(std.testing.allocator, 4 * 1024 * 1024);
    defer mem.deinit();
    // Shrink protected reserve for the test arena.
    mem.shared.setup(0, @intCast(mem.buf.len), 64 * 1024);

    // Non-protected allocations start past the reserve.
    const a = mem.sharedMalloc(1024, false, 8);
    try std.testing.expect(a >= 64 * 1024);
    const b = mem.sharedMalloc(1024, false, 8);
    try std.testing.expect(b > a);

    // Alignment honored.
    const c = mem.sharedMalloc(16, false, 0x1000);
    try std.testing.expectEqual(@as(u32, 0), c % 0x1000);

    // Free then re-malloc reuses the freed gap (still only non-protected regions).
    mem.sharedFree(a);
    const a2 = mem.sharedMalloc(512, false, 8);
    try std.testing.expectEqual(a, a2);

    // realloc grows by relocating; data preserved.
    mem.writeU32(b, 0xdeadbeef);
    const b2 = mem.shared.realloc(&mem, b, 1 << 20);
    try std.testing.expect(b2 != 0);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), mem.readU32(b2));

    // Protected allocation can dip into the low reserve.
    const p = mem.sharedMalloc(32, true, 8);
    try std.testing.expect(p < 64 * 1024);
}
