//! Fixed-buffer free-list allocator for the object heap.
//!
//! The object heap (Instance structs, their field maps, owned byte/int buffers, the
//! handle table, the palette side-table) used to come from `std.heap.c_allocator`. That
//! is a general-purpose host malloc — unavailable on a bare-metal RTOS target, where we
//! must own all of our memory up front. This allocator hands out memory from ONE fixed
//! buffer the caller provides (on RTOS: a static array; in the WASM/desktop builds: a
//! single boot-time allocation). Steady-state VM execution then performs ZERO calls to a
//! general-purpose allocator — every object alloc/free is satisfied from this buffer.
//!
//! Unlike a `FixedBufferAllocator` (bump-only, can't reclaim), this is a real allocator
//! with `free` + coalescing, so the GC's `freeOne` actually returns memory to the pool.
//! That is the whole reason the object heap can live in a fixed region at all: a bump
//! arena grew unboundedly (~786 live objects) because nothing was ever reclaimed.
//!
//! Implementation: an address-sorted singly-linked free list. Each free block stores an
//! 8-byte header {next_off: u32, len: u32} in its own first bytes; allocated blocks carry
//! no header (the `Allocator` vtable hands us the length back on `free`). All blocks are
//! 16-byte aligned and 16-byte-multiple sized, so any allocation with alignment ≤ 16 is
//! satisfied at a block start, and a split remainder is always ≥ 16 (room for a header).
//! Offsets are relative to the aligned base, so the free list itself is position-
//! independent — it survives a relocation of the backing buffer.
const std = @import("std");

const NIL: u32 = 0xFFFF_FFFF;
const GRAIN: usize = 16;

inline fn roundUp(n: usize) usize {
    return (@max(n, 1) + (GRAIN - 1)) & ~@as(usize, GRAIN - 1);
}

pub const ObjectArena = struct {
    /// Whole backing buffer as handed in.
    mem: []u8,
    /// 16-aligned base pointer inside `mem` (skips any leading misalignment).
    base: [*]u8,
    /// Usable length from `base`, rounded down to a multiple of 16.
    len: usize,
    /// Offset (from `base`) of the first free block, or NIL when full.
    head: u32,

    pub fn init(buffer: []u8) ObjectArena {
        const addr = @intFromPtr(buffer.ptr);
        const aligned = std.mem.alignForward(usize, addr, GRAIN);
        const pad = aligned - addr;
        const usable = (buffer.len - pad) & ~@as(usize, GRAIN - 1);
        var self: ObjectArena = .{
            .mem = buffer,
            .base = @ptrFromInt(aligned),
            .len = usable,
            .head = 0,
        };
        // One free block spanning the whole usable region.
        self.setNext(0, NIL);
        self.setLen(0, @intCast(usable));
        return self;
    }

    // --- free-block header access (offsets relative to base) ----------------
    inline fn nodeNext(self: *const ObjectArena, off: u32) u32 {
        return std.mem.readInt(u32, (self.base + off)[0..4], .little);
    }
    inline fn nodeLen(self: *const ObjectArena, off: u32) u32 {
        return std.mem.readInt(u32, (self.base + off + 4)[0..4], .little);
    }
    inline fn setNext(self: *ObjectArena, off: u32, v: u32) void {
        std.mem.writeInt(u32, (self.base + off)[0..4], v, .little);
    }
    inline fn setLen(self: *ObjectArena, off: u32, v: u32) void {
        std.mem.writeInt(u32, (self.base + off + 4)[0..4], v, .little);
    }

    // --- core alloc/free ----------------------------------------------------
    fn allocBlock(self: *ObjectArena, want: usize, byte_align: usize) ?[*]u8 {
        if (byte_align > GRAIN) return null; // every block start is 16-aligned
        const need: u32 = @intCast(roundUp(want));

        var prev: u32 = NIL;
        var cur = self.head;
        while (cur != NIL) {
            const clen = self.nodeLen(cur);
            if (clen >= need) {
                const next = self.nodeNext(cur);
                if (clen == need) {
                    // Exact fit: unlink the whole block.
                    self.linkPrev(prev, next);
                } else {
                    // Carve `need` off the front; the remainder (always ≥ 16,
                    // since both clen and need are 16-multiples) stays free.
                    const rem = cur + need;
                    self.setNext(rem, next);
                    self.setLen(rem, clen - need);
                    self.linkPrev(prev, rem);
                }
                return self.base + cur;
            }
            prev = cur;
            cur = self.nodeNext(cur);
        }
        return null;
    }

    /// Point `prev`'s next pointer (or the head) at `target`.
    inline fn linkPrev(self: *ObjectArena, prev: u32, target: u32) void {
        if (prev == NIL) self.head = target else self.setNext(prev, target);
    }

    fn freeBlock(self: *ObjectArena, ptr: [*]u8, size_in: usize) void {
        const off: u32 = @intCast(@intFromPtr(ptr) - @intFromPtr(self.base));
        const size: u32 = @intCast(roundUp(size_in));

        // Find the insertion point: prev = last free block before `off`.
        var prev: u32 = NIL;
        var cur = self.head;
        while (cur != NIL and cur < off) {
            prev = cur;
            cur = self.nodeNext(cur);
        }

        // Coalesce with the previous block if it ends exactly at `off`.
        if (prev != NIL and prev + self.nodeLen(prev) == off) {
            self.setLen(prev, self.nodeLen(prev) + size);
            // Then coalesce prev with the following block if now adjacent.
            if (cur != NIL and prev + self.nodeLen(prev) == cur) {
                self.setLen(prev, self.nodeLen(prev) + self.nodeLen(cur));
                self.setNext(prev, self.nodeNext(cur));
            }
            return;
        }

        // Insert a fresh node at `off`.
        self.setNext(off, cur);
        self.setLen(off, size);
        self.linkPrev(prev, off);
        // Coalesce the new node with the following block if adjacent.
        if (cur != NIL and off + size == cur) {
            self.setLen(off, size + self.nodeLen(cur));
            self.setNext(off, self.nodeNext(cur));
        }
    }

    inline fn owns(self: *const ObjectArena, ptr: [*]u8) bool {
        const a = @intFromPtr(ptr);
        const lo = @intFromPtr(self.base);
        return a >= lo and a < lo + self.len;
    }

    /// Bytes currently on the free list (diagnostics).
    pub fn freeBytes(self: *const ObjectArena) usize {
        var total: usize = 0;
        var cur = self.head;
        while (cur != NIL) : (cur = self.nodeNext(cur)) total += self.nodeLen(cur);
        return total;
    }

    pub fn allocator(self: *ObjectArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    fn vAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        _ = ra;
        const self: *ObjectArena = @ptrCast(@alignCast(ctx));
        return self.allocBlock(n, alignment.toByteUnits());
    }

    fn vResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        _ = alignment;
        _ = ra;
        const self: *ObjectArena = @ptrCast(@alignCast(ctx));
        const old = roundUp(buf.len);
        const new = roundUp(new_len);
        if (new == old) return true;
        if (new < old) {
            // Shrink in place: release the tail [ptr+new, ptr+old) back to the pool.
            self.freeBlock(buf.ptr + new, old - new);
            return true;
        }
        return false; // grow → caller falls back to alloc+copy+free
    }

    fn vRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (vResize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
    }

    fn vFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        _ = alignment;
        _ = ra;
        const self: *ObjectArena = @ptrCast(@alignCast(ctx));
        if (buf.len == 0 or !self.owns(buf.ptr)) return;
        self.freeBlock(buf.ptr, buf.len);
    }
};

// ---------------------------------------------------------------------------
test "alloc/free/coalesce round-trip" {
    var backing: [4096]u8 = undefined;
    var arena = ObjectArena.init(&backing);
    const a = arena.allocator();

    const start_free = arena.freeBytes();
    const p1 = try a.alloc(u8, 100);
    const p2 = try a.alloc(u8, 200);
    const p3 = try a.alloc(u8, 50);
    try std.testing.expect(arena.freeBytes() < start_free);

    // Free the middle, then the neighbours — everything must coalesce back.
    a.free(p2);
    a.free(p1);
    a.free(p3);
    try std.testing.expectEqual(start_free, arena.freeBytes());

    // After full reclaim a big allocation that needs the whole pool succeeds.
    const big = try a.alloc(u8, 3000);
    a.free(big);
    try std.testing.expectEqual(start_free, arena.freeBytes());
}

test "reuse freed hole and 16-byte alignment" {
    var backing: [2048]u8 = undefined;
    var arena = ObjectArena.init(&backing);
    const a = arena.allocator();

    const x = try a.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(x.ptr) % 16);
    a.free(x);
    const y = try a.alloc(u8, 64); // same-size request reuses the just-freed block
    try std.testing.expectEqual(@intFromPtr(x.ptr), @intFromPtr(y.ptr));
}

test "struct + hashmap live on the arena" {
    var backing: [1 << 16]u8 = undefined;
    var arena = ObjectArena.init(&backing);
    const a = arena.allocator();

    var map = std.AutoHashMap(u32, u32).init(a);
    defer map.deinit();
    var i: u32 = 0;
    while (i < 200) : (i += 1) try map.put(i, i * 3);
    try std.testing.expectEqual(@as(u32, 297), map.get(99).?);
}
