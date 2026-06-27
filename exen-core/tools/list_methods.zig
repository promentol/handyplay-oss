//! Enumerate all methods in a class and the descriptor at a given offset.
//! Usage:
//!   zig run tools/list_methods.zig -- samples/TheTerminator.exn 0x82a4b082 [0x0e00]
const std = @import("std");

const ClassRec = struct { off: usize, sz: usize, hash: u32 };

fn findClass(buf: []const u8, tail_start: usize, target: u32) ?ClassRec {
    var off = tail_start;
    while (off + 16 <= buf.len) {
        if (!std.mem.eql(u8, buf[off..][0..4], "4CVP")) break;
        const sz: usize = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
        const h = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
        if (h == target) return .{ .off = off, .sz = sz, .hash = h };
        off = (off + sz + 3) & ~@as(usize, 3);
    }
    return null;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next();
    const exn_path = args.next() orelse return;
    const class_hash_str = args.next() orelse return;
    const probe_off_str = args.next();

    const class_hash = try std.fmt.parseInt(u32, class_hash_str[2..], 16);
    const buf = try std.fs.cwd().readFileAlloc(a, exn_path, 1 << 22);
    defer a.free(buf);

    const method_count_at_34: u32 = std.mem.readInt(u32, buf[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count_at_34;
    const tail_start: usize = @intCast(std.mem.readInt(u32, buf[sentinel_off..][0..4], .little));
    const cls = findClass(buf, tail_start, class_hash) orelse {
        std.debug.print("class not found\n", .{});
        return;
    };
    const cb = buf[cls.off .. cls.off + cls.sz];

    const mt: usize = std.mem.readInt(u16, cb[32..][0..2], .little);
    const mcount = std.mem.readInt(u16, cb[mt..][0..2], .little);
    var p: usize = (mt + 5) & ~@as(usize, 3);
    std.debug.print("class=0x{x:0>8}  method_table=0x{x}  count={d}\n", .{ class_hash, mt, mcount });
    var i: u16 = 0;
    while (i < mcount) : (i += 1) {
        if (p + 12 > cb.len) break;
        const h = std.mem.readInt(u32, cb[p..][0..4], .little);
        const fl = std.mem.readInt(u16, cb[p + 4 ..][0..2], .little);
        const ac = std.mem.readInt(u16, cb[p + 6 ..][0..2], .little);
        const bo = std.mem.readInt(u16, cb[p + 8 ..][0..2], .little);
        std.debug.print("  [{d:3}] desc@0x{x:0>4}  hash=0x{x:0>8}  flags=0x{x:0>4}  argc={d}  body=0x{x:0>4}\n", .{ i, p, h, fl, ac, bo });
        p = (p + 15) & ~@as(usize, 3);
    }

    if (probe_off_str) |s| {
        const off = try std.fmt.parseInt(u32, s[2..], 16);
        if (off + 12 <= cb.len) {
            const h = std.mem.readInt(u32, cb[off..][0..4], .little);
            const fl = std.mem.readInt(u16, cb[off + 4 ..][0..2], .little);
            const ac = std.mem.readInt(u16, cb[off + 6 ..][0..2], .little);
            const bo = std.mem.readInt(u16, cb[off + 8 ..][0..2], .little);
            std.debug.print("\nprobe desc@0x{x:0>4}: hash=0x{x:0>8}  flags=0x{x:0>4}  argc={d}  body=0x{x:0>4}\n", .{ off, h, fl, ac, bo });
        }
    }

    // Dump FIRE handler field descriptors of interest
    std.debug.print("\n--- field descriptors at common offsets ---\n", .{});
    for ([_]u16{ 0x003c, 0x0048, 0x0054, 0x0078, 0x0084, 0x00c0, 0x009c, 0x0030 }) |fo| {
        const off: usize = fo;
        if (off + 12 <= cb.len) {
            const h = std.mem.readInt(u32, cb[off..][0..4], .little);
            const t1 = std.mem.readInt(u16, cb[off + 4 ..][0..2], .little);
            const t2 = std.mem.readInt(u16, cb[off + 6 ..][0..2], .little);
            const sl = std.mem.readInt(u16, cb[off + 8 ..][0..2], .little);
            std.debug.print("  desc@0x{x:0>4}: hash=0x{x:0>8}  f4=0x{x:0>4}  tag=0x{x:0>4}  slot={d}\n", .{ fo, h, t1, t2, sl });
        }
    }
}
