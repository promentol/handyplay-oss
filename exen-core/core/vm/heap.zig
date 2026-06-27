//! Object heap — hands out monotonically-increasing u32 handles. Each
//! `Instance` owns its hash-keyed field map, optional decoded pixel
//! raster, and an optional owned byte buffer. Handles are stable for
//! the lifetime of the VM (no compaction).

const std = @import("std");

/// Heap-allocated object instance (referenced by u32 handle in the
/// operand stack). Handle 0 = null. Mirrors the simulator's heap
/// object layout: class pointer at +4 (we store the class hash) and
/// instance fields starting at +16.
pub const Instance = struct {
    class_hash: u32,
    /// Transient GC mark (set during the mark phase, cleared each collection). The
    /// collector is a conservative mark-sweep rooted at class statics + the live
    /// operand slab + a small pin set; from each marked object it follows any field /
    /// array slot whose u32 value is itself a live handle. Conservative (an int that
    /// equals a live handle over-retains, never frees a live object) — chosen over
    /// canonical's per-field-type refcount because it can't crash a gamelet by
    /// under-counting a missed native store site. See reference_exen_canonical_gc.
    gc_seen: bool = false,
    /// Slot-indexed storage. Used by array opcodes (NEWARRAY stores
    /// length at slot 0, elements at 1..N) and as a fallback when a
    /// field's owning class can't be resolved.
    fields: [64]u32 = .{0} ** 64,
    /// Hash-keyed field storage. Object instances use this for normal
    /// field access — each field is unique by its u32 hash regardless
    /// of which class along the super chain declared it, which avoids
    /// slot collisions when two classes both declare a "slot 0" field.
    field_map: std.AutoHashMap(u32, u32) = undefined,
    field_map_init: bool = false,
    /// Decoded ABGR8888 pixel buffer — read-only view used by
    /// `Graphics.drawImage`. May be either:
    ///   * borrowed from the pre-decoded image cache (legacy
    ///     opNew-bound path; `pixels_owned` stays null), or
    ///   * a freshly-decoded raster produced by
    ///     `image.TransformBitmapFromResExed` (`pixels_owned`
    ///     holds the same slice; freed by `heap.deinit`).
    pixels: ?[]const u32 = null,
    pixels_owned: ?[]u32 = null,
    /// Parallel buffer of source palette indices — one byte per pixel,
    /// same dimensions as `pixels`. Populated only by the palette-decode
    /// path (`doTransformToSystemPalette`); null when an image was
    /// PNG-decoded directly to ABGR (where index info is unavailable
    /// post-decode). Used by drawImage's transparency path to skip pixels
    /// by their SOURCE palette index — necessary because multiple
    /// palette entries can decode to the same ABGR color (e.g. palette
    /// indices 0..N all = 0x00 → black) and a decoded-color equality
    /// check would skip too many pixels.
    pixel_indices: ?[]u8 = null,
    /// True when this Image has been bound as a Graphics draw target
    /// (FIELD_GFX_TARGET 0x3dd3bff1). Its `pixels` come from compositing
    /// (drawImage), NOT from a palette-decoded resource — so
    /// `doTransformToSystemPalette` must skip it, or it would clobber the
    /// composed pixels with a blank-indexed decode. Canonical keeps a
    /// single indexed buffer per image; we approximate by never
    /// palette-decoding a render target. See
    /// reference_canonical_indexed_pipeline.
    is_render_target: bool = false,
    pix_w: u32 = 0,
    pix_h: u32 = 0,
    /// Owned byte storage — populated by `Resource.readBytes` /
    /// `readUTF` so the result is a real array the gamelet can
    /// `*ALOAD` from. Freed by `heap.deinit`.
    bytes: ?[]u8 = null,
    /// Owned int[] storage — populated by `NEWARRAY` for tag-0x59
    /// (int[]) arrays larger than `fields.len - 1`. Without this, an
    /// `int[132]` ball-X→cell-X lookup table loses everything past
    /// index 62, collapsing ball.x to 0 for every position past screen
    /// pixel 62. Freed by `heap.deinit`.
    ints: ?[]u32 = null,
    /// Image descriptor (canonical `image+40` struct). Set by
    /// `image.Init` via `sub_4176C7`; consumed by every Graphics
    /// drawing primitive. `origin_*` is the target-local coordinate
    /// origin (always 0,0 in practice for the gamelets we have;
    /// kept for canonical fidelity). `logical_w/h` is the bounds
    /// rect for clipping inside the descriptor (canonical desc[8..9]).
    /// `is_image` discriminates an Image with descriptor data from a
    /// non-Image Instance (e.g. byte[], String) so Graphics natives
    /// can early-exit if a non-Image lands as a draw target.
    desc_origin_x: i32 = 0,
    desc_origin_y: i32 = 0,
    desc_logical_w: u32 = 0,
    desc_logical_h: u32 = 0,
    desc_depth: u8 = 0,
    is_image_descriptor: bool = false,
};

/// Object heap. Hands out monotonically-increasing u32 handles.
///
/// `allocator` is the freeing gpa (c_allocator) — every `Instance`, its `field_map`,
/// and its owned buffers (bytes/ints/pixels) are allocated from here so the GC can
/// reclaim them (slab + class statics stay on the FBA arena in exen.zig). Because the
/// object graph is host pointers into the gpa heap (not a position-independent region),
/// a save-state can NOT be a flat dump like mre's guest RAM — it serializes an explicit
/// object table (handle → {class_hash, fields, field_map, bytes, ints, descriptor}) and
/// rebuilds the heap on load with handles preserved, so the handles restored into the
/// slab/statics still resolve. See exen.zig saveState/loadState (ST_VERSION 2).
pub const Heap = struct {
    /// FREEING allocator (NOT the FBA bump arena) — so `freeOne` actually reclaims an
    /// Instance + its field_map + owned buffers. Everything an Instance owns is
    /// allocated from here so the GC can return it. (slab + class statics stay on the
    /// FBA in exen.zig; only the object heap moved here so it can be collected.)
    allocator: std.mem.Allocator,
    instances: std.AutoHashMap(u32, *Instance),
    next_handle: u32 = 1,
    /// The object-arena address range (set by exen.boot). Every Instance, field_map,
    /// and owned byte/int buffer is allocated from that arena, so it is freeable. A few
    /// `pixels`/`pixel_indices` slices are BORROWED from the pre-decoded image cache
    /// (they point outside the arena) and must NOT be freed — we free a buffer only when
    /// its pointer lies inside [arena_lo, arena_hi). (Belt-and-suspenders: the arena's
    /// own `free` also no-ops on a pointer it doesn't own.)
    arena_lo: usize = 0,
    arena_hi: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .instances = std.AutoHashMap(u32, *Instance).init(allocator),
        };
    }

    /// A buffer is freeable only if non-empty (zero-length slices carry a sentinel
    /// pointer that isn't a real allocation) and resident in the object arena.
    fn freeable(self: *const Heap, ptr: usize, len: usize) bool {
        return len > 0 and ptr >= self.arena_lo and ptr < self.arena_hi;
    }

    pub fn deinit(self: *Heap) void {
        var it = self.instances.valueIterator();
        while (it.next()) |inst| self.freeInstance(inst.*);
        self.instances.deinit();
    }

    pub fn alloc(self: *Heap, class_hash: u32) !u32 {
        const inst = try self.allocator.create(Instance);
        inst.* = .{ .class_hash = class_hash };
        inst.field_map = std.AutoHashMap(u32, u32).init(self.allocator);
        inst.field_map_init = true;
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.instances.put(handle, inst);
        return handle;
    }

    pub fn get(self: *const Heap, handle: u32) ?*Instance {
        if (handle == 0) return null;
        return self.instances.get(handle);
    }

    /// Free an Instance and everything it owns (field_map + decoded/owned buffers).
    /// Pixels that are BORROWED from the image cache (`pixels` set, `pixels_owned`
    /// null) are not freed here.
    fn freeInstance(self: *Heap, inst: *Instance) void {
        if (inst.field_map_init) inst.field_map.deinit();
        if (inst.pixels_owned) |p| if (self.freeable(@intFromPtr(p.ptr), p.len)) self.allocator.free(p);
        if (inst.pixel_indices) |p| if (self.freeable(@intFromPtr(p.ptr), p.len)) self.allocator.free(p);
        if (inst.bytes) |b| if (self.freeable(@intFromPtr(b.ptr), b.len)) self.allocator.free(b);
        if (inst.ints) |b| if (self.freeable(@intFromPtr(b.ptr), b.len)) self.allocator.free(b);
        self.allocator.destroy(inst);
    }

    /// Reclaim one object by handle (the GC sweep calls this — canonical sub_40AD94).
    pub fn freeOne(self: *Heap, handle: u32) void {
        const inst = self.instances.get(handle) orelse return;
        self.freeInstance(inst);
        _ = self.instances.remove(handle);
    }

    /// Free every object and empty the table (keeps the map allocated). Used by
    /// save-state load before rebuilding the heap from the serialized object table.
    pub fn clearAll(self: *Heap) void {
        var it = self.instances.valueIterator();
        while (it.next()) |inst| self.freeInstance(inst.*);
        self.instances.clearRetainingCapacity();
        self.next_handle = 1;
    }
};
