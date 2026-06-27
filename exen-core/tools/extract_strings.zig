//! Extract all text strings from an ExEn .exn file.
//!
//! ExEn string-resource format (deduced from the simulator's
//! `EXManufStringRegister` flow and TheTerminator's resource dumps):
//!
//!   Resources containing strings are stored as length-prefixed
//!   ("Pascal-style") byte strings, sometimes preceded by a small
//!   header (u32-LE total length + u16 string count + u16 metadata),
//!   sometimes embedded inline with leading `0xFF` padding bytes
//!   marking "absent" slots before the actual strings start.
//!
//!   String layout: `<u8 length><ASCII bytes>` repeated until either
//!   the resource ends or a NUL byte appears.
//!
//! Output is a per-resource text file in `extracted_strings/`, one
//! string per line, prefixed with its index in the resource.
//!
//! Usage:  zig run extract_strings.zig -- <gamelet.exn> [out_dir]

const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse "TheTerminator.exn";
    const out_dir_path = args.next() orelse "extracted_strings";

    const cwd = std.fs.cwd();
    const raw = try cwd.readFileAlloc(allocator, input_path, 64 << 20);
    defer allocator.free(raw);

    try cwd.makePath(out_dir_path);
    var out_dir = try cwd.openDir(out_dir_path, .{});
    defer out_dir.close();

    // Method/resource offset table at 0x38, count at 0x34.
    if (raw.len < 0x38) return error.TooSmall;
    const n = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    if (raw.len < 0x38 + 4 * n + 4) return error.TooSmall;
    var offsets = try allocator.alloc(u32, n);
    defer allocator.free(offsets);
    for (0..n) |i| {
        offsets[i] = std.mem.readInt(u32, raw[0x38 + i * 4 ..][0..4], .little);
    }
    const sentinel = std.mem.readInt(u32, raw[0x38 + 4 * n ..][0..4], .little);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("=== Extracting strings from {s} ({d} resources) ===\n\n", .{ input_path, n });

    // Combined "all strings" file too, for easy grepping.
    var combined_buf: std.ArrayList(u8) = .{};
    defer combined_buf.deinit(allocator);

    var total_strings: u32 = 0;
    var resources_with_strings: u32 = 0;
    for (0..n) |i| {
        const end: u32 = if (i + 1 < n) offsets[i + 1] else sentinel;
        if (end <= offsets[i]) continue;
        const length = end - offsets[i];
        if (length < 4) continue;
        const body = raw[offsets[i]..end];

        // Scan for length-prefixed strings. Skip the PNG signature
        // resources entirely — those are sprites.
        if (std.mem.indexOf(u8, body[0..@min(body.len, 64)], "\x89PNG") != null) continue;

        var strings: std.ArrayList([]const u8) = .{};
        defer strings.deinit(allocator);

        // Approach: scan the resource for consecutive runs of
        // printable (ASCII + Latin-1) bytes ≥ 2 chars, treating
        // any non-text byte (NUL, 0xFF, control chars except
        // CR/LF/tab, etc.) as a delimiter. ExEn uses several
        // delimiter conventions across resources — 0xFF as a
        // separator, Pascal-style u8-length prefixes, or short
        // u16/u32 headers — and walking-by-runs handles them all.
        var pos: usize = 0;
        while (pos < length) {
            // Skip non-text bytes.
            const c0 = body[pos];
            const is_text = (c0 >= 0x20 and c0 < 0x7F) or c0 >= 0xA0 or c0 == '\r' or c0 == '\n' or c0 == '\t';
            if (!is_text) {
                pos += 1;
                continue;
            }
            const start = pos;
            while (pos < length) {
                const c = body[pos];
                const text = (c >= 0x20 and c < 0x7F) or c >= 0xA0 or c == '\r' or c == '\n' or c == '\t';
                if (!text) break;
                pos += 1;
            }
            const slice = body[start..pos];
            if (slice.len < 5) continue;
            // Require ≥3 ASCII letters and letters be a meaningful
            // fraction of total bytes — filters out random Latin-1
            // high-byte sequences in binary resources.
            var letters: u32 = 0;
            for (slice) |b| {
                if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')) letters += 1;
            }
            if (letters < 3) continue;
            if (letters * 2 < slice.len) continue; // <50% letters → not a real string
            try strings.append(allocator, slice);
        }

        if (strings.items.len == 0) continue;
        resources_with_strings += 1;
        total_strings += @intCast(strings.items.len);

        var name_buf: [80]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "res_{d:0>3}_at_0x{x:0>5}.txt", .{ i, offsets[i] });

        var file = try out_dir.createFile(name, .{});
        defer file.close();
        var fw_buf: [4096]u8 = undefined;
        var fw = file.writer(&fw_buf);
        const w = &fw.interface;
        defer w.flush() catch {};

        try w.print("# Resource {d}, file offset 0x{x:0>5}, length {d}, {d} strings\n\n", .{ i, offsets[i], length, strings.items.len });
        try stdout.print("res {d:>3} (0x{x:0>5}, {d:>4} bytes): {d} strings  -> {s}\n", .{ i, offsets[i], length, strings.items.len, name });

        for (strings.items, 0..) |s, idx| {
            try w.print("[{d:>2}] {d:>3} chars: ", .{ idx, s.len });
            // Show ASCII characters as-is; replace CR/LF/separators
            // with visible escapes; replace other bytes with `.`.
            for (s) |b| {
                if (b == '\r') {
                    try w.writeAll("\\r");
                } else if (b == '\n') {
                    try w.writeAll("\\n");
                } else if (b == '\t') {
                    try w.writeAll("\\t");
                } else if (b >= 0x20 and b < 0x7F) {
                    try w.writeByte(b);
                } else {
                    try w.print("\\x{x:0>2}", .{b});
                }
            }
            try w.writeByte('\n');

            // Combined: one-line entry too
            try combined_buf.writer(allocator).print("res {d:>3}[{d:>2}]: ", .{ i, idx });
            for (s) |b| {
                if (b == '\r') {
                    try combined_buf.writer(allocator).writeAll("\\r");
                } else if (b == '\n') {
                    try combined_buf.writer(allocator).writeAll("\\n");
                } else if (b >= 0x20 and b < 0x7F) {
                    try combined_buf.writer(allocator).writeByte(b);
                } else {
                    try combined_buf.writer(allocator).print("\\x{x:0>2}", .{b});
                }
            }
            try combined_buf.writer(allocator).writeByte('\n');
        }
    }

    // Write the combined file.
    {
        const combined_path = "ALL_STRINGS.txt";
        var combined_file = try out_dir.createFile(combined_path, .{});
        defer combined_file.close();
        try combined_file.writeAll(combined_buf.items);
        try stdout.print("\nWrote combined dump: {s}/{s}\n", .{ out_dir_path, combined_path });
    }

    try stdout.print("\nSummary: {d} strings across {d} resources\n", .{ total_strings, resources_with_strings });
}
