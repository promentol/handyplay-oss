//! Scan ALL classes in an .exn for any code that writes the field with the
//! given hash. Reports class/method/PC for every PUTSTATIC, PUTSTATIC_FULL,
//! PUTFIELD_OWN, PUTFIELD_FULL whose descriptor's hash matches.
//!
//! Usage:
//!   zig run tools/scan_field_writers.zig -- samples/Pikubi.exn 0x184d7ccc
const std = @import("std");

const OperandKind = enum { none, u8op, u16op, switch_table };

fn operandKind(op: u8) OperandKind {
    return switch (op) {
        0x10, 0x19, 0x3A, 0x4A, 0xD5, 0xD6 => .u8op,
        0x11, 0x12, 0x14, 0x99...0xA7, 0xC0, 0xC6, 0xC7, 0xBB, 0xBC,
        0xD0, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
        0xF7, 0xF8, 0xF9, 0xFA => .u16op,
        0x84 => .u16op,
        0xCC, 0xCD => .switch_table,
        else => .none,
    };
}

fn alignPc(pc: u32) u32 { return (pc + 1) & ~@as(u32, 1); }

const BodyRec = struct { body_off: u16, idx: u32 };

fn ltBody(_: void, a: BodyRec, b: BodyRec) bool { return a.body_off < b.body_off; }

fn collectMethodEnds(cb: []const u8, allocator: std.mem.Allocator) ![]u32 {
    const mt: usize = std.mem.readInt(u16, cb[32..][0..2], .little);
    if (mt == 0 or mt + 2 > cb.len) return &.{};
    const mcount = std.mem.readInt(u16, cb[mt..][0..2], .little);
    var p: usize = (mt + 5) & ~@as(usize, 3);

    var bodies = try allocator.alloc(BodyRec, mcount);
    defer allocator.free(bodies);
    var i: u16 = 0;
    while (i < mcount) : (i += 1) {
        if (p + 12 > cb.len) break;
        const body_off = std.mem.readInt(u16, cb[p + 8..][0..2], .little);
        bodies[i] = .{ .body_off = body_off, .idx = i };
        p = (p + 15) & ~@as(usize, 3);
    }
    std.sort.pdq(BodyRec, bodies, {}, ltBody);

    var ends = try allocator.alloc(u32, mcount);
    var j: u32 = 0;
    while (j < bodies.len) : (j += 1) {
        const this_off = bodies[j].body_off;
        var next_off: u32 = @intCast(cb.len);
        var k: u32 = j + 1;
        while (k < bodies.len) : (k += 1) {
            if (bodies[k].body_off > this_off) {
                next_off = bodies[k].body_off;
                break;
            }
        }
        ends[bodies[j].idx] = next_off;
    }
    return ends;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next();
    const exn_path = args.next() orelse return;
    const target_hash_str = args.next() orelse return;
    const target_hash = try std.fmt.parseInt(u32, target_hash_str[2..], 16);

    const buf = try std.fs.cwd().readFileAlloc(a, exn_path, 1 << 22);
    defer a.free(buf);

    const method_count_at_34: u32 = std.mem.readInt(u32, buf[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count_at_34;
    const tail_start: usize = @intCast(std.mem.readInt(u32, buf[sentinel_off..][0..4], .little));

    std.debug.print("scanning all classes for writers of field hash 0x{x:0>8}\n\n", .{target_hash});

    var off = tail_start;
    var hits: u32 = 0;
    while (off + 16 <= buf.len) : (off = (off + std.mem.readInt(u16, buf[off + 4..][0..2], .little) + 3) & ~@as(usize, 3)) {
        if (!std.mem.eql(u8, buf[off..][0..4], "4CVP")) break;
        const sz: usize = std.mem.readInt(u16, buf[off + 4..][0..2], .little);
        const class_hash = std.mem.readInt(u32, buf[off + 12..][0..4], .little);
        const cb = buf[off..off + sz];

        const mt: usize = std.mem.readInt(u16, cb[32..][0..2], .little);
        if (mt == 0 or mt + 2 > cb.len) continue;
        const mcount = std.mem.readInt(u16, cb[mt..][0..2], .little);

        const ends = collectMethodEnds(cb, a) catch &.{};
        defer if (ends.len > 0) a.free(ends);

        var p: usize = (mt + 5) & ~@as(usize, 3);
        var i: u16 = 0;
        while (i < mcount) : (i += 1) {
            if (p + 12 > cb.len) break;
            const mhash = std.mem.readInt(u32, cb[p..][0..4], .little);
            const body_off = std.mem.readInt(u16, cb[p + 8..][0..2], .little);
            p = (p + 15) & ~@as(usize, 3);

            if (body_off == 0 or body_off + 6 > cb.len) continue;
            var pc: u32 = body_off + 6;
            const end: u32 = if (i < ends.len) ends[i] else @intCast(cb.len);

            while (pc < end and pc < cb.len) {
                const op = cb[pc];
                const opc_pc = pc;
                pc += 1;
                switch (operandKind(op)) {
                    .none => {},
                    .u8op => pc += 1,
                    .u16op => {
                        pc = alignPc(pc);
                        if (pc + 2 > end) break;
                        const v = std.mem.readInt(u16, cb[pc..][0..2], .little);
                        const is_writer = op == 0xf4 or op == 0xf8 or op == 0xf6 or op == 0xfa;
                        if (is_writer) {
                            if (@as(usize, v) + 4 <= cb.len) {
                                const hashv = std.mem.readInt(u32, cb[v..][0..4], .little);
                                if (hashv == target_hash) {
                                    std.debug.print("  HIT class=0x{x:0>8} method=0x{x:0>8} PC=0x{x:0>4} op=0x{x:0>2}  desc=0x{x:0>4} hash=0x{x:0>8}\n",
                                        .{ class_hash, mhash, opc_pc, op, v, hashv });
                                    hits += 1;
                                }
                            }
                        }
                        pc += 2;
                    },
                    .switch_table => {
                        pc = alignPc(pc);
                        if (pc + 6 > end) break;
                        if (op == 0xCD) {
                            const low: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 2..][0..2], .little));
                            const high: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 4..][0..2], .little));
                            const range: i32 = @as(i32, high) - @as(i32, low) + 1;
                            if (range <= 0 or range > 65535) break; // bogus tableswitch, give up
                            const n: u32 = @intCast(range);
                            pc += 6 + 2 * n;
                        } else {
                            const count: u32 = std.mem.readInt(u16, cb[pc + 2..][0..2], .little);
                            pc += 4 + 4 * count;
                        }
                    },
                }
            }
        }
    }
    std.debug.print("\ndone. {d} hit(s).\n", .{hits});
}
