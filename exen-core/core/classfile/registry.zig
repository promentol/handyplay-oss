//! Class registry: combines built-in 4CVP records from `unk_4494F0.bin`
//! and gamelet 4CVP records from a loaded .exn's tail into a single
//! hash → class-record table. Mirrors the runtime state established by
//! `sub_40713F` + `sub_406FC8` in the simulator.

const std = @import("std");

pub const Error = error{
    NotA4CVP,
    BadRecord,
    ClassNotFound,
    MethodNotFound,
};

/// One built-in or gamelet class.
pub const ClassRecord = struct {
    /// Source bytes (borrowed). The 4CVP record header starts at byte 0.
    bytes: []const u8,
    /// CRC-32 of class name (or, for gamelet records, the stored hash).
    hash: u32,
    /// Sequential index in scan order. Some bytecode references
    /// classes by u16 index (NEW, INVOKE class-ref descriptors) —
    /// this mirrors the simulator's `sub_4102D4` hash → index map.
    index: u16,
    /// Where the record came from (for debugging).
    origin: Origin,

    pub const Origin = enum { builtin, gamelet };

    /// 16-bit total size of the record (u16 at +4).
    pub fn size(self: ClassRecord) u16 {
        return std.mem.readInt(u16, self.bytes[4..6], .little);
    }

    /// File-relative offset of the method-info table (u16 at +32).
    pub fn methodTableOffset(self: ClassRecord) u16 {
        return std.mem.readInt(u16, self.bytes[32..34], .little);
    }

    /// Number of method-info records.
    pub fn methodCount(self: ClassRecord) u16 {
        const mt = self.methodTableOffset();
        if (mt == 0 or mt + 2 > self.bytes.len) return 0;
        return std.mem.readInt(u16, self.bytes[mt..][0..2], .little);
    }

    /// Pointer to the start of method-info records (12 bytes each).
    pub fn firstMethodInfoOffset(self: ClassRecord) usize {
        const mt = self.methodTableOffset();
        return (mt + 5) & ~@as(usize, 3);
    }

    /// Field-table offset (u16 at byte 30 of record). Discovered by
    /// reading `sub_40DDF4` which uses `*(WORD*)(class_obj + 30)` as
    /// the field table location.
    pub fn fieldTableOffset(self: ClassRecord) u16 {
        if (self.bytes.len < 32) return 0;
        return std.mem.readInt(u16, self.bytes[30..32], .little);
    }

    /// Super-class index (u16) — the runtime class-table index of the
    /// immediate super class. Recovered from `sub_40ED5A:12583`:
    /// `v4 = *(_WORD *)(v8 + 40)`; if non-zero, dereference at that
    /// offset to read the parent's u16 class index. Returns `null` when
    /// the class is a root (java.lang.Object has +40 = 0).
    pub fn superIndex(self: ClassRecord) ?u16 {
        if (self.bytes.len < 42) return null;
        const off40 = std.mem.readInt(u16, self.bytes[40..42], .little);
        if (off40 == 0 or @as(usize, off40) + 2 > self.bytes.len) return null;
        return std.mem.readInt(u16, self.bytes[off40..][0..2], .little);
    }

    /// `<clinit>` method-info offset (u16 at byte 26). When non-zero,
    /// this points to a 12-byte method-info record for the class's
    /// static initializer. Mirrors `sub_40E359:12261-12278` which
    /// runs the static initializer when a class is first touched.
    pub fn clinitOffset(self: ClassRecord) u16 {
        if (self.bytes.len < 28) return 0;
        return std.mem.readInt(u16, self.bytes[26..28], .little);
    }

    /// Returns the `<clinit>` method-info, or null if the class has
    /// no static initializer.
    pub fn clinit(self: *const ClassRecord) ?MethodInfo {
        const off = self.clinitOffset();
        if (off == 0 or off + 12 > self.bytes.len) return null;
        return .{
            .class = self,
            .hash = std.mem.readInt(u32, self.bytes[off..][0..4], .little),
            .flags = std.mem.readInt(u16, self.bytes[off + 4 ..][0..2], .little),
            .arg_count = std.mem.readInt(u16, self.bytes[off + 6 ..][0..2], .little),
            .body_offset = std.mem.readInt(u16, self.bytes[off + 8 ..][0..2], .little),
        };
    }

    pub fn fieldCount(self: ClassRecord) u16 {
        const ft = self.fieldTableOffset();
        if (ft == 0 or ft + 2 > self.bytes.len) return 0;
        return std.mem.readInt(u16, self.bytes[ft..][0..2], .little);
    }

    /// Field-info records follow the same 12-byte-stride layout as
    /// method-info, starting at `(field_table_offset + 5) & ~3`.
    pub fn firstFieldInfoOffset(self: ClassRecord) usize {
        const ft = self.fieldTableOffset();
        return (ft + 5) & ~@as(usize, 3);
    }

    pub fn findField(self: *const ClassRecord, field_hash: u32) ?FieldInfo {
        const count = self.fieldCount();
        var p = self.firstFieldInfoOffset();
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            if (p + 12 > self.bytes.len) return null;
            const h = std.mem.readInt(u32, self.bytes[p..][0..4], .little);
            if (h == field_hash) {
                return .{
                    .class = self,
                    .hash = h,
                    .type_tag = std.mem.readInt(u16, self.bytes[p + 6 ..][0..2], .little),
                    .slot = std.mem.readInt(u16, self.bytes[p + 8 ..][0..2], .little),
                };
            }
            p = (p + 15) & ~@as(usize, 3);
        }
        return null;
    }

    /// Look up a method by its u32 hash. Returns the method-info as
    /// a 12-byte slice, or null. Mirrors `sub_40E747`.
    pub fn findMethod(self: *const ClassRecord, method_hash: u32) ?MethodInfo {
        const count = self.methodCount();
        var p = self.firstMethodInfoOffset();
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            if (p + 12 > self.bytes.len) return null;
            const h = std.mem.readInt(u32, self.bytes[p..][0..4], .little);
            if (h == method_hash) {
                return .{
                    .class = self,
                    .hash = h,
                    .flags = std.mem.readInt(u16, self.bytes[p + 4 ..][0..2], .little),
                    .arg_count = std.mem.readInt(u16, self.bytes[p + 6 ..][0..2], .little),
                    .body_offset = std.mem.readInt(u16, self.bytes[p + 8 ..][0..2], .little),
                };
            }
            p = (p + 15) & ~@as(usize, 3);
        }
        return null;
    }
};

/// One field-info record (12 bytes — same shape as method-info but
/// the trailing fields differ slightly per the field-access opcodes).
pub const FieldInfo = struct {
    class: *const ClassRecord,
    hash: u32,
    type_tag: u16,
    slot: u16,
};

/// One method-info record (12 bytes).
pub const MethodInfo = struct {
    class: *const ClassRecord,
    hash: u32,
    flags: u16,
    arg_count: u16,
    body_offset: u16,

    pub fn isNative(self: MethodInfo) bool {
        return (self.flags & 0x100) != 0;
    }

    /// For native methods: returns the funcs_407AA2[] index.
    pub fn nativeIndex(self: MethodInfo) u32 {
        std.debug.assert(self.isNative());
        return std.mem.readInt(u32, self.class.bytes[self.body_offset..][0..4], .little);
    }

    /// For bytecode methods: returns the body slice (6-byte header + bytecode).
    pub fn bytecodeBody(self: MethodInfo) []const u8 {
        std.debug.assert(!self.isNative());
        // Body extends to end-of-record by default; this may overshoot
        // since each body's size isn't directly stored, but the
        // interpreter halts on RETURN, so trailing bytes don't matter.
        return self.class.bytes[self.body_offset..];
    }

    pub fn maxStack(self: MethodInfo) u16 {
        std.debug.assert(!self.isNative());
        return std.mem.readInt(u16, self.class.bytes[self.body_offset..][0..2], .little);
    }

    pub fn localsCount(self: MethodInfo) u16 {
        std.debug.assert(!self.isNative());
        return std.mem.readInt(u16, self.class.bytes[self.body_offset + 2 ..][0..2], .little);
    }
};

/// Hash → ClassRecord index.
pub const Registry = struct {
    classes: std.AutoHashMap(u32, ClassRecord),
    by_index: std.AutoHashMap(u16, u32), // index → class hash
    next_index: u16 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .classes = std.AutoHashMap(u32, ClassRecord).init(allocator),
            .by_index = std.AutoHashMap(u16, u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.classes.deinit();
        self.by_index.deinit();
    }

    /// Scan a buffer for 4CVP records and register each by its class hash.
    /// Assigns sequential u16 indices in scan order — matches the
    /// order the simulator's `sub_40713F` walks built-in records.
    pub fn scanBuffer(self: *Registry, buf: []const u8, off_start: usize, origin: ClassRecord.Origin) !u32 {
        var off: usize = off_start;
        var added: u32 = 0;
        while (off + 16 <= buf.len) {
            if (!std.mem.eql(u8, buf[off..][0..4], "4CVP")) break;
            const sz = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
            if (sz < 16 or off + sz > buf.len) return Error.BadRecord;
            const hash = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
            const idx = self.next_index;
            self.next_index += 1;
            try self.classes.put(hash, .{
                .bytes = buf[off .. off + sz],
                .hash = hash,
                .index = idx,
                .origin = origin,
            });
            try self.by_index.put(idx, hash);
            added += 1;
            off = (off + sz + 3) & ~@as(usize, 3);
        }
        return added;
    }

    pub fn lookup(self: *const Registry, class_hash: u32) ?ClassRecord {
        return self.classes.get(class_hash);
    }

    pub fn lookupByIndex(self: *const Registry, idx: u16) ?ClassRecord {
        const hash = self.by_index.get(idx) orelse return null;
        return self.classes.get(hash);
    }

    /// Combined lookup: find class by hash, then find method by hash within it.
    pub fn findMethod(self: *const Registry, class_hash: u32, method_hash: u32) ?MethodInfo {
        const cls: *const ClassRecord = self.classes.getPtr(class_hash) orelse return null;
        return cls.findMethod(method_hash);
    }

    /// Resolve `class_hash`'s immediate super-class hash via the
    /// on-disk super-class index at byte +40 (see `ClassRecord.superIndex`).
    /// Returns null when the class is a root or the index is unknown.
    pub fn superHash(self: *const Registry, class_hash: u32) ?u32 {
        const rec = self.classes.getPtr(class_hash) orelse return null;
        const idx = rec.superIndex() orelse return null;
        return self.by_index.get(idx);
    }

    /// Walk the super chain starting at `recv_class_hash`, returning the
    /// most-derived method matching `method_hash`. Mirrors `sub_40DF05`
    /// (the virtual dispatcher) which walks `class -> class.super -> …`
    /// via the runtime pointer at `+16`. Falls back to a global search
    /// only if the chain produces no match (covers calls to interface
    /// defaults or to methods stored on classes we don't yet know
    /// belong on the chain).
    pub fn resolveVirtual(self: *const Registry, recv_class_hash: u32, method_hash: u32) ?MethodInfo {
        var ch: u32 = recv_class_hash;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            if (self.findMethod(ch, method_hash)) |mi| return mi;
            const next = self.superHash(ch) orelse break;
            if (next == 0 or next == ch) break;
            ch = next;
        }
        return self.findMethodAnywhere(method_hash);
    }

    /// Find a method by hash across ALL registered classes. Used as
    /// a fallback when virtual dispatch + super-chain miss (e.g. for
    /// INVOKESTATIC targeting an unrelated class).
    pub fn findMethodAnywhere(self: *const Registry, method_hash: u32) ?MethodInfo {
        var it = self.classes.iterator();
        while (it.next()) |entry| {
            const cls = entry.value_ptr;
            if (cls.findMethod(method_hash)) |mi| return mi;
        }
        return null;
    }

    /// Combined field lookup walking the actual super-class chain via
    /// the on-disk super-index at byte +40 of each class record (see
    /// `superHash`). Mirrors `sub_40DDF4` which walks `this.class` →
    /// `this.class.super` → … Falls back to a global search for fields
    /// declared on classes we can't reach via the chain (e.g. when the
    /// receiver hash itself isn't registered).
    pub fn findFieldInChain(self: *const Registry, recv_class_hash: u32, field_hash: u32) ?FieldInfo {
        var ch: u32 = recv_class_hash;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            if (self.classes.getPtr(ch)) |cls| {
                if (cls.findField(field_hash)) |fi| return fi;
            }
            const next = self.superHash(ch) orelse break;
            if (next == 0 or next == ch) break;
            ch = next;
        }
        var it = self.classes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.findField(field_hash)) |fi| return fi;
        }
        return null;
    }
};

// ── well-known hashes ─────────────────────────────────────────────────────

pub const CLASS_VM_SYS_BOOTSTRAP: u32 = 0x6551F7DC;
pub const EXEN_GAMELET_HASH: u32 = 0xE127B0E1;
pub const JAVA_LANG_OBJECT_HASH: u32 = 0x4161C4A6;

pub const METHOD_INIT: u32 = 0x35B0F11E;
pub const METHOD_TICK: u32 = 0x3F522033;
pub const METHOD_KEYPRESS: u32 = 0x305A6D35;
pub const METHOD_KEYRELEASE: u32 = 0x305A1E56;
pub const METHOD_SMSRECEIVED: u32 = 0x6F6C0565;
pub const METHOD_SMSSENT: u32 = 0x305A7631;
pub const METHOD_NICKNAMECHANGED: u32 = 0x35B0015C;
pub const METHOD_EXIT: u32 = 0x3F523566;

// ── tests ─────────────────────────────────────────────────────────────────

test "load built-in classes + find vm.sys.Bootstrap.tick" {
    const builtins = std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/unk_4494F0.bin", 1 << 20) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(builtins);

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const n = try reg.scanBuffer(builtins, 0, .builtin);
    try std.testing.expect(n > 40);

    // vm.sys.Bootstrap must be present.
    const bs = reg.lookup(CLASS_VM_SYS_BOOTSTRAP) orelse return error.MissingBootstrap;
    try std.testing.expectEqual(@as(u16, 10), bs.methodCount());

    // tick method must be findable by hash.
    const tick = reg.findMethod(CLASS_VM_SYS_BOOTSTRAP, METHOD_TICK) orelse return error.MissingTick;
    try std.testing.expect(!tick.isNative()); // tick is bytecode
    try std.testing.expectEqual(@as(u16, 0), tick.arg_count);
}

test "load gamelet classes alongside built-ins" {
    const builtins = std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/unk_4494F0.bin", 1 << 20) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(builtins);

    const exn = std.fs.cwd().readFileAlloc(std.testing.allocator, "samples/download1.exn", 1 << 20) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(exn);

    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    _ = try reg.scanBuffer(builtins, 0, .builtin);

    // For gamelet: tail starts at the sentinel of the offset table.
    // method_count at file +0x34; sentinel = entry[N] at file +0x38+4N.
    const method_count = std.mem.readInt(u32, exn[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count;
    const tail_start = std.mem.readInt(u32, exn[sentinel_off..][0..4], .little);
    const added = try reg.scanBuffer(exn, tail_start, .gamelet);
    try std.testing.expectEqual(@as(u32, 20), added); // download1 has 20 classes

    // PartEngine main class.
    const part_engine_hash: u32 = 0xB912A714;
    const pe = reg.lookup(part_engine_hash) orelse return error.MissingPartEngine;
    try std.testing.expectEqual(@as(u16, 9), pe.methodCount());
}
