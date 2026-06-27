//! BIOS discovery by MD5 (RetroArch convention): the frontend drops BIOS files into
//! the libretro system directory under ANY name; the core scans that directory,
//! MD5s each file, and matches against the hashes it requires — so identification is
//! filename-independent. Matched files are copied to the MEMFS paths the VM reads.
//! (Copied per core; keep the hash table in sync with the firmware set.)
const std = @import("std");
const Md5 = std.crypto.hash.Md5;

pub const Req = struct {
    md5: []const u8, // expected lowercase-hex MD5 (32 chars)
    dst: []const u8, // MEMFS path to copy the matching file to
};

fn md5hex(data: []const u8, out: *[32]u8) void {
    var h: [16]u8 = undefined;
    Md5.hash(data, &h, .{});
    const hx = "0123456789abcdef";
    for (h, 0..) |b, i| {
        out[i * 2] = hx[b >> 4];
        out[i * 2 + 1] = hx[b & 0xf];
    }
}

fn writeMemfs(dst: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(dst)) |d| std.fs.cwd().makePath(d) catch {};
    const f = try std.fs.cwd().createFile(dst, .{});
    defer f.close();
    try f.writeAll(data);
}

/// Scan `sysdir` and copy each required BIOS (matched by MD5) to its dst path.
/// Errors if any required hash isn't present — the frontend must provide the firmware.
pub fn install(gpa: std.mem.Allocator, sysdir: []const u8, reqs: []const Req) !void {
    var zbuf: [1024]u8 = undefined;
    const sysz = std.fmt.bufPrintZ(&zbuf, "{s}", .{sysdir}) catch return error.PathTooLong;
    const dir = std.c.opendir(sysz) orelse return error.NoSystemDir;
    defer _ = std.c.closedir(dir);

    const found = try gpa.alloc(bool, reqs.len);
    defer gpa.free(found);
    @memset(found, false);

    while (std.c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        var pbuf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ sysdir, name }) catch continue;
        const data = std.fs.cwd().readFileAlloc(gpa, full, 16 << 20) catch continue;
        defer gpa.free(data);
        var hx: [32]u8 = undefined;
        md5hex(data, &hx);
        for (reqs, 0..) |req, i| {
            if (!found[i] and std.mem.eql(u8, &hx, req.md5)) {
                writeMemfs(req.dst, data) catch {};
                found[i] = true;
            }
        }
    }
    for (found, reqs) |f, req| if (!f) {
        std.log.scoped(.bios).err("missing BIOS md5={s} (-> {s}) in {s}", .{ req.md5, req.dst, sysdir });
        return error.MissingBios;
    };
}
