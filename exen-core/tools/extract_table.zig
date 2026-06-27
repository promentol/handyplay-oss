//! Comprehensive 4CVP-record dumper. Reads assets/unk_4494F0.bin and
//! emits docs/extracted_table.md with every header field, field-info,
//! method-info, and decoded signature for all 54 built-in classes.
//!
//! Run:  zig run tools/extract_table.zig

const std = @import("std");

const CLASS_NAMES = [_]struct { hash: u32, name: []const u8 }{
    .{ .hash = 0x335fb0fe, .name = "exen.Animation" },
    .{ .hash = 0xc6ed8e2a, .name = "exen.Graphics" },
    .{ .hash = 0x23c5e7e8, .name = "exen.Image" },
    .{ .hash = 0x3834a617, .name = "exen.TextureMap" },
    .{ .hash = 0xf214cebb, .name = "exen.Rectangle" },
    .{ .hash = 0x5562ca3b, .name = "exen.Palette" },
    .{ .hash = 0xbab5c664, .name = "exen.Resource" },
    .{ .hash = 0xe7167d52, .name = "exen.AnimBitmap" },
    .{ .hash = 0x7219d0b4, .name = "exen.PlayField" },
    .{ .hash = 0x60fe5152, .name = "exen.Sprite" },
    .{ .hash = 0xd414954a, .name = "exen.AnimFlash" },
    .{ .hash = 0x1c4d8791, .name = "exen.Command" },
    .{ .hash = 0xd4a75556, .name = "exen.CommandListener" },
    .{ .hash = 0x02255f70, .name = "exen.Displayable" },
    .{ .hash = 0xe127b0e1, .name = "exen.Gamelet" },
    .{ .hash = 0xf7f39575, .name = "exen.Component" },
    .{ .hash = 0x6bddc5b7, .name = "exen.Sms" },
    .{ .hash = 0xb6ee3b2a, .name = "exen.DialogBox" },
    .{ .hash = 0xd8f81132, .name = "exen.FX" },
    .{ .hash = 0x3c0c89c6, .name = "exen.GameletEnhanced" },
    .{ .hash = 0xdf774e57, .name = "exen.List" },
    .{ .hash = 0x3298b202, .name = "exen.Math" },
    .{ .hash = 0x8f9e8280, .name = "exen.Matrix3D" },
    .{ .hash = 0xe36f9667, .name = "exen.Vector3D" },
    .{ .hash = 0x36a7404d, .name = "exen.Palette_RAW" },
    .{ .hash = 0x9ac35be7, .name = "exen.Point2D" },
    .{ .hash = 0xd0c31058, .name = "exen.RawData" },
    .{ .hash = 0xd0b8e4ac, .name = "exen.RayCast" },
    .{ .hash = 0x11749d8a, .name = "exen.util.Debug" },
    .{ .hash = 0x4161c4a6, .name = "java.lang.Object" },
    .{ .hash = 0x42816699, .name = "java.lang.Class" },
    .{ .hash = 0x72737f61, .name = "java.lang.Exception" },
    .{ .hash = 0xb00cb273, .name = "java.lang.Throwable" },
    .{ .hash = 0x7772dde3, .name = "java.lang.String" },
    .{ .hash = 0xb21fbad6, .name = "java.lang.ClassLoader" },
    .{ .hash = 0x47cb31c2, .name = "java.lang.StringBuffer" },
    .{ .hash = 0x20817ec1, .name = "java.lang.System" },
    .{ .hash = 0xf217c377, .name = "java.lang.Error" },
    .{ .hash = 0x1c65ec89, .name = "java.lang.Boolean" },
    .{ .hash = 0x5da4d0c7, .name = "java.lang.Byte" },
    .{ .hash = 0x9ec04138, .name = "java.lang.Character" },
    .{ .hash = 0x2b927978, .name = "java.lang.Cloneable" },
    .{ .hash = 0xefac077f, .name = "java.lang.CloneNotSupportedException" },
    .{ .hash = 0xccefcfea, .name = "java.lang.Integer" },
    .{ .hash = 0xfbf3e3c1, .name = "java.lang.Long" },
    .{ .hash = 0xf2f8aa1c, .name = "java.lang.OutOfMemoryError" },
    .{ .hash = 0x62caf278, .name = "java.lang.VirtualMachineError" },
    .{ .hash = 0x20e2efa4, .name = "java.lang.Short" },
    .{ .hash = 0xf050084a, .name = "java.io.Serializable" },
    .{ .hash = 0xb4f0ccbf, .name = "vm.sys.Runtime" },
    .{ .hash = 0x1a8f99cc, .name = "vm.sys.Application" },
    .{ .hash = 0x6551f7dc, .name = "vm.sys.Bootstrap" },
    .{ .hash = 0xbbd967f9, .name = "catalog.Catalog" },
    .{ .hash = 0xdd22a4ed, .name = "catalog.GameProperty" },
};

fn className(hash: u32) []const u8 {
    for (CLASS_NAMES) |c| if (c.hash == hash) return c.name;
    return "<unknown>";
}

const NameEntry = struct { off: usize, name: []const u8, sig_start: usize, sig_end: usize };

fn isValidNameByte(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or c == '$' or c == '<' or c == '>';
}

fn collectNames(rec: []const u8, alloc: std.mem.Allocator, cls_short: []const u8) !std.ArrayList(NameEntry) {
    var raw = std.ArrayList(NameEntry).empty;
    var i: usize = 36;
    while (i + 2 <= rec.len) {
        const namelen: u16 = @as(u16, rec[i]) | (@as(u16, rec[i + 1]) << 8);
        if (namelen >= 2 and namelen <= 40 and i + 2 + namelen <= rec.len) {
            const name = rec[i + 2 ..][0..namelen];
            var valid = true;
            for (name) |c| if (!isValidNameByte(c)) { valid = false; break; };
            const first_ok = name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '<' or name[0] == '_');
            if (valid and first_ok) {
                if (!std.mem.eql(u8, name, cls_short))
                    try raw.append(alloc, .{ .off = i, .name = name, .sig_start = i + 2 + namelen, .sig_end = 0 });
                i += 2 + namelen;
                continue;
            }
        }
        i += 1;
    }
    // sig_end of entry k is the start of entry k+1, or end of strings region.
    // The strings region ends at the field_table or method_table, whichever is
    // first non-zero.
    const ft = std.mem.readInt(u16, rec[30..][0..2], .little);
    const mt = std.mem.readInt(u16, rec[32..][0..2], .little);
    var strings_end: usize = rec.len;
    if (ft != 0 and ft < strings_end) strings_end = ft;
    if (mt != 0 and mt < strings_end) strings_end = mt;
    for (raw.items, 0..) |*e, idx| {
        e.sig_end = if (idx + 1 < raw.items.len) raw.items[idx + 1].off else strings_end;
    }
    return raw;
}

pub const ParsedSig = struct {
    ret_type: u16,
    argc: u16,
    arg_types: []u16,
};

/// Parse ONE signature record starting at `pos`. Returns the parsed
/// signature and updates `*pos` to point past it (so the caller can
/// keep reading the next overload). Returns null on parse failure
/// or back-ref mismatch.
///
/// Empirical format (verified across Animation/Bootstrap/Graphics/Image):
///   [optional 1 align byte if pos is odd at entry]
///   u32 back_ref     (== expected name offset)
///   u16 head_ret     (return type when argc==0; 0 placeholder otherwise)
///   u16 argc
///   argc × u16 type tags    (arg types, INCLUDING `this` for instance methods)
///   [u16 tail_ret if argc > 0]   (return type when argc>0)
///
/// We use head_ret when argc==0, tail_ret when argc>0. This is the only
/// layout that consistently matches all overload back-refs aligning at
/// the right offsets.
fn parseOneSig(rec: []const u8, pos: *usize, sig_end: usize, name_off: usize, alloc: std.mem.Allocator) !?ParsedSig {
    if (pos.* & 1 != 0 and pos.* + 1 <= sig_end) pos.* += 1;
    if (pos.* + 8 > sig_end) return null;
    const back_ref = std.mem.readInt(u32, rec[pos.*..][0..4], .little);
    if (back_ref != name_off) return null;
    pos.* += 4;
    const head_ret = std.mem.readInt(u16, rec[pos.*..][0..2], .little);
    pos.* += 2;
    const argc = std.mem.readInt(u16, rec[pos.*..][0..2], .little);
    pos.* += 2;
    if (argc > 64) return null;
    if (pos.* + @as(usize, argc) * 2 > sig_end) return null;
    const args = try alloc.alloc(u16, argc);
    for (0..argc) |k| {
        args[k] = std.mem.readInt(u16, rec[pos.* + k * 2 ..][0..2], .little);
    }
    pos.* += argc * 2;
    var ret = head_ret;
    if (argc > 0 and pos.* + 2 <= sig_end) {
        ret = std.mem.readInt(u16, rec[pos.*..][0..2], .little);
        pos.* += 2;
    }
    return ParsedSig{ .ret_type = ret, .argc = argc, .arg_types = args };
}

/// Parse ALL signature records for one name. Methods can be
/// overloaded — the strings region lists each name once but appends
/// multiple signature records back-to-back. Returns the list of
/// overloads in declaration order.
fn parseAllSigs(rec: []const u8, sig_start: usize, sig_end: usize, name_off: usize, alloc: std.mem.Allocator) !std.ArrayList(ParsedSig) {
    var out = std.ArrayList(ParsedSig).empty;
    var pos = sig_start;
    while (pos < sig_end) {
        const start_pos = pos;
        if (try parseOneSig(rec, &pos, sig_end, name_off, alloc)) |s| {
            try out.append(alloc, s);
        } else {
            // No more sigs for this name — restore and stop.
            pos = start_pos;
            break;
        }
    }
    return out;
}

fn shortClassName(full: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, full, ".")) |idx| return full[idx + 1 ..];
    return full;
}

/// Decode a single u16 J2ME/ExEn type tag into a human-readable string.
/// Tags we've observed empirically:
///   0x0042 'B' = byte
///   0x0043 'C' = char
///   0x0049 'I' = int (alt)
///   0x004a 'J' = long
///   0x0053 'S' = short
///   0x0056 'V' = void
///   0x0059 'Y' = int (most common — ExEn's primary "int")
///   0x005a 'Z' = boolean
///   0x0099       = reference (heap object)
///   0x013c       = byte[] or similar array ref
///   other        = "?0xXXXX"
/// Type tags decoded by the Resource.read* "Rosetta Stone": each
/// method's NAME tells us its return type, so we can map every tag.
/// Confirmed primitives:
///   0x0015 short    (Resource.readShort)
///   0x0055 char     (Resource.readChar)
///   0x0059 int      (Resource.readInt)
///   0x0090 byte     (Resource.readByte)
///   0x00d5 bool     (Resource.readBoolean)
///   0x0099 ref      (heap object — generic)
/// Arrays are `primitive + 0x0100`:
///   0x0115 short[]  (Resource.readShorts)
///   0x0159 int[]    (Resource.readInts)
///   0x0190 byte[]   (Resource.readBytes — high byte 0x01 = array marker)
/// Other:
///   0x0000 void     (typical return type for setters)
///   0x013c probably String reference (seen as arg of methods that
///          format/display text)
fn typeTag(tag: u16) []const u8 {
    return switch (tag) {
        0x0000 => "void",
        // Primitives
        0x0015 => "short",
        0x0055 => "char",
        0x0059 => "int",
        0x0090 => "byte",
        0x00d5 => "bool",
        // Generic reference
        0x0099 => "ref",
        // Arrays = primitive + 0x0100
        0x0115 => "short[]",
        0x0155 => "char[]",
        0x0159 => "int[]",
        0x0190 => "byte[]",
        0x01d5 => "bool[]",
        0x013c => "String",
        // JVM-style explicit tags (rare)
        0x0042 => "byte (B)",
        0x0043 => "char (C)",
        0x0049 => "int (I)",
        0x004a => "long (J)",
        0x0053 => "short (S)",
        0x0056 => "void (V)",
        0x005a => "bool (Z)",
        // Class-specific 0x0aXX refs are resolved per-record via xref
        // tables — the caller passes a map and decodes those there.
        else => "?",
    };
}

/// Render a single type tag, using the per-record xref map to resolve
/// 0x0aXX class-specific refs to actual class names. Ambiguous cases
/// (multiple candidate classes — e.g. shared inherited methods) are
/// rendered as `ref<A|B|C>`.
fn renderTag(tag: u16, xref: *const XrefMap, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if ((tag & 0xff00) == 0x0a00) {
        if (xref.get(tag)) |res| {
            const candidates = res.candidates.items;
            if (candidates.len == 0) {
                const s = try std.fmt.allocPrint(alloc, "ref<?:0x{x:0>4}>", .{tag});
                defer alloc.free(s);
                try buf.appendSlice(alloc, s);
            } else {
                try buf.appendSlice(alloc, "ref<");
                for (candidates, 0..) |c, i| {
                    if (i > 0) try buf.append(alloc, '|');
                    try buf.appendSlice(alloc, shortClassName(className(c)));
                }
                try buf.append(alloc, '>');
            }
        } else {
            const s = try std.fmt.allocPrint(alloc, "ref<unresolved:0x{x:0>4}>", .{tag});
            defer alloc.free(s);
            try buf.appendSlice(alloc, s);
        }
        return;
    }
    const ts = typeTag(tag);
    if (std.mem.eql(u8, ts, "?")) {
        const s = try std.fmt.allocPrint(alloc, "0x{x:0>4}", .{tag});
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    } else {
        try buf.appendSlice(alloc, ts);
    }
}

fn flagDesc(flags: u16, alloc: std.mem.Allocator) ![]u8 {
    var parts = std.ArrayList(u8).empty;
    // Verified flag bits:
    //   0x008 = static (used by INVOKESTATIC in opcodes/invoke.zig:154)
    //   0x100 = native (185 methods set this; matches funcs_407AA2[] size)
    // Inferred from the corpus:
    //   0x002 = instance field marker (every instance field has it)
    //   0x010 = final/constant (set on static constants like PM_*)
    //   0x001 = public/accessible (most methods)
    //   0x400 = abstract (Animation's 7 base-class slots only)
    if (flags & 0x100 != 0) try parts.appendSlice(alloc, "native ");
    if (flags & 0x400 != 0) try parts.appendSlice(alloc, "abstract ");
    if (flags & 0x008 != 0) try parts.appendSlice(alloc, "static ");
    if (flags & 0x010 != 0) try parts.appendSlice(alloc, "final ");
    if (flags & 0x002 != 0) try parts.appendSlice(alloc, "instance ");
    if (flags & 0x001 != 0) try parts.appendSlice(alloc, "public ");
    if (flags & 0x004 != 0) try parts.appendSlice(alloc, "f4? ");
    if (flags & 0x020 != 0) try parts.appendSlice(alloc, "f20? ");
    if (flags & 0x040 != 0) try parts.appendSlice(alloc, "f40? ");
    if (flags & 0x080 != 0) try parts.appendSlice(alloc, "f80? ");
    if (flags & 0x200 != 0) try parts.appendSlice(alloc, "f200? ");
    if (flags & 0x800 != 0) try parts.appendSlice(alloc, "f800? ");
    if (parts.items.len == 0) try parts.appendSlice(alloc, "-");
    return parts.toOwnedSlice(alloc);
}

fn fileNameForClass(full: []const u8, buf: []u8) []const u8 {
    // Replace "." with "_" so file names work on every filesystem.
    var n: usize = 0;
    for (full) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c == '.') '_' else c;
        n += 1;
    }
    return buf[0..n];
}

/// Pre-scan: build an index mapping every method hash to the list of
/// classes that declare it. Used to resolve xref-table entries: each
/// xref says "I call method-hash H on class-tag T"; we look up H here
/// to find candidate classes, then intersect across all entries
/// sharing the same T.
const MethodIndex = std.AutoHashMap(u32, std.ArrayList(u32));

/// Companion index: for each (class_hash, method_hash) pair, was the
/// method NAMED in that class's strings region? Used as a tiebreaker
/// when xref intersection yields multiple candidates: prefer classes
/// that DECLARE the method (named) over classes that merely INHERIT
/// it (unnamed entries in the dispatch table).
const NamedKey = struct { cls: u32, hash: u32 };
const NamedSet = std.AutoHashMap(NamedKey, void);

const Indexes = struct {
    method_idx: MethodIndex,
    named: NamedSet,
};

fn buildIndexes(bytes: []const u8, alloc: std.mem.Allocator) !Indexes {
    var method_idx = MethodIndex.init(alloc);
    var named = NamedSet.init(alloc);

    var off: usize = 0;
    while (off + 16 <= bytes.len) {
        if (!std.mem.eql(u8, bytes[off..][0..4], "4CVP")) { off += 1; continue; }
        const sz = std.mem.readInt(u16, bytes[off + 4 ..][0..2], .little);
        if (sz < 16 or off + sz > bytes.len) { off += 1; continue; }
        const rec = bytes[off .. off + sz];
        const cls = std.mem.readInt(u32, rec[12..][0..4], .little);
        var cls_label: []const u8 = "Unknown";
        for (CLASS_NAMES) |c| if (c.hash == cls) { cls_label = c.name; break; };
        const cls_short = shortClassName(cls_label);

        const ft = std.mem.readInt(u16, rec[30..][0..2], .little);
        const mt = std.mem.readInt(u16, rec[32..][0..2], .little);
        const fcount: u16 = if (ft != 0 and ft + 2 <= rec.len) std.mem.readInt(u16, rec[ft..][0..2], .little) else 0;

        // Collect method hashes
        var method_hashes = std.ArrayList(u32).empty;
        defer method_hashes.deinit(alloc);
        if (mt != 0 and mt + 2 <= rec.len) {
            const mcount = std.mem.readInt(u16, rec[mt..][0..2], .little);
            var p: usize = (mt + 5) & ~@as(usize, 3);
            var i: u16 = 0;
            while (i < mcount and p + 12 <= rec.len) : (i += 1) {
                const h = std.mem.readInt(u32, rec[p..][0..4], .little);
                try method_hashes.append(alloc, h);
                const gop = try method_idx.getOrPut(h);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                try gop.value_ptr.append(alloc, cls);
                p += 12;
            }
        }

        // Collect names (same logic as collectNames in main flow)
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(alloc);
        var i: usize = 36;
        while (i + 2 <= rec.len) {
            const namelen: u16 = @as(u16, rec[i]) | (@as(u16, rec[i + 1]) << 8);
            if (namelen >= 2 and namelen <= 40 and i + 2 + namelen <= rec.len) {
                const name = rec[i + 2 ..][0..namelen];
                var valid = true;
                for (name) |c| if (!isValidNameByte(c)) { valid = false; break; };
                const first_ok = name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '<' or name[0] == '_');
                if (valid and first_ok) {
                    if (!std.mem.eql(u8, name, cls_short)) try names.append(alloc, name);
                    i += 2 + namelen;
                    continue;
                }
            }
            i += 1;
        }

        // Same <init>-anchored pairing the main loop uses, so the "named"
        // set agrees with what we print per-class.
        var init_name_idx: ?usize = null;
        for (names.items, 0..) |n, idx| if (std.mem.eql(u8, n, "<init>")) { init_name_idx = idx; break; };
        var fpair_effective: usize = fcount;
        if (init_name_idx) |ni| {
            if (ni < fcount) fpair_effective = ni;
        }
        // Count total sig records across all method names (each name can
        // carry multiple overloads back-to-back). That count tells us
        // how many method_table entries are actually DECLARED (named) in
        // this class — the rest are inherited stubs in the dispatch
        // table without name strings.
        if (names.items.len > fpair_effective) {
            const method_names_start_idx: usize = fpair_effective;
            var total_named: usize = 0;
            // We need names with positions to compute sig_start/end. The
            // collectNames helper exposes NameEntry; do the equivalent
            // here. Reusing the local `names: ArrayList([]const u8)` we
            // already have isn't enough; re-walk strings to capture
            // positions for parseAllSigs.
            var name_entries = std.ArrayList(NameEntry).empty;
            defer name_entries.deinit(alloc);
            var ni: usize = 36;
            while (ni + 2 <= rec.len) {
                const namelen: u16 = @as(u16, rec[ni]) | (@as(u16, rec[ni + 1]) << 8);
                if (namelen >= 2 and namelen <= 40 and ni + 2 + namelen <= rec.len) {
                    const name = rec[ni + 2 ..][0..namelen];
                    var valid = true;
                    for (name) |c| if (!isValidNameByte(c)) { valid = false; break; };
                    const first_ok = name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '<' or name[0] == '_');
                    if (valid and first_ok) {
                        if (!std.mem.eql(u8, name, cls_short))
                            try name_entries.append(alloc, .{ .off = ni, .name = name, .sig_start = ni + 2 + namelen, .sig_end = 0 });
                        ni += 2 + namelen;
                        continue;
                    }
                }
                ni += 1;
            }
            // Compute sig_end for each entry
            var strings_end: usize = rec.len;
            if (ft != 0 and ft < strings_end) strings_end = ft;
            if (mt != 0 and mt < strings_end) strings_end = mt;
            for (name_entries.items, 0..) |*e, idx| {
                e.sig_end = if (idx + 1 < name_entries.items.len) name_entries.items[idx + 1].off else strings_end;
            }

            // For each method name, parse overload count
            for (name_entries.items[method_names_start_idx..]) |ne| {
                var ovs = parseAllSigs(rec, ne.sig_start, ne.sig_end, ne.off, alloc) catch continue;
                defer {
                    for (ovs.items) |s| alloc.free(s.arg_types);
                    ovs.deinit(alloc);
                }
                total_named += ovs.items.len;
            }
            const pair_count = @min(method_hashes.items.len, total_named);
            for (0..pair_count) |k| {
                try named.put(.{ .cls = cls, .hash = method_hashes.items[k] }, {});
            }
        }

        off = (off + sz + 3) & ~@as(usize, 3);
    }
    return .{ .method_idx = method_idx, .named = named };
}

/// Parse one record's xref table. Returns map tag (0x0aXX) → resolved
/// class hash (0 if ambiguous / not found). Layout in each record:
///
///   end-of-method-bodies up to `m34`:
///     u16[mcount-1]   sig-offset table (one per non-`<clinit>` method)
///     u32             xref count
///     count × 8 bytes:
///       u32   target_method_hash
///       u16   ??? (often 0, sometimes argc-ish)
///       u16   target_class_tag (0x0aXX form)
const TagResolution = struct {
    candidates: std.ArrayList(u32),
};

const XrefMap = std.AutoHashMap(u16, TagResolution);

fn xrefMapDeinit(m: *XrefMap, alloc: std.mem.Allocator) void {
    var it = m.valueIterator();
    while (it.next()) |r| r.candidates.deinit(alloc);
    m.deinit();
}

fn parseXrefTable(rec: []const u8, indexes: *const Indexes, alloc: std.mem.Allocator) !XrefMap {
    var out = XrefMap.init(alloc);
    const mt = std.mem.readInt(u16, rec[32..][0..2], .little);
    const m34 = std.mem.readInt(u16, rec[34..][0..2], .little);
    if (mt == 0 or m34 == 0 or m34 > rec.len) return out;
    const mcount = std.mem.readInt(u16, rec[mt..][0..2], .little);
    if (mcount == 0) return out;
    const mt_first: usize = (mt + 5) & ~@as(usize, 3);
    const mt_end: usize = mt_first + @as(usize, mcount) * 12;

    const sig_off_size: usize = (@as(usize, mcount) - 1) * 2;
    const xref_count_pos = mt_end + sig_off_size;
    if (xref_count_pos + 4 > rec.len or xref_count_pos + 4 > m34) return out;
    const xcount = std.mem.readInt(u32, rec[xref_count_pos..][0..4], .little);
    if (xcount == 0 or xcount > 256) return out;
    const entries_start = xref_count_pos + 4;
    if (entries_start + xcount * 8 > rec.len) return out;

    // Group xref entries by tag.
    var tag_methods = std.AutoHashMap(u16, std.ArrayList(u32)).init(alloc);
    defer {
        var it = tag_methods.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        tag_methods.deinit();
    }
    var k: u32 = 0;
    while (k < xcount) : (k += 1) {
        const entry_off = entries_start + k * 8;
        const hash = std.mem.readInt(u32, rec[entry_off..][0..4], .little);
        const tag = std.mem.readInt(u16, rec[entry_off + 6 ..][0..2], .little);
        const gop = try tag_methods.getOrPut(tag);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
        try gop.value_ptr.append(alloc, hash);
    }

    // Resolve each tag: intersect candidate classes across all hashes,
    // then prefer candidates that NAME the method (declaring class) over
    // candidates that inherit it (entry exists in dispatch table but
    // unnamed in strings region).
    var tit = tag_methods.iterator();
    while (tit.next()) |e| {
        const tag = e.key_ptr.*;
        const hashes = e.value_ptr.items;
        if (hashes.len == 0) continue;
        const first_classes = indexes.method_idx.get(hashes[0]) orelse continue;
        if (first_classes.items.len == 0) continue;
        var candidates = std.ArrayList(u32).empty;
        try candidates.appendSlice(alloc, first_classes.items);
        for (hashes[1..]) |h| {
            const more = indexes.method_idx.get(h) orelse {
                candidates.clearRetainingCapacity();
                break;
            };
            var i: usize = 0;
            while (i < candidates.items.len) {
                var found = false;
                for (more.items) |c| if (c == candidates.items[i]) { found = true; break; };
                if (!found) {
                    _ = candidates.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (candidates.items.len == 0) break;
        }

        // Tiebreaker: score each candidate by how many of `hashes` it
        // declares (has a name for) vs inherits (no name). Keep only the
        // candidates with the maximum score.
        if (candidates.items.len > 1) {
            var best_score: usize = 0;
            var scores = std.ArrayList(usize).empty;
            defer scores.deinit(alloc);
            for (candidates.items) |c| {
                var s: usize = 0;
                for (hashes) |h| {
                    if (indexes.named.contains(.{ .cls = c, .hash = h })) s += 1;
                }
                try scores.append(alloc, s);
                if (s > best_score) best_score = s;
            }
            // Keep only top-scoring candidates.
            if (best_score > 0) {
                var i: usize = 0;
                while (i < candidates.items.len) {
                    if (scores.items[i] < best_score) {
                        _ = candidates.swapRemove(i);
                        _ = scores.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        try out.put(tag, .{ .candidates = candidates });
    }
    return out;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const f = try std.fs.openFileAbsolute("/Users/narekh/Projects/notconsole/packages/exen-player2/assets/unk_4494F0.bin", .{});
    defer f.close();
    const bytes = try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(bytes);

    // Pre-scan: build the global method_hash → [class_hash] index AND
    // the (class, method) → named set used to disambiguate inherited
    // methods from declared ones during xref resolution.
    var indexes = try buildIndexes(bytes, alloc);
    defer {
        var it = indexes.method_idx.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        indexes.method_idx.deinit();
        indexes.named.deinit();
    }

    // Ensure docs/extracted/ exists.
    std.fs.makeDirAbsolute("/Users/narekh/Projects/notconsole/packages/exen-player2/docs/extracted") catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    const of = try std.fs.createFileAbsolute("/Users/narekh/Projects/notconsole/packages/exen-player2/docs/extracted_table.md", .{});
    defer of.close();
    var ofbuf: [65536]u8 = undefined;
    var ofw = of.writer(&ofbuf);
    const w = &ofw.interface;

    try w.print(
        \\# Extracted 4CVP Table — Index
        \\
        \\Generated by `tools/extract_table.zig` from `assets/unk_4494F0.bin`.
        \\
        \\Per-class details live in [`docs/extracted/<class>.md`](extracted/).
        \\Each per-class file contains **three structural views** of the
        \\record — no positional name-pairing anywhere. Hashes are the
        \\authoritative dispatch keys; names live in their own sequence
        \\and are NOT joined to the structural tables.
        \\
        \\1. **`field_table (raw)`** — every field-table row by index:
        \\   `hash`, `flags`, `type tag`, `slot`, `init_cp_off`. Hash is
        \\   what GETFIELD/PUTFIELD/GETSTATIC/PUTSTATIC dispatch on.
        \\2. **`method_table (raw)`** — every method-table row by index:
        \\   `hash`, `flags`, `argc`, `body_off`, `extra`, `native_idx`.
        \\   Hash is what INVOKE_* dispatches on; for natives, `body_off`
        \\   bytes hold a u32 → `funcs_407AA2[native_idx]` → `sub_*`.
        \\3. **`strings region (raw)`** — every parsed name with its
        \\   signature record(s) in byte-position order. Sigs (argc, arg
        \\   types, return type) are structural parses of the bin's
        \\   type-tag stream — they're real bytes, not heuristics.
        \\   What name belongs to what method-table row is NOT recorded
        \\   in the bin; pairing is a guess we deliberately avoid here.
        \\
        \\Hash uniqueness is scoped per class — `<init>` hashes to
        \\`0x3f52ef2f` across 30+ classes but the VM dispatches per
        \\receiver class so there's no ambiguity. The few `<init>`
        \\overloads with non-zero argc get a different hash (e.g.
        \\`Image.<init>(w,h,depth)` is `0x8a2aef2f`).
        \\
        \\## Flag bits
        \\
        \\| bit | meaning | source |
        \\|-----|---------|--------|
        \\| `0x001` | public / accessible | inferred (set on most methods) |
        \\| `0x002` | instance (counterpart to static) | inferred (every instance field) |
        \\| `0x004` | unknown (`f4?`) | – |
        \\| `0x008` | **static** | verified in `opcodes/invoke.zig:154` |
        \\| `0x010` | final / constant | inferred (set on `PM_*` and other static constants) |
        \\| `0x100` | **native** | verified — 185 methods have it, matching `funcs_407AA2[]` |
        \\| `0x400` | abstract | inferred (only Animation's 7 base-class slots set it; their `body_offset=0`) |
        \\
        \\## Type tags
        \\
        \\Decoded via the `Resource.read*` Rosetta Stone — each method's
        \\name reveals its return tag.
        \\
        \\### Primitives
        \\
        \\| tag | meaning | evidence |
        \\|-----|---------|---------|
        \\| `0x0000` | void | typical setter return |
        \\| `0x0015` | **short** | `Resource.readShort() → 0x0015` |
        \\| `0x0055` | **char** | `Resource.readChar() → 0x0055` |
        \\| `0x0059` | **int** | ExEn's primary int — `Resource.readInt() → int` |
        \\| `0x0090` | **byte** | `Resource.readByte() → 0x0090` |
        \\| `0x00d5` | **bool** | `Resource.readBoolean() → 0x00d5` |
        \\
        \\### Arrays (= primitive + `0x0100`)
        \\
        \\| tag | meaning | evidence |
        \\|-----|---------|---------|
        \\| `0x0115` | short[] | `Resource.readShorts(int) → 0x0115` |
        \\| `0x0155` | char[] | seen in `Bootstrap.init(char[])` — class-name string |
        \\| `0x0159` | int[] | `Resource.readInts(int) → 0x0159` |
        \\| `0x0190` | byte[] | `Resource.readBytes(int) → byte[]` |
        \\| `0x01d5` | bool[] | inferred from rule |
        \\
        \\### References
        \\
        \\| tag | meaning |
        \\|-----|---------|
        \\| `0x0099` | generic reference (any heap object — no static class info) |
        \\| `0x013c` | String reference (specific) |
        \\| `0x0a__` | class-specific reference — record-local class tag. The low byte indexes into the record's **cross-reference table** (after the sig-offset table, before the constant pool). The xref table is `[u32 count][count × {{ u32 target_method_hash; u16 ???; u16 target_class_tag }}]`. We resolve each tag by intersecting the classes that contain ALL its target method hashes — the unique match is the target. Same tag value (e.g. `0x0a34`) means **different classes in different records** because tags are compiler-assigned per record. |
        \\
        \\Explicit JVM-style tags (rare; used only for a few overloads):
        \\
        \\| tag | meaning |
        \\|-----|---------|
        \\| `0x0042` (`B`) | byte |
        \\| `0x0043` (`C`) | char |
        \\| `0x0049` (`I`) | int |
        \\| `0x004a` (`J`) | long |
        \\| `0x0053` (`S`) | short |
        \\| `0x0056` (`V`) | void |
        \\| `0x005a` (`Z`) | boolean |
        \\
        \\---
        \\
        \\## Classes
        \\
        \\
    , .{});

    var off: usize = 0;
    while (off + 16 <= bytes.len) {
        if (!std.mem.eql(u8, bytes[off..][0..4], "4CVP")) { off += 1; continue; }
        const sz = std.mem.readInt(u16, bytes[off + 4 ..][0..2], .little);
        if (sz < 16 or off + sz > bytes.len) { off += 1; continue; }
        const rec = bytes[off .. off + sz];
        const cls_hash = std.mem.readInt(u32, rec[12..][0..4], .little);
        const cls_full = className(cls_hash);
        const cls_short = shortClassName(cls_full);

        const m6 = std.mem.readInt(u16, rec[6..][0..2], .little);
        const m8 = std.mem.readInt(u32, rec[8..][0..4], .little);
        const m20 = std.mem.readInt(u32, rec[20..][0..4], .little);
        const clinit = std.mem.readInt(u16, rec[26..][0..2], .little);
        const ft = std.mem.readInt(u16, rec[30..][0..2], .little);
        const mt = std.mem.readInt(u16, rec[32..][0..2], .little);
        const m34 = std.mem.readInt(u16, rec[34..][0..2], .little);

        // Per-class file
        var fname_buf: [128]u8 = undefined;
        const fname = fileNameForClass(cls_full, &fname_buf);
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/Users/narekh/Projects/notconsole/packages/exen-player2/docs/extracted/{s}.md", .{fname});
        const cf = try std.fs.createFileAbsolute(path, .{});
        defer cf.close();
        var cfbuf: [262144]u8 = undefined;
        var cfw = cf.writer(&cfbuf);
        const cw = &cfw.interface;

        // Index entry pointing at the per-class file
        try w.print("- [`{s}`](extracted/{s}.md) — hash `0x{x:0>8}`, size {d} bytes\n", .{ cls_full, fname, cls_hash, sz });

        try cw.print(
            \\# {s}  (`0x{x:0>8}`)
            \\
            \\[← back to index](../extracted_table.md)
            \\
            \\## Header
            \\
            \\| field | offset | value | notes |
            \\|-------|--------|-------|-------|
            \\| `record_size` | +4  | {d} | total bytes in this record |
            \\| `format_version` | +6 | `0x{x:0>4}` | constant `0x0100` across all records |
            \\| `magic` | +8 | `0x{x:0>8}` | constant `0x000027dd` |
            \\| `tail_ptr` | +20 | `0x{x:0>8}` | high u16 ≈ end of strings region |
            \\| `clinit_method_info` | +26 | `0x{x:0>4}` | {s} |
            \\| `field_table_offset` | +30 | `0x{x:0>4}` | |
            \\| `method_table_offset` | +32 | `0x{x:0>4}` | |
            \\| `mystery_+34` | +34 | `0x{x:0>4}` | possibly constant-pool offset |
            \\
            \\
        , .{ cls_full, cls_hash, sz, m6, m8, m20, clinit, if (clinit == 0) "no static initializer" else "has `<clinit>`", ft, mt, m34 });

        // Parse this record's xref table for class-ref tag resolution.
        var xref = try parseXrefTable(rec, &indexes, alloc);
        defer xrefMapDeinit(&xref, alloc);

        // Collect names (positional)
        var names = try collectNames(rec, alloc, cls_short);
        defer names.deinit(alloc);

        const fcount: u16 = if (ft != 0 and ft + 2 <= rec.len) std.mem.readInt(u16, rec[ft..][0..2], .little) else 0;
        const mcount: u16 = if (mt != 0 and mt + 2 <= rec.len) std.mem.readInt(u16, rec[mt..][0..2], .little) else 0;

        // ===== field_table[] (purely structural — no name pairing) =====
        try cw.print("## field_table (raw — by row position)\n\n", .{});
        try cw.print(
            \\Pure dump of `field_table[]` rows in their byte order. Every
            \\field is read directly from the record bytes — no pairing
            \\with the strings region. `hash` is the field's dispatch key
            \\at runtime (`GETFIELD`/`PUTFIELD`/`GETSTATIC`/`PUTSTATIC`
            \\look up fields by this hash on the receiver class).
            \\
            \\
        , .{});
        if (fcount == 0) {
            try cw.print("_none_\n\n", .{});
        } else {
            try cw.print("| # | hash | flags | static | type | slot | init_cp_off |\n", .{});
            try cw.print("|---|------|-------|--------|------|------|-------------|\n", .{});
            var p: usize = (ft + 5) & ~@as(usize, 3);
            var i: u16 = 0;
            while (i < fcount and p + 12 <= rec.len) : (i += 1) {
                const h = std.mem.readInt(u32, rec[p..][0..4], .little);
                const flags = std.mem.readInt(u16, rec[p + 4 ..][0..2], .little);
                const tag = std.mem.readInt(u16, rec[p + 6 ..][0..2], .little);
                const slot = std.mem.readInt(u16, rec[p + 8 ..][0..2], .little);
                const cpoff = std.mem.readInt(u16, rec[p + 10 ..][0..2], .little);
                const flagstr = try flagDesc(flags, alloc);
                defer alloc.free(flagstr);
                const is_static: []const u8 = if (flags & 0x008 != 0) "yes" else "no";
                var type_buf = std.ArrayList(u8).empty;
                defer type_buf.deinit(alloc);
                try renderTag(tag, &xref, &type_buf, alloc);
                try cw.print(
                    "| {d} | `0x{x:0>8}` | `0x{x:0>4}` ({s}) | {s} | `0x{x:0>4}` ({s}) | {d} | `0x{x:0>4}` |\n",
                    .{ i, h, flags, flagstr, is_static, tag, type_buf.items, slot, cpoff },
                );
                p += 12;
            }
            try cw.print("\n", .{});
        }

        // ===== method_table[] (purely structural — no name pairing) =====
        try cw.print("## method_table (raw — by row position)\n\n", .{});
        try cw.print(
            \\Pure dump of `method_table[]` rows in their byte order. Every
            \\field is read directly from the record bytes — no pairing
            \\with the strings region. `hash` is the runtime dispatch key
            \\(`INVOKE_*` instructions look up methods by this hash).
            \\
            \\
        , .{});
        if (mcount == 0) {
            try cw.print("_none_\n\n", .{});
        } else {
            try cw.print("| # | hash | flags | static | native | argc | body_off | extra | native_idx |\n", .{});
            try cw.print("|---|------|-------|--------|--------|------|----------|-------|------------|\n", .{});
            var p2: usize = (mt + 5) & ~@as(usize, 3);
            var ii: u16 = 0;
            while (ii < mcount and p2 + 12 <= rec.len) : (ii += 1) {
                const h2 = std.mem.readInt(u32, rec[p2..][0..4], .little);
                const flags2 = std.mem.readInt(u16, rec[p2 + 4 ..][0..2], .little);
                const argc2 = std.mem.readInt(u16, rec[p2 + 6 ..][0..2], .little);
                const body2 = std.mem.readInt(u16, rec[p2 + 8 ..][0..2], .little);
                const extra2 = std.mem.readInt(u16, rec[p2 + 10 ..][0..2], .little);
                const flagstr2 = try flagDesc(flags2, alloc);
                defer alloc.free(flagstr2);
                const stat2: []const u8 = if (flags2 & 0x008 != 0) "yes" else "no";
                const nat2: []const u8 = if (flags2 & 0x100 != 0) "yes" else "no";
                var nidx_buf: [12]u8 = undefined;
                const nidx_str: []const u8 = if (flags2 & 0x100 != 0 and body2 + 4 <= rec.len) blk: {
                    const idx_val = std.mem.readInt(u32, rec[body2..][0..4], .little);
                    break :blk std.fmt.bufPrint(&nidx_buf, "{d}", .{idx_val}) catch "?";
                } else "-";
                try cw.print(
                    "| {d} | `0x{x:0>8}` | `0x{x:0>4}` ({s}) | {s} | {s} | {d} | `0x{x:0>4}` | `0x{x:0>4}` | {s} |\n",
                    .{ ii, h2, flags2, flagstr2, stat2, nat2, argc2, body2, extra2, nidx_str },
                );
                p2 += 12;
            }
            try cw.print("\n", .{});
        }

        // ===== Strings region (names + parsed sig records) =====
        try cw.print("## strings region (raw — by byte position)\n\n", .{});
        try cw.print(
            \\Pure dump of names + signature records as they appear in
            \\the record's strings region, in byte-position order. The
            \\region holds field-names AND method-names AND inline sig
            \\records, interleaved. Field-names have no sig records.
            \\Each method-name may carry one or more sig records (one
            \\per overload). The sig parse (argc + arg type tags +
            \\return type) is purely structural — real bytes, NOT
            \\inferred from the name. What is intentionally NOT here:
            \\any join from this name list to the method_table or
            \\field_table above. The bin does not encode that join; any
            \\pairing would be a positional guess, so we omit it.
            \\
            \\
        , .{});
        if (names.items.len == 0) {
            try cw.print("_no recognizable names_\n\n", .{});
        } else {
            try cw.print("| # | byte_off | name | overload | argc | arg types | return |\n", .{});
            try cw.print("|---|----------|------|----------|------|-----------|--------|\n", .{});
            for (names.items, 0..) |ne, ni| {
                var sigs = parseAllSigs(rec, ne.sig_start, ne.sig_end, ne.off, alloc) catch {
                    try cw.print("| {d} | `0x{x:0>4}` | `{s}` | - | - | (parse error) | - |\n", .{ ni, ne.off, ne.name });
                    continue;
                };
                defer {
                    for (sigs.items) |s| alloc.free(s.arg_types);
                    sigs.deinit(alloc);
                }
                if (sigs.items.len == 0) {
                    try cw.print("| {d} | `0x{x:0>4}` | `{s}` | - | - | (no sig records) | - |\n", .{ ni, ne.off, ne.name });
                    continue;
                }
                for (sigs.items, 0..) |s, oi| {
                    var args_buf = std.ArrayList(u8).empty;
                    defer args_buf.deinit(alloc);
                    for (s.arg_types, 0..) |tag, k| {
                        if (k > 0) try args_buf.appendSlice(alloc, ", ");
                        try renderTag(tag, &xref, &args_buf, alloc);
                    }
                    var ret_buf = std.ArrayList(u8).empty;
                    defer ret_buf.deinit(alloc);
                    try renderTag(s.ret_type, &xref, &ret_buf, alloc);
                    if (oi == 0) {
                        try cw.print(
                            "| {d} | `0x{x:0>4}` | `{s}` | {d} | {d} | `{s}` | `{s}` |\n",
                            .{ ni, ne.off, ne.name, oi, s.argc, args_buf.items, ret_buf.items },
                        );
                    } else {
                        try cw.print(
                            "| {d}.{d} | | ↳ | {d} | {d} | `{s}` | `{s}` |\n",
                            .{ ni, oi, oi, s.argc, args_buf.items, ret_buf.items },
                        );
                    }
                }
            }
            try cw.print("\n", .{});
        }

        try cw.flush();
        off = (off + sz + 3) & ~@as(usize, 3);
    }

    try w.flush();
    std.debug.print("Wrote docs/extracted_table.md (index) + 54 per-class files in docs/extracted/\n", .{});
}
