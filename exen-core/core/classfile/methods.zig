//! Class file parser — Stage 2 of the execution chain (see
//! `docs/execution.md` and `docs/classfile.md`). Reads a `.exn`'s
//! 56-byte class header, the method-offset table at +0x38, the flag
//! table after it, and identifies any `PATC` entries embedded as
//! 8-byte "methods" with flag `0x20`.
//!
//! This is the on-disk-layout layer. It does not allocate VM objects
//! or hash method names — that's the loader's job (next stage).

const std = @import("std");

pub const Error = error{
    NotAnExnFile,
    BadHeader,
    BadMethodCount,
    BadMethodOffset,
    Truncated,
};

/// Per-method record in the parsed class file.
pub const Method = struct {
    /// File offset of the start of the method's body (the 6-byte
    /// header is `body[0..6]`, bytecode starts at `body[6]`).
    offset: u32,
    /// Length in bytes (from this method's offset to the next
    /// method's offset, or end-of-file for the last method).
    length: u32,
    /// Method-flag byte. Bit `0x20` (== ASCII space) marks PATC
    /// entries; bit `0x100` would mark NATIVE (per the resolver in
    /// `sub_40E02C`), but that's a method-info field, not a class-file
    /// flag — TBD whether it appears here too.
    flag: u8,
    /// True if this entry is a PATC record (`flag == 0x20` and
    /// `length == 8`).
    is_patc: bool,
};

pub const ClassFile = struct {
    name: []const u8,        // borrowed slice of `raw`
    method_count: u32,
    methods: []Method,
    allocator: std.mem.Allocator,
    raw: []const u8,         // borrowed (caller owns)

    pub fn deinit(self: *ClassFile) void {
        self.allocator.free(self.methods);
    }

    /// Body slice (6-byte header + bytecode) for a given method index.
    pub fn methodBody(self: *const ClassFile, idx: usize) []const u8 {
        const m = self.methods[idx];
        return self.raw[m.offset .. m.offset + m.length];
    }

    /// Bytecode-only slice (skips the 6-byte method header).
    pub fn methodBytecode(self: *const ClassFile, idx: usize) []const u8 {
        const m = self.methods[idx];
        return self.raw[m.offset + 6 .. m.offset + m.length];
    }

    /// Read the 6-byte per-method header for a given method index.
    /// Returns (locals_count, max_stack, flags_or_etable).
    pub fn methodHeader(self: *const ClassFile, idx: usize) struct {
        locals: u16,
        stack: u16,
        extra: u16,
    } {
        const m = self.methods[idx];
        return .{
            .locals = std.mem.readInt(u16, self.raw[m.offset..][0..2], .little),
            .stack = std.mem.readInt(u16, self.raw[m.offset + 2 ..][0..2], .little),
            .extra = std.mem.readInt(u16, self.raw[m.offset + 4 ..][0..2], .little),
        };
    }
};

/// Parse a `.exn`'s class file out of an in-memory buffer.
///
/// Layout (verified for TheTerminator.exn; see classfile.md):
///
/// ```
/// 0x00..0x04  "NEXE"
/// 0x04..0x08  tag_04 (== 0x80; purpose TBD)
/// 0x08..0x14  three (u16 blocks, u16 size) memory-tier pairs
/// 0x14..0x35  zero-padded "<filestem>.<classname>"
/// 0x30..0x34  reserved
/// 0x34..0x38  u32 method_count (N)            ← 0xA0 = 160 for TheTerminator
/// 0x38..0x38+4(N+1)  u32 method_offset[N+1]   ← last is end-of-data sentinel
/// next:               u8  method_flag[N]
/// next:               PATC entries (each is itself a "method" with flag 0x20 and size 8)
/// rest:               method bodies (each 6-byte header + bytecode/data)
/// ```
///
/// "Method" here is the simulator's term — entries in the table can
/// also be raw resource blobs (PNGs, text). Bytecode methods are
/// identified by their 6-byte header `(locals, max_stack, ?)` and
/// the absence of a PNG signature at body[6..14].
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !ClassFile {
    if (raw.len < 0x38) return Error.BadHeader;
    if (!(raw[0] == 'N' and raw[1] == 'E' and raw[2] == 'X' and raw[3] == 'E')) {
        return Error.NotAnExnFile;
    }

    var name_end: usize = 0x14;
    while (name_end < raw.len and raw[name_end] != '.' and raw[name_end] != 0) : (name_end += 1) {}
    const name = raw[0x14..name_end];

    // Method count = u32 at +0x34. Offset table has (N+1) entries:
    // entry[N] is the end-of-data sentinel.
    const method_count = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    if (method_count == 0 or method_count > 65536) return Error.BadMethodCount;

    const offsets_bytes: u32 = 4 * (method_count + 1);
    if (0x38 + offsets_bytes + method_count > raw.len) return Error.Truncated;
    const flags_off: u32 = 0x38 + offsets_bytes;

    const methods = try allocator.alloc(Method, method_count);
    errdefer allocator.free(methods);

    var i: u32 = 0;
    while (i < method_count) : (i += 1) {
        const off = std.mem.readInt(u32, raw[0x38 + 4 * i ..][0..4], .little);
        const nxt = std.mem.readInt(u32, raw[0x38 + 4 * (i + 1) ..][0..4], .little);
        if (off > raw.len or nxt > raw.len or nxt < off) return Error.BadMethodOffset;
        methods[i].offset = off;
        methods[i].length = nxt - off;

        const f = raw[flags_off + i];
        methods[i].flag = f;
        methods[i].is_patc = (f == 0x20 and methods[i].length == 8 and
            std.mem.eql(u8, raw[off..][0..4], "PATC"));
    }

    return .{
        .name = name,
        .method_count = method_count,
        .methods = methods,
        .allocator = allocator,
        .raw = raw,
    };
}

test "parse TheTerminator.exn class file (if present)" {
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "TheTerminator.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try parse(std.testing.allocator, raw);
    defer cf.deinit();

    try std.testing.expectEqualStrings("TheTerminator", cf.name);
    try std.testing.expectEqual(@as(u32, 160), cf.method_count);
    try std.testing.expectEqual(@as(u32, 0x35C), cf.methods[0].offset);
}

test "parse download1.exn class file (if present)" {
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "download1.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try parse(std.testing.allocator, raw);
    defer cf.deinit();

    try std.testing.expectEqualStrings("PartEngine", cf.name);
    try std.testing.expectEqual(@as(u32, 26), cf.method_count);
    try std.testing.expectEqual(@as(u32, 0xC0), cf.methods[0].offset);
    // Sentinel = end of method bodies = start of tail 4CVP records.
    try std.testing.expectEqual(@as(u32, 0x6CB0), cf.methods[25].offset + cf.methods[25].length);
}
