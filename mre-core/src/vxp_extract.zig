const std = @import("std");

const usage = "usage: vxp-extract <input.vxp> [output.elf]\n";

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 2 or args.len > 3) {
        std.debug.print(usage, .{});
        return error.BadArgs;
    }

    const in_path = args[1];
    const out_path = if (args.len == 3) args[2] else try defaultElfName(gpa, in_path);
    defer if (args.len < 3) gpa.free(out_path);

    var in_file = try std.fs.cwd().openFile(in_path, .{});
    defer in_file.close();
    var out_file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_file.close();

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;

    var file_reader = in_file.reader(&in_buf);
    var file_writer = out_file.writer(&out_buf);

    // Sniff: zlib stream (0x78 0x9c/0xda/0x01) vs raw ELF (0x7F 'E' 'L' 'F').
    const magic = try file_reader.interface.peek(4);
    const kind: enum { zlib, elf, unknown } = blk: {
        if (std.mem.eql(u8, magic, "\x7fELF")) break :blk .elf;
        if (magic[0] == 0x78) break :blk .zlib;
        break :blk .unknown;
    };

    const n = switch (kind) {
        .zlib => n: {
            var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .zlib, &window);
            break :n try decompress.reader.streamRemaining(&file_writer.interface);
        },
        .elf => try file_reader.interface.streamRemaining(&file_writer.interface),
        .unknown => {
            std.debug.print("unrecognised VXP header: {x}\n", .{magic});
            return error.UnknownFormat;
        },
    };
    try file_writer.interface.flush();

    std.debug.print("wrote {s} ({d} bytes, {s})\n", .{ out_path, n, @tagName(kind) });
}

fn defaultElfName(gpa: std.mem.Allocator, in_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(in_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    return std.fmt.allocPrint(gpa, "{s}.elf", .{stem});
}
