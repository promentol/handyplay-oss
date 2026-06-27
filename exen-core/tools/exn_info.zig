//! exn_info — print a gamelet's metadata + dump its icon PNG.
//!
//! Usage:
//!   zig build tools && zig-out/bin/exn_info <path-to.exn> [--icon out.png]
//!
//! Prints name, file size, section count, and (when present) icon
//! dimensions. With `--icon <path>`, extracts the icon PNG bytes to
//! the given file.

const std = @import("std");
const exen = @import("core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe

    var path: ?[]const u8 = null;
    var icon_out: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--icon")) {
            icon_out = args.next() orelse usage();
        } else if (path == null) {
            path = a;
        }
    }
    const p = path orelse usage();

    var meta = exen.exn_metadata_fs.readMetadata(alloc, p) catch |err| {
        std.debug.print("error reading {s}: {s}\n", .{ p, @errorName(err) });
        std.process.exit(1);
    };
    defer meta.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("name:     {s}\n", .{meta.name});
    try stdout.print("size:     {d} bytes\n", .{meta.file_size});
    try stdout.print("sections: {d}\n", .{meta.section_count});
    if (meta.icon) |i| {
        try stdout.print("icon:     {d}x{d}, PNG @ file+{d} ({d} bytes)\n", .{
            i.width, i.height, i.png_offset, i.png_length,
        });
    } else {
        try stdout.print("icon:     none\n", .{});
    }

    if (icon_out) |out_path| {
        const png_bytes = (try exen.exn_metadata_fs.readIconPng(alloc, p)) orelse {
            std.debug.print("no icon section to extract\n", .{});
            std.process.exit(2);
        };
        defer alloc.free(png_bytes);
        var f = try std.fs.cwd().createFile(out_path, .{});
        defer f.close();
        try f.writeAll(png_bytes);
        try stdout.print("wrote icon → {s} ({d} bytes)\n", .{ out_path, png_bytes.len });
    }
}

fn usage() noreturn {
    std.debug.print("usage: exn_info <path-to.exn> [--icon out.png]\n", .{});
    std.process.exit(64);
}
