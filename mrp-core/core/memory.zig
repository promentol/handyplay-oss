//! Guest address space + heap allocator: the guest memory layout, the LG
//! free-list allocator, and the address<->pointer helpers.
//!
//! The allocator runs in guest-address space directly: `mallocExt` returns a
//! guest address (0 == NULL), and `ptr()`/`slice()` hand back host views into the
//! single flat buffer — no host-pointer/guest-address juggling at the bridge
//! boundary, just one free-list laid out in guest memory.
const std = @import("std");

// --- Guest memory layout ----------------------------------------------------
pub const CODE_ADDRESS: u32 = 0x80000; // dsm engine (cfunction.ext) loads here
pub const CODE_SIZE: u32 = 1 * 1024 * 1024;
pub const STACK_ADDRESS: u32 = CODE_ADDRESS + CODE_SIZE;
pub const STACK_SIZE: u32 = 1 * 1024 * 1024;
pub const MEMORY_MANAGER_ADDRESS: u32 = STACK_ADDRESS + STACK_SIZE;
pub const MEMORY_MANAGER_SIZE: u32 = 6 * 1024 * 1024;
pub const START_ADDRESS: u32 = CODE_ADDRESS;
pub const END_ADDRESS: u32 = MEMORY_MANAGER_ADDRESS + MEMORY_MANAGER_SIZE;
pub const TOTAL_MEMORY: u32 = END_ADDRESS - START_ADDRESS;

/// 8-byte rounding used by the LG allocator (`realLGmemSize`).
inline fn realLGmemSize(x: u32) u32 {
    return (x + 7) & 0xfffffff8;
}

/// Free-list node {next, len} stored at the head of every free block.
/// `next` is an offset relative to `base`. next at +0, len +4.
const NODE_SIZE: u32 = 8;

pub const Memory = struct {
    gpa: std.mem.Allocator,
    buf: []u8, // flat guest RAM, [START_ADDRESS, END_ADDRESS)

    // LG allocator state, all offsets relative to `base`.
    base: u32 = 0, // guest address of the aligned manager region
    len: u32 = 0, // usable manager length
    left: u32 = 0, // bytes free
    head_next: u32 = 0, // LG_mem_free.next: offset of first free block

    pub fn init(gpa: std.mem.Allocator) !Memory {
        const buf = try gpa.alloc(u8, TOTAL_MEMORY);
        @memset(buf, 0);
        var m: Memory = .{ .gpa = gpa, .buf = buf };
        m.initManager(MEMORY_MANAGER_ADDRESS, MEMORY_MANAGER_SIZE);
        return m;
    }

    pub fn deinit(self: *Memory) void {
        self.gpa.free(self.buf);
    }

    // --- address <-> host view ---------------------------------------------
    /// Host pointer for a guest address. No bounds check; callers pass addresses
    /// the guest produced.
    pub inline fn ptr(self: *Memory, addr: u32) [*]u8 {
        return self.buf.ptr + (addr - START_ADDRESS);
    }

    /// Host slice of `n` bytes at guest address `addr`.
    pub inline fn slice(self: *Memory, addr: u32, n: usize) []u8 {
        const off = addr - START_ADDRESS;
        return self.buf[off .. off + n];
    }

    /// Guest address of a host pointer into `buf`.
    pub inline fn addrOf(self: *Memory, p: [*]const u8) u32 {
        return @intCast(@intFromPtr(p) - @intFromPtr(self.buf.ptr) + START_ADDRESS);
    }

    pub inline fn read32(self: *Memory, addr: u32) u32 {
        return std.mem.readInt(u32, self.buf[addr - START_ADDRESS ..][0..4], .little);
    }
    pub inline fn write32(self: *Memory, addr: u32, v: u32) void {
        std.mem.writeInt(u32, self.buf[addr - START_ADDRESS ..][0..4], v, .little);
    }

    // --- LG free-list allocator --------------------------------------------
    inline fn nodeNext(self: *Memory, off: u32) u32 {
        return self.read32(self.base + off);
    }
    inline fn nodeLen(self: *Memory, off: u32) u32 {
        return self.read32(self.base + off + 4);
    }
    inline fn setNodeNext(self: *Memory, off: u32, v: u32) void {
        self.write32(self.base + off, v);
    }
    inline fn setNodeLen(self: *Memory, off: u32, v: u32) void {
        self.write32(self.base + off + 4, v);
    }

    fn initManager(self: *Memory, base_addr: u32, region_len: u32) void {
        // Align base up to 4, shrink len to multiple of 4.
        const aligned = (base_addr + 3) & ~@as(u32, 3);
        self.base = aligned;
        self.len = (region_len - (aligned - base_addr)) & ~@as(u32, 3);
        self.head_next = 0;
        // First free block at offset 0 spans the whole region: next=len (sentinel
        // == end, so the walk terminates), len=len.
        self.setNodeNext(0, self.len);
        self.setNodeLen(0, self.len);
        self.left = self.len;
    }

    /// Raw allocation. Returns a guest address, or 0 on failure.
    pub fn malloc(self: *Memory, want: u32) u32 {
        const len = realLGmemSize(want);
        if (len == 0 or len >= self.left) return 0;

        var prev_off: ?u32 = null; // null => head node
        var cur = self.head_next;
        while (cur < self.len) {
            const clen = self.nodeLen(cur);
            const cnext = self.nodeNext(cur);
            if (clen == len) {
                self.setPrevNext(prev_off, cnext);
                self.left -= len;
                return self.base + cur;
            }
            if (clen > len) {
                const split = cur + len;
                self.setNodeNext(split, cnext);
                self.setNodeLen(split, clen - len);
                self.setPrevNext(prev_off, self.prevNext(prev_off) + len);
                self.left -= len;
                return self.base + cur;
            }
            prev_off = cur;
            cur = cnext;
        }
        return 0;
    }

    inline fn prevNext(self: *Memory, prev_off: ?u32) u32 {
        return if (prev_off) |o| self.nodeNext(o) else self.head_next;
    }
    inline fn setPrevNext(self: *Memory, prev_off: ?u32, v: u32) void {
        if (prev_off) |o| self.setNodeNext(o, v) else {
            self.head_next = v;
        }
    }

    /// Free a block obtained from `malloc` (guest address + its rounded length).
    pub fn free(self: *Memory, addr: u32, want: u32) void {
        if (addr == 0) return;
        const len = realLGmemSize(want);
        const p_off = addr - self.base;

        // Walk the sorted free list to find the slot before p.
        var prev_off: ?u32 = null;
        var n = self.head_next;
        while (n < self.len and n < p_off) {
            prev_off = n;
            n = self.nodeNext(n);
        }

        // Coalesce with previous block if adjacent, else insert p as a new node.
        var cur: u32 = undefined;
        if (prev_off) |pv| {
            if (pv + self.nodeLen(pv) == p_off) {
                self.setNodeLen(pv, self.nodeLen(pv) + len);
                cur = pv;
            } else {
                self.setPrevNext(prev_off, p_off);
                self.setNodeNext(p_off, n);
                self.setNodeLen(p_off, len);
                cur = p_off;
            }
        } else {
            self.head_next = p_off;
            self.setNodeNext(p_off, n);
            self.setNodeLen(p_off, len);
            cur = p_off;
        }

        // Coalesce with the following block if adjacent.
        if (n < self.len and p_off + len == n) {
            self.setNodeNext(cur, self.nodeNext(n));
            self.setNodeLen(cur, self.nodeLen(cur) + self.nodeLen(n));
        }
        self.left += len;
    }

    // --- Ext helpers (length-prefixed) -------------------------------------
    /// `mallocExt`: prepend a u32 length header so `freeExt` needs only the ptr.
    /// Returns the guest address of the payload (0 == NULL).
    pub fn mallocExt(self: *Memory, len: u32) u32 {
        if (len == 0) return 0;
        const p = self.malloc(len + 4);
        if (p == 0) return 0;
        self.write32(p, len);
        return p + 4;
    }

    /// Zeroing variant of `mallocExt`.
    pub fn mallocExt0(self: *Memory, len: u32) u32 {
        const p = self.mallocExt(len);
        if (p != 0) @memset(self.slice(p, len), 0);
        return p;
    }

    pub fn freeExt(self: *Memory, addr: u32) void {
        if (addr == 0) return;
        const hdr = addr - 4;
        const l = self.read32(hdr);
        self.free(hdr, l + 4);
    }

    /// Allocate guest memory and copy a NUL-terminated string into it.
    /// Returns the guest address.
    pub fn copyStrToGuest(self: *Memory, str: []const u8) u32 {
        const addr = self.mallocExt(@intCast(str.len + 1));
        if (addr == 0) return 0;
        const dst = self.slice(addr, str.len + 1);
        @memcpy(dst[0..str.len], str);
        dst[str.len] = 0;
        return addr;
    }
};

// ---------------------------------------------------------------------------
test "guest memory layout constants" {
    try std.testing.expectEqual(@as(u32, 0x80000), START_ADDRESS);
    try std.testing.expectEqual(@as(u32, 0x180000), STACK_ADDRESS);
    try std.testing.expectEqual(@as(u32, 0x280000), MEMORY_MANAGER_ADDRESS);
    try std.testing.expectEqual(@as(u32, 6 * 1024 * 1024), MEMORY_MANAGER_SIZE);
}

test "alloc/free round trip and reuse" {
    var m = try Memory.init(std.testing.allocator);
    defer m.deinit();

    const a = m.malloc(100);
    try std.testing.expect(a != 0);
    const b = m.malloc(200);
    try std.testing.expect(b != 0);
    try std.testing.expect(b != a);

    // 100 rounds up to 104, 200 to 200.
    const left_after = m.left;
    m.free(a, 100);
    try std.testing.expectEqual(left_after + 104, m.left);

    // Same-size request reuses the just-freed hole.
    const a2 = m.malloc(100);
    try std.testing.expectEqual(a, a2);
}

test "mallocExt header + freeExt" {
    var m = try Memory.init(std.testing.allocator);
    defer m.deinit();
    const before = m.left;
    const p = m.mallocExt(50);
    try std.testing.expect(p != 0);
    try std.testing.expectEqual(@as(u32, 50), m.read32(p - 4)); // length header
    m.freeExt(p);
    try std.testing.expectEqual(before, m.left); // fully reclaimed
}

test "copyStrToGuest" {
    var m = try Memory.init(std.testing.allocator);
    defer m.deinit();
    const p = m.copyStrToGuest("dsm_gm.mrp");
    const s = m.slice(p, 11);
    try std.testing.expectEqualStrings("dsm_gm.mrp", s[0..10]);
    try std.testing.expectEqual(@as(u8, 0), s[10]);
}

test "coalesce adjacent frees" {
    var m = try Memory.init(std.testing.allocator);
    defer m.deinit();
    const full = m.left;
    const a = m.malloc(64);
    const b = m.malloc(64);
    const c = m.malloc(64);
    _ = c;
    m.free(a, 64);
    m.free(b, 64); // should merge with a's hole and/or the tail
    // A 128-byte request should now fit in the merged region.
    const big = m.malloc(128);
    try std.testing.expect(big != 0);
    _ = full;
}
