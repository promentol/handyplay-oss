//! Classify the MRE natives a decompiled C file references, using the metadata table
//! in core/natives.zig as the single source of truth. That table (`core.natives.table`,
//! a `[]const Native` with boolean `stub`/`verified` fields) is imported directly — no
//! text/comment parsing, no @embedFile, no running the VM. Every native referenced in
//! the C is reported as one of:
//!
//!   MISSING             — not in the table at all (needs implementing).
//!   STUBBED / UNVERIFIED — stub == true, verified == false: constant return not yet
//!                          confirmed against the SDK doc.
//!   STUBBED / VERIFIED   — stub == true, verified == true: placeholder whose return is
//!                          confirmed correct (behaves right; low priority).
//!   implemented          — stub == false: a real handler.
//!
//! Editing/annotating a native in core/natives.zig's `table` is the ONLY change needed;
//! this tool re-derives everything from it on the next build.
//!
//! Usage:
//!   natives-from-c                     aggregate table over ALL .c in vxp_game_sources/
//!   natives-from-c <dir>               aggregate table over all .c in <dir>
//!   natives-from-c <file.c> [more.c…]  per-file report(s); use "-" for stdin
//!     zig build natives-from-c                                    # full corpus table
//!     zig build natives-from-c -- vxp_game_sources/adam_n_eve_240x320.c
const std = @import("std");
const core = @import("core");

const default_dir = "vxp_game_sources";

const Category = enum { implemented, stub_verified, stub_unverified };

// gamelet entry points / decompiler artifacts — not host natives.
const not_natives = [_][]const u8{ "vm_main", "vm_image_p", "vm_get_sym_entry" };

fn isExcluded(name: []const u8) bool {
    for (not_natives) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Look the name up in the authoritative registration table. Null = MISSING.
fn classify(name: []const u8) ?Category {
    for (core.natives.table) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (!e.stub) return .implemented;
        return if (e.verified) .stub_verified else .stub_unverified;
    }
    return null;
}

/// A quoted token is a native name iff it starts vm_/mremu_ and is all [a-z0-9_].
fn isNativeName(s: []const u8) bool {
    const ok_prefix = std.mem.startsWith(u8, s, "vm_") or std.mem.startsWith(u8, s, "mremu_");
    if (!ok_prefix or s.len < 5) return false;
    for (s) |ch| switch (ch) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

/// Distinct native names referenced (as string literals) in a C source. Keys reference
/// `src` — keep it alive while the set is in use.
fn scan(gpa: std.mem.Allocator, src: []const u8) !std.StringHashMap(void) {
    var refs = std.StringHashMap(void).init(gpa);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] != '"') continue;
        const start = i + 1;
        var j = start;
        while (j < src.len and src[j] != '"' and src[j] != '\n') j += 1;
        i = j; // resume at/after the closing quote
        if (j >= src.len or src[j] != '"') continue;
        const tok = src[start..j];
        if (isNativeName(tok) and !isExcluded(tok)) try refs.put(tok, {});
    }
    return refs;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn printGroup(title: []const u8, names: [][]const u8) void {
    if (names.len == 0) return;
    std.debug.print("  {s} ({d}):\n", .{ title, names.len });
    for (names) |n| std.debug.print("    {s}\n", .{n});
}

fn report(gpa: std.mem.Allocator, label: []const u8, src: []const u8) !void {
    var refs = try scan(gpa, src);
    defer refs.deinit();

    var missing: std.ArrayList([]const u8) = .empty;
    var stub_unv: std.ArrayList([]const u8) = .empty;
    var stub_ver: std.ArrayList([]const u8) = .empty;
    var impl: std.ArrayList([]const u8) = .empty;
    defer for ([_]*std.ArrayList([]const u8){ &missing, &stub_unv, &stub_ver, &impl }) |l| l.deinit(gpa);

    var it = refs.keyIterator();
    while (it.next()) |k| {
        const name = k.*;
        const list = switch (classify(name) orelse {
            try missing.append(gpa, name);
            continue;
        }) {
            .implemented => &impl,
            .stub_verified => &stub_ver,
            .stub_unverified => &stub_unv,
        };
        try list.append(gpa, name);
    }
    for ([_]*std.ArrayList([]const u8){ &missing, &stub_unv, &stub_ver, &impl }) |l|
        std.mem.sort([]const u8, l.items, {}, lessName);

    std.debug.print("\n{s}\n", .{label});
    std.debug.print("  {d} natives referenced | MISSING {d}, STUBBED-unverified {d}, " ++
        "STUBBED-verified {d}, implemented {d}\n", .{
        refs.count(), missing.items.len, stub_unv.items.len, stub_ver.items.len, impl.items.len,
    });
    printGroup("MISSING — not in core/natives.zig table (implement these)", missing.items);
    printGroup("STUBBED / UNVERIFIED — return not confirmed vs SDK doc", stub_unv.items);
    printGroup("STUBBED / VERIFIED — return confirmed correct (placeholder)", stub_ver.items);
    printGroup("implemented", impl.items);
}

// ---- aggregate mode: one table across every .c in a folder --------------------

const Row = struct { name: []const u8, count: u32 };

/// Sort by game-count descending, then name ascending.
fn moreCount(_: void, a: Row, b: Row) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn printRows(o: *std.Io.Writer, title: []const u8, rows: []const Row) !void {
    if (rows.len == 0) return;
    try o.print("\n  {s} ({d}):\n", .{ title, rows.len });
    for (rows) |r| try o.print("    {d:>3}  {s}\n", .{ r.count, r.name });
}

fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// Scan every `*.c` in `dir_path` and print a single table: each native referenced by
/// any game, its category (from the natives.zig table), and the number of games that
/// reference it — sorted most-wanted first within each category.
fn aggregate(gpa: std.mem.Allocator, dir_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa); // owns the deduped name keys
    defer arena.deinit();
    const akey = arena.allocator();

    const Rec = struct { cat: ?Category, count: u32 }; // cat == null -> MISSING
    var agg = std.StringHashMap(Rec).init(gpa);
    defer agg.deinit();

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open dir '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close();

    var files: u32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".c")) continue;
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(path);
        const src = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        files += 1;
        var refs = try scan(gpa, src);
        defer refs.deinit();
        var rit = refs.keyIterator();
        while (rit.next()) |k| {
            if (agg.getPtr(k.*)) |rec| {
                rec.count += 1;
            } else {
                try agg.put(try akey.dupe(u8, k.*), .{ .cat = classify(k.*), .count = 1 });
            }
        }
    }

    var miss: std.ArrayList(Row) = .empty;
    var sunv: std.ArrayList(Row) = .empty;
    var sver: std.ArrayList(Row) = .empty;
    var impl: std.ArrayList(Row) = .empty;
    defer for ([_]*std.ArrayList(Row){ &miss, &sunv, &sver, &impl }) |l| l.deinit(gpa);

    var ait = agg.iterator();
    while (ait.next()) |e| {
        const row = Row{ .name = e.key_ptr.*, .count = e.value_ptr.count };
        const list = switch (e.value_ptr.cat orelse {
            try miss.append(gpa, row);
            continue;
        }) {
            .implemented => &impl,
            .stub_verified => &sver,
            .stub_unverified => &sunv,
        };
        try list.append(gpa, row);
    }
    for ([_]*std.ArrayList(Row){ &miss, &sunv, &sver, &impl }) |l|
        std.mem.sort(Row, l.items, {}, moreCount);

    // Write the full table to <dir>/_natives_table.txt; echo a one-line summary.
    const out_path = try std.fs.path.join(gpa, &.{ dir_path, "_natives_table.txt" });
    defer gpa.free(out_path);
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    var wbuf: [8192]u8 = undefined;
    var fw = file.writer(&wbuf);
    const o = &fw.interface;

    try o.print("=== natives across {d} game(s) in {s} ===\n", .{ files, dir_path });
    try o.print("  {d} distinct natives | MISSING {d}, STUBBED-unverified {d}, " ++
        "STUBBED-verified {d}, implemented {d}  (count = games referencing it)\n", .{
        agg.count(), miss.items.len, sunv.items.len, sver.items.len, impl.items.len,
    });
    try printRows(o, "MISSING — not in core/natives.zig table (implement these)", miss.items);
    try printRows(o, "STUBBED / UNVERIFIED — return not confirmed vs SDK doc", sunv.items);
    try printRows(o, "STUBBED / VERIFIED — return confirmed correct (placeholder)", sver.items);
    try printRows(o, "implemented", impl.items);
    try o.flush();

    std.debug.print("wrote {s}  ({d} games, {d} natives: MISSING {d}, " ++
        "STUBBED-unverified {d}, STUBBED-verified {d}, implemented {d})\n", .{
        out_path, files, agg.count(), miss.items.len, sunv.items.len, sver.items.len, impl.items.len,
    });
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // No args -> aggregate the whole default corpus folder.
    if (args.len < 2) return aggregate(gpa, default_dir);
    // A single directory arg -> aggregate that folder.
    if (args.len == 2 and isDir(args[1])) return aggregate(gpa, args[1]);

    // Otherwise: a per-file report for each argument ("-" = stdin).
    for (args[1..]) |path| {
        if (std.mem.eql(u8, path, "-")) {
            const src = try std.fs.File.stdin().readToEndAlloc(gpa, 64 * 1024 * 1024);
            defer gpa.free(src);
            try report(gpa, "<stdin>", src);
            continue;
        }
        const src = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024) catch |err| {
            std.debug.print("\n{s}\n  skip: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(src);
        try report(gpa, path, src);
    }
}
