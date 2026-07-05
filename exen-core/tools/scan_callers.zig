//! Find every method invocation across the .exn whose descriptor's method
//! hash matches the given target. Reports class/method/PC and the call
//! opcode (which family of INVOKE).
//!
//! Usage:
//!   zig run tools/scan_callers.zig -- samples/Pikubi.exn 0x3f52e539
const std = @import("std");
const core = @import("core");

const OperandKind = enum { none, u8op, u16op, iinc, newarray, multianewarray, switch_table };

/// Derived from `core.opcodes.operand_widths` (single source with the VM
/// dispatch table). Fixes the old private table's bugs: IINC (0x84) is an
/// UNALIGNED u8+s8 pair (was stepped as aligned u16), and the 0xAA/0xAB
/// switch flavours are now stepped as switches instead of no-operand.
fn operandKind(op: u8) OperandKind {
    return switch (core.opcodes.operand_widths[op]) {
        1 => .u8op,
        2 => .u16op,
        -2 => .iinc,
        -3 => .newarray,
        -4 => .multianewarray,
        -1 => .switch_table,
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

const opName = core.opcodes.opName;

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

    std.debug.print("scanning all classes for callers of method hash 0x{x:0>8}\n\n", .{target_hash});

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

            while (pc < end) {
                const op = cb[pc];
                const opc_pc = pc;
                pc += 1;
                switch (operandKind(op)) {
                    .none => {},
                    .u8op => pc += 1,
                    .iinc => pc += 2,
                    .newarray, .multianewarray => {
                        // aligned u16 tag (+u8 dim first for MULTI), plus a
                        // second u16 class ref iff tag low byte == 0x99.
                        if (operandKind(op) == .multianewarray) pc += 1;
                        pc = alignPc(pc);
                        if (pc + 2 > end) break;
                        const tag = std.mem.readInt(u16, cb[pc..][0..2], .little);
                        pc += 2;
                        if ((tag & 0xFF) == 0x99) pc += 2;
                    },
                    .u16op => {
                        pc = alignPc(pc);
                        if (pc + 2 > end) break;
                        const v = std.mem.readInt(u16, cb[pc..][0..2], .little);
                        const is_call = op >= 0xED and op <= 0xF2;
                        if (is_call) {
                            // method descriptor: hash at +0
                            if (@as(usize, v) + 4 <= cb.len) {
                                const hashv = std.mem.readInt(u32, cb[v..][0..4], .little);
                                if (hashv == target_hash) {
                                    std.debug.print("  CALLER class=0x{x:0>8} method=0x{x:0>8} PC=0x{x:0>4} op=0x{x:0>2} ({s}) desc=0x{x:0>4}\n",
                                        .{ class_hash, mhash, opc_pc, op, opName(op), v });
                                    hits += 1;
                                }
                            }
                        }
                        pc += 2;
                    },
                    .switch_table => {
                        pc = alignPc(pc);
                        if (pc + 6 > end) break;
                        if (op == 0xCD or op == 0xAA) {
                            const low: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 2..][0..2], .little));
                            const high: i16 = @bitCast(std.mem.readInt(u16, cb[pc + 4..][0..2], .little));
                            const range: i32 = @as(i32, high) - @as(i32, low) + 1;
                            if (range <= 0 or range > 65535) break;
                            const n: u32 = @intCast(range);
                            pc += 6 + 2 * n;
                        } else if (op == 0xAB) { // LOOKUPSWITCH_W: u32 keys, 4-byte-aligned
                            const count: u32 = std.mem.readInt(u16, cb[pc + 2..][0..2], .little);
                            const keys_base = (pc + 4 + 3) & ~@as(u32, 3);
                            pc = keys_base + count * 6;
                        } else { // LOOKUPSWITCH 0xCC: u16 key + u16 target pairs
                            const count: u32 = std.mem.readInt(u16, cb[pc + 2..][0..2], .little);
                            pc += 4 + 4 * count;
                        }
                    },
                }
            }
        }
    }
    std.debug.print("\ndone. {d} caller(s).\n", .{hits});
}
