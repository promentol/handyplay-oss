//! .exn gamelet file loader and method-table append.
//! Mirrors ref sub_43D57A:36969 (loader) and sub_43D350:36922 (processor).

const std = @import("std");
const vm_state = @import("../vm_state.zig");
const classfile = @import("../classfile/methods.zig");
const png = @import("../codecs/png.zig");

/// A resolved Resource slice — a byte range inside the .exn's raw
/// buffer. Mirrors what `sub_428AA0` (ref:27307) computes
/// from the simulator's "resource table" (= the class file's method
/// offset table at file offset 0x38).
pub const ResourceSlice = struct {
    offset: u32, // file offset into `raw`
    length: u32, // bytes available
};

/// Resolve a resource id to a slice of the loaded .exn. The id
/// indexes the method offset table — `cf.methods[id].offset` is the
/// resource's start, `cf.methods[id].length` is its size.
/// Returns null when the id is out of range.
///
/// Pure: doesn't read any global state. Caller passes the parsed
/// class file (which carries the method offset table) and the raw
/// .exn bytes for sanity bounds-checking.
pub fn resolveResource(cf: *const classfile.ClassFile, raw: []const u8, id: u32) ?ResourceSlice {
    if (id >= cf.method_count) return null;
    const m = cf.methods[id];
    if (m.offset > raw.len) return null;
    if (m.offset + m.length > raw.len) return null;
    return .{ .offset = m.offset, .length = m.length };
}

/// Look up the flag byte for a resource id — the simulator's
/// `sub_429813` returns this as `Resource.getResourceType()`. The
/// flag table sits right after the offset table in the .exn (one
/// byte per resource).
pub fn resourceFlag(cf: *const classfile.ClassFile, id: u32) ?u8 {
    if (id >= cf.method_count) return null;
    return cf.methods[id].flag;
}

// ── Image construction (Layer 2) ─────────────────────────────────────────
//
// Mirrors what the simulator's Image instance carries (sub_426785 +
// sub_4267F6 + sub_4265CA): dimensions, depth, optional palette,
// and the decoded ABGR raster.
//
//   width / height / depth — set by `image.Init` (native [24])
//   palette                — optional, ABGR8888 entries
//   pixels                 — ABGR8888 raster; populated by
//                            `image.TransformBitmapFromResExed`
//                            (native [26]) by decoding a PNG-format
//                            blob out of a Resource's bytes.

pub const ImageState = struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    palette: ?[]u32 = null, // owned by caller
    pixels: ?[]u32 = null, // owned by caller — ABGR8888 raster

    pub fn deinit(self: *ImageState, allocator: std.mem.Allocator) void {
        if (self.palette) |p| allocator.free(p);
        if (self.pixels) |p| allocator.free(p);
        self.palette = null;
        self.pixels = null;
    }
};

/// Initialise an `ImageState` from the dimensions native [24]
/// (image.Init) receives. Mirrors `sub_4267F6` + its callee
/// `sub_4176C7`, which just stashes the three fields on the
/// instance. No pixel allocation here — the actual raster comes
/// from `decodeImageFromResource`.
pub fn imageInit(w: u32, h: u32, depth: u32) ImageState {
    return .{ .width = w, .height = h, .depth = depth };
}

/// Decode a PNG-format image out of a Resource's current cursor
/// position into `image.pixels`. Mirrors `sub_4265CA` →
/// `sub_418D0A` → `sub_41E504` (codec dispatch in png.zig +
/// codec.zig). The caller owns the decoded buffer; pass the same
/// allocator to `ImageState.deinit` later.
///
/// Returns true on success. On failure (PNG signature not found at
/// the resource start, or codec decode fails) leaves `image.pixels`
/// untouched and returns false.
pub fn decodeImageFromResource(
    image: *ImageState,
    res: ResourceState,
    raw: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    if (res.base + res.length > raw.len) return false;
    const slice_start: usize = res.base;
    const slice_end: usize = res.base + res.length;
    // PNG signature can sit a few bytes into the resource (ExEn
    // prefixes 6 bytes of u16 w/h/idat_len for image sections, but
    // not always — scan).
    const sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    var sig_off: ?usize = null;
    var i: usize = slice_start;
    while (i + 8 <= slice_end and i + 8 <= raw.len) : (i += 1) {
        if (std.mem.eql(u8, raw[i .. i + 8], &sig)) {
            sig_off = i;
            break;
        }
    }
    const off = sig_off orelse return false;
    const decoded = png.decodePngToAbgr(allocator, raw, off) catch return false;
    // Free previous pixels if re-decoding.
    if (image.pixels) |p| allocator.free(p);
    image.pixels = decoded.pixels;
    image.width = decoded.width;
    image.height = decoded.height;
    return true;
}

/// Decode a PNG-format image directly from an in-memory byte slice into
/// `image.pixels`. byte[]-source variant of `decodeImageFromResource`,
/// used by `Image.TransformBitmapFromByteArray` (canonical sub_4266A1).
/// Returns true on success.
pub fn decodeImageFromBytes(
    image: *ImageState,
    payload: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    const sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    var sig_off: ?usize = null;
    var i: usize = 0;
    while (i + 8 <= payload.len) : (i += 1) {
        if (std.mem.eql(u8, payload[i .. i + 8], &sig)) {
            sig_off = i;
            break;
        }
    }
    const off = sig_off orelse return false;
    const decoded = png.decodePngToAbgr(allocator, payload, off) catch return false;
    if (image.pixels) |p| allocator.free(p);
    image.pixels = decoded.pixels;
    image.width = decoded.width;
    image.height = decoded.height;
    return true;
}

// ── Resource read state (Layer 1) ────────────────────────────────────────
//
// Mirrors the fields the simulator reads from a Resource instance
// (sub_428B4E / sub_428BE5 / sub_428C79 / sub_428D0D / sub_429265):
//
//   a2[6] = base (file offset into raw)
//   a2[7] = length
//   a2[8] = position (cursor)
//
// Pure read methods: read N bytes at `raw[base + position]`,
// advance position. Endianness matches the simulator EXACTLY:
//   * readShort: LE u16  (sub_428C79: 2-byte fread into __int16)
//   * readInt:   LE u32  (sub_428BE5: 4-byte fread into int)
//   * UTF length prefix: BE u16 (sub_429265: `Buffer[1] + (*Buffer << 8)`)
// On underflow (would read past the resource's length) the simulator
// stores 0 into the return slot — we mirror that with null returns.

pub const ResourceState = struct {
    base: u32,
    length: u32,
    position: u32 = 0,

    /// Build a `ResourceState` for resource `id`. Returns null when
    /// the id is out of range.
    pub fn init(cf: *const classfile.ClassFile, raw: []const u8, id: u32) ?ResourceState {
        const slice = resolveResource(cf, raw, id) orelse return null;
        return .{ .base = slice.offset, .length = slice.length, .position = 0 };
    }

    /// Bytes remaining at the current position.
    pub fn remaining(self: ResourceState) u32 {
        if (self.position >= self.length) return 0;
        return self.length - self.position;
    }

    /// Read one byte; returns null on EOF.
    pub fn readByte(self: *ResourceState, raw: []const u8) ?u8 {
        if (self.position >= self.length) return null;
        const off = self.base + self.position;
        if (off >= raw.len) return null;
        self.position += 1;
        return raw[off];
    }

    /// Read a little-endian u16 (sub_428C79). Returns null on EOF.
    pub fn readShort(self: *ResourceState, raw: []const u8) ?u16 {
        if (self.position + 2 > self.length) return null;
        const lo = self.readByte(raw) orelse return null;
        const hi = self.readByte(raw) orelse return null;
        return (@as(u16, hi) << 8) | lo;
    }

    /// Read a little-endian u32 (sub_428BE5). Returns null on EOF.
    pub fn readInt(self: *ResourceState, raw: []const u8) ?u32 {
        if (self.position + 4 > self.length) return null;
        var v: u32 = 0;
        for (0..4) |i| {
            const b = self.readByte(raw) orelse return null;
            v |= @as(u32, b) << @intCast(8 * i);
        }
        return v;
    }

    /// Copy up to `dst.len` bytes; returns the number copied. On
    /// short read, the buffer is left partially filled and position
    /// advances by the amount actually read.
    pub fn readBytes(self: *ResourceState, raw: []const u8, dst: []u8) usize {
        var n: usize = 0;
        while (n < dst.len) : (n += 1) {
            dst[n] = self.readByte(raw) orelse return n;
        }
        return n;
    }

    /// Read a Java-style modified-UTF8 string: a 2-byte big-endian
    /// length followed by `len` bytes. Returns null on EOF or bad
    /// length. Caller owns the returned slice.
    pub fn readUTF(self: *ResourceState, raw: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        if (self.position + 2 > self.length) return null;
        const hi = self.readByte(raw) orelse return null;
        const lo = self.readByte(raw) orelse return null;
        const len: u32 = (@as(u32, hi) << 8) | lo;
        if (len > self.remaining()) return null;
        const bytes = try allocator.alloc(u8, len);
        const got = self.readBytes(raw, bytes);
        if (got != len) {
            allocator.free(bytes);
            return null;
        }
        return bytes;
    }
};

pub const Error = error{
    NotAnExnFile,
    NameNotTerminated,
    MethodTableOverflow,
    BadOffsetTable,
};

// ── .exn file layout ──────────────────────────────────────────────────────
//
// Header (48 bytes):
//   +0x00..+0x04  magic "NEXE"
//   +0x04..+0x08  u32 = 0x80 in TheTerminator.exn — purpose TBD; possibly a
//                 fixed header-field tag or a class-count. Same value in
//                 every gamelet observed so far. Documented as `tag_04`.
//   +0x08..+0x0E  three (u16, u16) pairs — heuristically `(blocks, size)` per
//                 memory tier; observed values for TheTerminator.exn:
//                   (0x0200, 0x2000), (0x0400, 0x3000), (0x0800, 0x6000)
//                 Names follow the INI's `EXEN_VM_BLOCKS_*` / `_SIZE_*` keys.
//   +0x14..+0x30  zero-padded gamelet name. Format `<filestem>.<classname>`,
//                 e.g. "TheTerminator.GameTopLevel". sub_43D57A:36999-37003
//                 only reads up to the first '.'.
//
// Top-level offset table (starts at +0x30):
//   Entries are u32 LE file offsets. Entry 0 is always 0 (sentinel). The
//   table ends just before the byte pointed to by entry 1 — i.e. the first
//   real section starts immediately after the table. Number of entries =
//   (entry1_value - 0x30) / 4. For TheTerminator.exn that's
//   (0xA0 - 0x30) / 4 = 28 (including the sentinel).
//
// Sections (each pointed to by a non-zero table entry):
//   - Image:   u16 width, u16 height, u16 idat_len, 8-byte PNG signature,
//              PNG-style chunks (length-BE | type | data, no trailing CRC).
//              Decoder in extract_pngs.zig handles the IDAT.
//   - Text:    sequence of null/0xFF-separated UTF-8 strings (e.g. "Score",
//              "Niveau:" in TheTerminator.exn section 13).
//   - Subtable: another monotonic u32-LE offset list pointing further into
//              the file (typical for section 1).
//   - Opaque:  bytecode / animation tracks (e.g. section 11). Identification
//              is deferred until a handler interprets it.

pub const SectionKind = enum {
    image,         // PNG with the 6-byte ExEn prefix
    subtable,      // monotonic u32-LE entries
    text,          // mostly printable bytes
    opaque_data,
};

pub const SectionInfo = struct {
    index: u32,
    offset: u32,
    length: u32,     // computed: next section's offset minus this one's
    kind: SectionKind,
};

pub const ExnLayout = struct {
    tag_04: u32,
    tiers: [3]struct { blocks: u16, size: u16 },
    section_count: u32,                 // includes the leading 0 sentinel
    sections: []SectionInfo,            // owned by `allocator`
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExnLayout) void {
        self.allocator.free(self.sections);
    }
};

pub const ExnFile = struct {
    raw: []u8,             // owned full file contents
    name: []const u8,      // slice into raw — gamelet name (no terminator)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExnFile) void {
        self.allocator.free(self.raw);
    }
};

/// Read an .exn file from disk, validate the magic, extract the gamelet name.
/// Port of sub_43D57A:36990-37009.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !ExnFile {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    errdefer allocator.free(raw);

    if (raw.len < 24) return Error.NotAnExnFile;

    // Magic check — sub_43D57A:37006-37009.
    // The C compares byte-by-byte: [3]=='E', [2]=='X', [1]=='E', [0]=='N'.
    if (!(raw[0] == 'N' and raw[1] == 'E' and raw[2] == 'X' and raw[3] == 'E')) {
        return Error.NotAnExnFile;
    }

    // Name extraction — sub_43D57A:36999-37003.
    // Starting at offset 20, scan forward for '.' (ASCII 46) OR '\0';
    // the name spans bytes 20..i. The trailing byte is restored after
    // the strcpy in C, so the raw buffer is unchanged from disk.
    var i: usize = 20;
    while (i < raw.len and raw[i] != '.' and raw[i] != 0) : (i += 1) {}
    if (i >= raw.len) return Error.NameNotTerminated;

    return .{
        .raw = raw,
        .name = raw[20..i],
        .allocator = allocator,
    };
}

// ── struct layouts (recovered from ref) ────────────────────────────

/// Parse the top-level offset table and classify each section.
pub fn parseLayout(allocator: std.mem.Allocator, raw: []const u8) !ExnLayout {
    if (raw.len < 0x34) return Error.BadOffsetTable;

    // First non-sentinel entry tells us how big the table is.
    const first = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    if (first <= 0x34 or first > raw.len or (first & 3) != 0) return Error.BadOffsetTable;
    const section_count: u32 = @intCast((first - 0x30) / 4);
    if (section_count < 2 or section_count > 1024) return Error.BadOffsetTable;

    // Read the entries.
    var entries = try allocator.alloc(u32, section_count);
    defer allocator.free(entries);
    var i: u32 = 0;
    while (i < section_count) : (i += 1) {
        const eoff = 0x30 + 4 * @as(usize, i);
        if (eoff + 4 > raw.len) return Error.BadOffsetTable;
        entries[i] = std.mem.readInt(u32, raw[eoff..][0..4], .little);
    }
    // Sanity: entry[0] must be 0 (sentinel); entries[1..] must be monotonic and within file.
    if (entries[0] != 0) return Error.BadOffsetTable;
    var prev: u32 = 0;
    var k: u32 = 1;
    while (k < section_count) : (k += 1) {
        const v = entries[k];
        if (v <= prev or v > raw.len) return Error.BadOffsetTable;
        prev = v;
    }

    // Build SectionInfo entries (skip the sentinel).
    const real_count = section_count - 1;
    const sections = try allocator.alloc(SectionInfo, real_count);
    errdefer allocator.free(sections);
    var j: u32 = 0;
    while (j < real_count) : (j += 1) {
        const sec_off = entries[j + 1];
        const next_off: u32 = if (j + 2 < section_count) entries[j + 2] else @intCast(raw.len);
        const sec_len = next_off - sec_off;
        sections[j] = .{
            .index = j + 1,
            .offset = sec_off,
            .length = sec_len,
            .kind = classify(raw, sec_off, sec_len),
        };
    }

    return .{
        .tag_04 = std.mem.readInt(u32, raw[0x04..][0..4], .little),
        .tiers = .{
            .{
                .blocks = std.mem.readInt(u16, raw[0x08..][0..2], .little),
                .size = std.mem.readInt(u16, raw[0x0A..][0..2], .little),
            },
            .{
                .blocks = std.mem.readInt(u16, raw[0x0C..][0..2], .little),
                .size = std.mem.readInt(u16, raw[0x0E..][0..2], .little),
            },
            .{
                .blocks = std.mem.readInt(u16, raw[0x10..][0..2], .little),
                .size = std.mem.readInt(u16, raw[0x12..][0..2], .little),
            },
        },
        .section_count = section_count,
        .sections = sections,
        .allocator = allocator,
    };
}

/// Heuristic section classifier. Reads the first few bytes and looks for
/// known signatures.
fn classify(raw: []const u8, off: u32, len: u32) SectionKind {
    if (len == 0) return .opaque_data;
    const end = @min(@as(usize, off) + @as(usize, len), raw.len);
    const body = raw[off..end];

    // PNG: ExEn prefixes 6 bytes (w, h, len) then the 8-byte PNG signature.
    const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (body.len >= 14 and std.mem.eql(u8, body[6..14], &png_sig)) return .image;

    // Subtable: dense monotonic u32-LE entries occupying most of the section.
    if (looksLikeSubtable(body, raw.len)) return .subtable;

    // Text: mostly printable ASCII with no NULs in the leading 32 bytes.
    if (looksLikeText(body)) return .text;

    return .opaque_data;
}

fn looksLikeSubtable(body: []const u8, file_len: usize) bool {
    if (body.len < 16) return false;
    var off: usize = 0;
    var prev: u32 = 0;
    var n: u32 = 0;
    while (off + 4 <= body.len and n < 16) : (off += 4) {
        const v = std.mem.readInt(u32, body[off..][0..4], .little);
        if (v == 0 or v <= prev or v >= file_len) return false;
        prev = v;
        n += 1;
    }
    return n >= 4;
}

fn looksLikeText(body: []const u8) bool {
    // ExEn text tables typically start with a u32 length, then UTF-8 strings
    // separated by 0xFF terminators (see TheTerminator.exn section @0x3304:
    // "Choix\xFFdu\xFFniveau\xFFScore\xFF..."). Probe past any length prefix.
    if (body.len < 16) return false;
    const start: usize = if (body.len >= 4 and body[1] == 0 and body[2] == 0 and body[3] == 0) 4 else 0;
    const probe = body[start..@min(body.len, start + 48)];
    if (probe.len < 8) return false;
    var printable: usize = 0;
    for (probe) |b| {
        if ((b >= 32 and b < 127) or b == 0xFF) printable += 1;
    }
    return printable * 5 >= probe.len * 4; // ≥80% printable-or-separator
}

/// 580-byte gamelet header (`v8[290]` in sub_43D57A, `a1` in sub_43D350).
pub const GameletHeader = extern struct {
    bytes: [580]u8,
    pub const size: usize = 580;
    comptime {
        std.debug.assert(@sizeOf(GameletHeader) == size);
    }
};

/// Metadata prefix written by sub_43D350:36945-36949 (the `v4[7]` table).
pub const GameletMeta = extern struct {
    reserved0: u32,        // +0
    original_size: u32,    // +4  the .exn file's byte size
    record_size: u32,      // +8  always 608 — used by the walk loop in sub_43D350:36960
    default_file_id: u32,  // +12 atoi("[SmsServerConfig] DefaultFileID"), default 128
    reserved4: u32,        // +16
    state_flag_a: u32,     // +20 = 2
    state_flag_b: u32,     // +24 = 1
    comptime {
        std.debug.assert(@sizeOf(GameletMeta) == 28);
    }
};

/// 608-byte gamelet record (0x260) appended to VmState.bytes[548+].
pub const GameletRecord = extern struct {
    meta: GameletMeta,        // +0..28
    header: GameletHeader,    // +28..608
    pub const size: usize = 608;
    comptime {
        std.debug.assert(@sizeOf(GameletRecord) == size);
    }
};

// ── append-to-VmState ──────────────────────────────────────────────────────

/// Build a GameletRecord from an ExnFile and append it to the VM's method
/// table. Port of the relevant slice of sub_43D350:36945-36963.
///
/// This is a minimal milestone implementation: we record metadata
/// (file size, default_file_id, state flags) but do not yet do the
/// 66-byte template merge from `unk_45E7C8` or the checksum at
/// header+8 (sub_43D350:36950, 36954) — those are out of scope until
/// a handler actually reads them.
pub fn appendGamelet(
    vm: *vm_state.VmState,
    exn: *const ExnFile,
    default_file_id: u32,
) !void {
    var rec: GameletRecord = std.mem.zeroes(GameletRecord);
    rec.meta = .{
        .reserved0 = 0,
        .original_size = @intCast(exn.raw.len),
        .record_size = GameletRecord.size,
        .default_file_id = default_file_id,
        .reserved4 = 0,
        .state_flag_a = 2,
        .state_flag_b = 1,
    };
    // Copy the gamelet name into the header's name slot (offset 12, see
    // GameletHeader layout — sub_43D57A:37003 writes into v8[6] = offset 12).
    const name_off: usize = 12;
    const max_name = GameletHeader.size - name_off - 1;
    const n = @min(exn.name.len, max_name);
    @memcpy(rec.header.bytes[name_off .. name_off + n], exn.name[0..n]);
    rec.header.bytes[name_off + n] = 0;

    // Walk to the end of the existing method table (sub_43D350:36958-36961).
    var off: usize = vm_state.VmState.off_method_table;
    var i: u16 = 0;
    while (i < vm.methodCount()) : (i += 1) {
        if (off + 12 > vm.bytes.len) return Error.MethodTableOverflow;
        const entry_size = std.mem.readInt(u32, vm.bytes[off + 8 ..][0..4], .little);
        if (entry_size == 0) break; // defensive
        off += entry_size;
    }
    if (off + GameletRecord.size > vm.bytes.len) return Error.MethodTableOverflow;

    const rec_bytes = std.mem.asBytes(&rec);
    @memcpy(vm.bytes[off .. off + GameletRecord.size], rec_bytes);
    vm.setMethodCount(vm.methodCount() + 1);
}

test "load TheTerminator.exn (if present)" {
    var exn = load(std.testing.allocator, "TheTerminator.exn") catch |err| {
        // Skip the test if the file isn't in the cwd.
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer exn.deinit();

    try std.testing.expectEqualStrings("TheTerminator", exn.name);
    try std.testing.expect(exn.raw.len > 100);
}

test "imageInit stashes dimensions" {
    const img = imageInit(90, 81, 4);
    try std.testing.expectEqual(@as(u32, 90), img.width);
    try std.testing.expectEqual(@as(u32, 81), img.height);
    try std.testing.expectEqual(@as(u32, 4), img.depth);
    try std.testing.expectEqual(@as(?[]u32, null), img.pixels);
}

test "decodeImageFromResource reads resource 0 of TheTerminator" {
    // Layer 2 deliverable: real PNG decode from a Resource's bytes.
    // Resource 0 of TheTerminator.exn is a 90x81 codec-5 PNG sitting
    // at file offset 0x362 (= resource base 0x35C + 6-byte ExEn
    // prefix). After decoding, `image.pixels` should hold 90*81 =
    // 7290 ABGR8888 pixels.
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "TheTerminator.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try classfile.parse(std.testing.allocator, raw);
    defer cf.deinit();

    const res = ResourceState.init(&cf, raw, 0) orelse return error.TestUnexpectedResult;

    var img = imageInit(0, 0, 0); // will be filled by decode
    const ok = try decodeImageFromResource(&img, res, raw, std.testing.allocator);
    defer img.deinit(std.testing.allocator);

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 90), img.width);
    try std.testing.expectEqual(@as(u32, 81), img.height);
    try std.testing.expect(img.pixels != null);
    try std.testing.expectEqual(@as(usize, 90 * 81), img.pixels.?.len);
}

test "ResourceState read* matches python3-extracted expectations" {
    // Layer 1 deliverable: pure read methods verified against
    // independently-extracted bytes of TheTerminator.exn resource 9.
    // Reference (first 16 bytes of resource 9 at file 0x314c):
    //   0a 00 00 00 7f 02 00 02 02 04 01 03 03 03 00 00
    // Expected reads from position 0:
    //   readByte  -> 0x0a  (pos = 1)
    //   readShort -> 0x0000 LE       (pos = 3)
    //   readInt   -> 0x00027f00 LE   (pos = 7)
    //   readBytes(5) -> 02 02 04 01 03   (pos = 12)
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "TheTerminator.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try classfile.parse(std.testing.allocator, raw);
    defer cf.deinit();

    var st = ResourceState.init(&cf, raw, 9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x314C), st.base);
    try std.testing.expectEqual(@as(u32, 16), st.length);
    try std.testing.expectEqual(@as(u32, 0), st.position);

    try std.testing.expectEqual(@as(?u8, 0x0a), st.readByte(raw));
    try std.testing.expectEqual(@as(u32, 1), st.position);

    try std.testing.expectEqual(@as(?u16, 0x0000), st.readShort(raw));
    try std.testing.expectEqual(@as(u32, 3), st.position);

    try std.testing.expectEqual(@as(?u32, 0x00027F00), st.readInt(raw));
    try std.testing.expectEqual(@as(u32, 7), st.position);

    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), st.readBytes(raw, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x02, 0x04, 0x01, 0x03 }, &buf);
    try std.testing.expectEqual(@as(u32, 12), st.position);

    // EOF: reading past length returns null and doesn't advance.
    var tail: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), st.readBytes(raw, &tail));
    try std.testing.expectEqual(@as(u32, 16), st.position);
    try std.testing.expectEqual(@as(?u8, null), st.readByte(raw));
}

test "resourceFlag returns the classfile flag byte" {
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "TheTerminator.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try classfile.parse(std.testing.allocator, raw);
    defer cf.deinit();

    // The flag byte for resource 9 — read directly from the .exn
    // (flag table starts at 0x38 + 4*(method_count+1) = 0x38 + 644 = 0x2BC for 160 methods).
    const flag_table_off: usize = 0x38 + 4 * (@as(usize, cf.method_count) + 1);
    const expected_flag = raw[flag_table_off + 9];
    try std.testing.expectEqual(@as(?u8, expected_flag), resourceFlag(&cf, 9));
    try std.testing.expectEqual(@as(?u8, null), resourceFlag(&cf, cf.method_count));
}

test "resolveResource returns same bytes as a xxd-extracted slice" {
    // Layer 0 deliverable: an id → byte-range resolver, validated
    // against an independently-computed slice of TheTerminator.exn.
    // Reference values were extracted via `python3` reading the
    // method offset table at file offset 0x38 (see Layer 0 plan).
    const raw = std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "TheTerminator.exn",
        64 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(raw);

    var cf = try classfile.parse(std.testing.allocator, raw);
    defer cf.deinit();

    // Resource 0: starts at 0x35C, length 2128.
    const r0 = resolveResource(&cf, raw, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x35C), r0.offset);
    try std.testing.expectEqual(@as(u32, 2128), r0.length);
    // First byte is 0x5a (matches python3-extracted bytes).
    try std.testing.expectEqual(@as(u8, 0x5a), raw[r0.offset]);

    // Resource 9: starts at 0x314C, length 16.
    const r9 = resolveResource(&cf, raw, 9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x314C), r9.offset);
    try std.testing.expectEqual(@as(u32, 16), r9.length);
    // First 4 bytes: 0a 00 00 00 — matches xxd dump.
    try std.testing.expectEqual(@as(u8, 0x0a), raw[r9.offset]);
    try std.testing.expectEqual(@as(u8, 0x00), raw[r9.offset + 1]);

    // Out-of-range id returns null.
    try std.testing.expectEqual(@as(?ResourceSlice, null), resolveResource(&cf, raw, 9999));
    try std.testing.expectEqual(@as(?ResourceSlice, null), resolveResource(&cf, raw, cf.method_count));
}

test "parseLayout against TheTerminator.exn (if present)" {
    var exn = load(std.testing.allocator, "TheTerminator.exn") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer exn.deinit();

    var layout = try parseLayout(std.testing.allocator, exn.raw);
    defer layout.deinit();

    try std.testing.expectEqual(@as(u32, 0x80), layout.tag_04);
    // 28 entries including sentinel → 27 real sections.
    try std.testing.expectEqual(@as(u32, 28), layout.section_count);
    try std.testing.expectEqual(@as(usize, 27), layout.sections.len);

    // First section starts at 0xA0 and is the subtable.
    try std.testing.expectEqual(@as(u32, 0xA0), layout.sections[0].offset);
    try std.testing.expectEqual(SectionKind.subtable, layout.sections[0].kind);

    // Second section is the first PNG image at 0x35C.
    try std.testing.expectEqual(@as(u32, 0x35C), layout.sections[1].offset);
    try std.testing.expectEqual(SectionKind.image, layout.sections[1].kind);

    // Sections 12 (index 12 → entry 13) holds the French text strings starting
    // with "Choix du niveau".
    var found_text = false;
    for (layout.sections) |s| {
        if (s.kind == .text and std.mem.indexOf(u8, exn.raw[s.offset..][0..@min(64, s.length)], "Choix") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);

    // Memory tiers: (0x0200, 0x2000), (0x0400, 0x3000), (0x0800, 0x6000).
    try std.testing.expectEqual(@as(u16, 0x0200), layout.tiers[0].blocks);
    try std.testing.expectEqual(@as(u16, 0x2000), layout.tiers[0].size);
    try std.testing.expectEqual(@as(u16, 0x6000), layout.tiers[2].size);
}

test "magic-check rejects garbage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bad.exn", .data = "XXXX................name." });

    var path_buf: [256]u8 = undefined;
    const path = try tmp.dir.realpath("bad.exn", &path_buf);

    try std.testing.expectError(Error.NotAnExnFile, load(std.testing.allocator, path));
}

test "appendGamelet grows method table" {
    var vm: vm_state.VmState = undefined;
    vm.initBlank();
    try std.testing.expectEqual(@as(u16, 0), vm.methodCount());

    var fake_exn = ExnFile{
        .raw = @constCast("NEXE................TestGame.payload"),
        .name = "TestGame",
        .allocator = undefined,
    };
    try appendGamelet(&vm, &fake_exn, 128);
    try std.testing.expectEqual(@as(u16, 1), vm.methodCount());

    // First entry sits at offset 548 with record_size at +8 = 608.
    const off = vm_state.VmState.off_method_table;
    try std.testing.expectEqual(
        @as(u32, GameletRecord.size),
        std.mem.readInt(u32, vm.bytes[off + 8 ..][0..4], .little),
    );
    // Name should be at off + 28 (record meta) + 12 (header name_off).
    try std.testing.expectEqualStrings("TestGame", vm.bytes[off + 28 + 12 ..][0..8]);

    // Append a second record; method count = 2, second record at off + 608.
    try appendGamelet(&vm, &fake_exn, 128);
    try std.testing.expectEqual(@as(u16, 2), vm.methodCount());
}
