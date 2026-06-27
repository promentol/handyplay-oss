//! Scan every method in a class for PUTSTATIC referencing a given descriptor
//! offset. Reports per-method PC + opcode (PUTSTATIC vs PUTSTATIC_FULL).
//!
//! Usage:
//!   zig run tools/scan_putstatic.zig -- samples/Pikubi.exn 0xfedefd22 0x0228
const std = @import("std");

const ClassRec = struct { off: usize, sz: usize };

fn findClass(buf: []const u8, tail_start: usize, target: u32) ?ClassRec {
    var off = tail_start;
    while (off + 16 <= buf.len) {
        if (!std.mem.eql(u8, buf[off..][0..4], "4CVP")) break;
        const sz: usize = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
        const h = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
        if (h == target) return .{ .off = off, .sz = sz };
        off = (off + sz + 3) & ~@as(usize, 3);
    }
    return null;
}

const OperandKind = enum { none, u8op, u16op, switch_table };

fn operandKind(op: u8) OperandKind {
    return switch (op) {
        0x10, 0x19, 0x3A, 0x4A, 0xD5, 0xD6 => .u8op,
        0x11, 0x12, 0x14, 0x99...0xA7, 0xC0, 0xC6, 0xC7, 0xBB, 0xBC,
        0xD0, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
        0xF7, 0xF8, 0xF9, 0xFA => .u16op,
        0x84 => .u16op, // IINC: 1+1, we'll treat as u16 padding
        0xCC, 0xCD => .switch_table,
        else => .none,
    };
}

fn alignPc(pc: u32) u32 {
    return (pc + 1) & ~@as(u32, 1);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next();
    const exn_path = args.next() orelse return;
    const class_hash_str = args.next() orelse return;
    const desc_off_str = args.next() orelse return;

    const class_hash = try std.fmt.parseInt(u32, class_hash_str[2..], 16);
    const target_desc: u16 = try std.fmt.parseInt(u16, desc_off_str[2..], 16);

    const buf = try std.fs.cwd().readFileAlloc(a, exn_path, 1 << 22);
    defer a.free(buf);

    const method_count_at_34: u32 = std.mem.readInt(u32, buf[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count_at_34;
    const tail_start: usize = @intCast(std.mem.readInt(u32, buf[sentinel_off..][0..4], .little));
    const cls = findClass(buf, tail_start, class_hash) orelse {
        std.debug.print("class 0x{x:0>8} not found\n", .{class_hash});
        return;
    };
    const cb = buf[cls.off..cls.off + cls.sz];

    const mt: usize = std.mem.readInt(u16, cb[32..][0..2], .little);
    const mcount = std.mem.readInt(u16, cb[mt..][0..2], .little);
    var p: usize = (mt + 5) & ~@as(usize, 3);

    std.debug.print("scanning class=0x{x:0>8}  target_desc=0x{x:0>4}  methods={d}\n", .{ class_hash, target_desc, mcount });

    var hits: u32 = 0;
    var i: u16 = 0;
    while (i < mcount) : (i += 1) {
        if (p + 12 > cb.len) break;
        const mhash = std.mem.readInt(u32, cb[p..][0..4], .little);
        const body_off = std.mem.readInt(u16, cb[p + 8 ..][0..2], .little);
        p = (p + 15) & ~@as(usize, 3);

        if (body_off == 0 or body_off + 6 > cb.len) continue;
        const body_len_field = std.mem.readInt(u16, cb[body_off + 4 ..][0..2], .little);
        var pc: u32 = body_off + 6;
        const end: u32 = @min(@as(u32, body_off) + 6 + body_len_field + 100, @as(u32, @intCast(cb.len)));

        while (pc < end) {
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
                    if ((op == 0xf4 or op == 0xf8) and v == target_desc) {
                        std.debug.print("  HIT method=0x{x:0>8}  PC=0x{x:0>4}  op=0x{x:0>2} ({s})  desc=0x{x:0>4}\n",
                            .{ mhash, opc_pc, op, if (op == 0xf4) "PUTSTATIC" else "PUTSTATIC_FULL", v });
                        hits += 1;
                    }
                    pc += 2;
                },
                .switch_table => {
                    pc = alignPc(pc);
                    if (pc + 2 > end) break;
                    if (op == 0xCD) {
                        if (pc + 6 > end) break;
                        const low: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 2 ..][0..2], .little));
                        const high: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 4 ..][0..2], .little));
                        const n: u32 = @intCast(@as(i32, high) - low + 1);
                        pc += 6 + 2 * n;
                    } else {
                        if (pc + 4 > end) break;
                        const count: u16 = std.mem.readInt(u16, cb[pc + 2 ..][0..2], .little);
                        pc += 4 + 4 * count;
                    }
                },
            }
        }
    }
    std.debug.print("done. {d} hit(s).\n", .{hits});
}
