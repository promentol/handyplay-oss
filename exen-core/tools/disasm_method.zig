//! Self-contained method disassembler.
//! Usage:
//!   zig run tools/disasm_method.zig -- samples/TheTerminator.exn 0x82a4b082 0x0dcbf391

const std = @import("std");
const core = @import("core");

const Op = struct { name: []const u8, operands: i32 };

/// Derived from `core.opcodes.op_specs` — single source with VM dispatch.
/// (This tool joined the build graph for the `core` import: build with
/// `zig build tools`, run `zig-out/bin/disasm_method`.)
const OPS: [256]Op = blk: {
    var t: [256]Op = undefined;
    for (0..256) |i| t[i] = .{
        .name = core.opcodes.mnemonics[i],
        .operands = core.opcodes.operand_widths[i],
    };
    break :blk t;
};

fn alignPc(pc: u32) u32 {
    return (pc + 1) & ~@as(u32, 1);
}

const MethodInfo = struct {
    hash: u32,
    flags: u16,
    arg_count: u16,
    body_offset: u16,
};

fn findClass(buf: []const u8, tail_start: usize, target_hash: u32) ?struct { off: usize, sz: usize } {
    var off: usize = tail_start;
    while (off + 16 <= buf.len) {
        if (!std.mem.eql(u8, buf[off..][0..4], "4CVP")) break;
        const sz = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
        const hash = std.mem.readInt(u32, buf[off + 12 ..][0..4], .little);
        if (hash == target_hash) return .{ .off = off, .sz = sz };
        off = (off + sz + 3) & ~@as(usize, 3);
    }
    return null;
}

fn methodTableOffset(class_bytes: []const u8) u16 {
    return std.mem.readInt(u16, class_bytes[32..][0..2], .little);
}
fn methodCount(class_bytes: []const u8) u16 {
    const mt = methodTableOffset(class_bytes);
    if (mt == 0 or mt + 2 > class_bytes.len) return 0;
    return std.mem.readInt(u16, class_bytes[mt..][0..2], .little);
}
fn firstMethodInfoOffset(class_bytes: []const u8) usize {
    const mt: usize = methodTableOffset(class_bytes);
    return (mt + 5) & ~@as(usize, 3);
}

fn findMethod(class_bytes: []const u8, target: u32) ?MethodInfo {
    const count = methodCount(class_bytes);
    var p = firstMethodInfoOffset(class_bytes);
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (p + 12 > class_bytes.len) return null;
        const h = std.mem.readInt(u32, class_bytes[p..][0..4], .little);
        if (h == target) {
            return .{
                .hash = h,
                .flags = std.mem.readInt(u16, class_bytes[p + 4 ..][0..2], .little),
                .arg_count = std.mem.readInt(u16, class_bytes[p + 6 ..][0..2], .little),
                .body_offset = std.mem.readInt(u16, class_bytes[p + 8 ..][0..2], .little),
            };
        }
        p = (p + 15) & ~@as(usize, 3);
    }
    return null;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    var args = try std.process.argsWithAllocator(a);
    defer args.deinit();
    _ = args.next();
    const exn_path = args.next() orelse "samples/TheTerminator.exn";
    const class_hash_str = args.next() orelse "0x82a4b082";
    const method_hash_str = args.next() orelse "0x0dcbf391";

    const class_hash = try std.fmt.parseInt(u32, class_hash_str[2..], 16);
    const method_hash = try std.fmt.parseInt(u32, method_hash_str[2..], 16);

    const buf = try std.fs.cwd().readFileAlloc(a, exn_path, 1 << 22);
    defer a.free(buf);

    // Raw 4CVP blob (e.g. assets/unk_4494F0.bin) starts directly with a
    // class record; the gamelet .exn has a header → tail_start at sentinel.
    const tail_start: usize = if (std.mem.eql(u8, buf[0..4], "4CVP")) 0 else blk: {
        const method_count_at_34: u32 = std.mem.readInt(u32, buf[0x34..][0..4], .little);
        const sentinel_off = 0x38 + 4 * method_count_at_34;
        break :blk @intCast(std.mem.readInt(u32, buf[sentinel_off..][0..4], .little));
    };

    const cls = findClass(buf, tail_start, class_hash) orelse {
        std.debug.print("class 0x{x:0>8} not found from tail_start=0x{x}\n", .{ class_hash, tail_start });
        return;
    };
    const class_bytes = buf[cls.off..cls.off + cls.sz];

    const mi = findMethod(class_bytes, method_hash) orelse {
        std.debug.print("method 0x{x:0>8} not found in class 0x{x:0>8}\n", .{ method_hash, class_hash });
        return;
    };

    // Abstract (ACC_ABSTRACT 0x400) / bodyless methods have no bytecode;
    // disassembling from body_offset+6 would decode the class-record
    // header as garbage instructions.
    if ((mi.flags & 0x400) != 0 or mi.body_offset == 0) {
        std.debug.print("class=0x{x:0>8}  method=0x{x:0>8}\n", .{ class_hash, method_hash });
        std.debug.print("  flags=0x{x:0>4}  arg_count={d}  — ABSTRACT / no body\n", .{ mi.flags, mi.arg_count });
        return;
    }

    const max_stack = std.mem.readInt(u16, class_bytes[mi.body_offset..][0..2], .little);
    const locals = std.mem.readInt(u16, class_bytes[mi.body_offset + 2 ..][0..2], .little);
    const body_len = std.mem.readInt(u16, class_bytes[mi.body_offset + 4 ..][0..2], .little);

    std.debug.print("class=0x{x:0>8}  method=0x{x:0>8}\n", .{ class_hash, method_hash });
    std.debug.print("  flags=0x{x:0>4}  arg_count={d}\n", .{ mi.flags, mi.arg_count });
    std.debug.print("  body_offset=0x{x:0>4}  max_stack={d}  locals={d}  body_len={d}\n\n", .{
        mi.body_offset, max_stack, locals, body_len,
    });

    var pc: u32 = mi.body_offset + 6;
    // body_len at +4 isn't reliable; cap at body_offset + ~600 bytes
    // to keep output manageable. Most ExEn methods are <500 bytes.
    const cap_end: u32 = @min(@as(u32, mi.body_offset) + 2000, @as(u32, @intCast(class_bytes.len)));
    const end: u32 = cap_end;
    var seen_return: bool = false;
    while (pc < end and !seen_return) {
        const op = class_bytes[pc];
        const opc_pc = pc;
        pc += 1;
        const info = OPS[op];

        std.debug.print("  0x{x:0>4}  0x{x:0>2}  {s: <18}", .{ opc_pc, op, info.name });

        // Don't stop at returns — keep going to disassemble all reachable
        // code (including post-branch targets). Caller can ctrl-c if too long.
        _ = &seen_return;
        if (info.operands == 0) {
            std.debug.print("\n", .{});
        } else if (info.operands == 1) {
            std.debug.print("  {d}\n", .{class_bytes[pc]});
            pc += 1;
        } else if (info.operands == 2) {
            pc = alignPc(pc);
            const v = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
            std.debug.print("  0x{x:0>4}\n", .{v});
            pc += 2;
        } else if (info.operands == -2) {
            // IINC: u8 local idx + s8 delta
            const idx = class_bytes[pc];
            const delta: i8 = @bitCast(class_bytes[pc + 1]);
            std.debug.print("  local[{d}] += {d}\n", .{ idx, delta });
            pc += 2;
        } else if (info.operands == -3 or info.operands == -4) {
            // NEWARRAY / MULTIANEWARRAY: aligned u16 type tag (MULTI has
            // a u8 dim first), plus a second u16 element-class ref iff
            // the tag low byte is 0x99 (canonical sub_40EE4D v0==153).
            var dim_str: u8 = 0;
            if (info.operands == -4) {
                dim_str = class_bytes[pc];
                pc += 1;
            }
            pc = alignPc(pc);
            const tag = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
            pc += 2;
            if (info.operands == -4) std.debug.print("  dim={d}", .{dim_str});
            if ((tag & 0xFF) == 0x99) {
                const cls_ref = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
                std.debug.print("  0x{x:0>4}  classref=0x{x:0>4}\n", .{ tag, cls_ref });
                pc += 2;
            } else {
                std.debug.print("  0x{x:0>4}\n", .{tag});
            }
        } else if (info.operands == -1) {
            // TABLESWITCH / LOOKUPSWITCH — variable-length
            pc = alignPc(pc);
            const default_pc = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
            if (op == 0xCD) { // TABLESWITCH
                const low: i16 = @bitCast(std.mem.readInt(u16, class_bytes[pc + 2 ..][0..2], .little));
                const high: i16 = @bitCast(std.mem.readInt(u16, class_bytes[pc + 4 ..][0..2], .little));
                const n: u32 = @intCast(@as(i32, high) - low + 1);
                std.debug.print("  default=0x{x:0>4}  low={d}  high={d}  targets:", .{ default_pc, low, high });
                pc += 6;
                for (0..n) |k| {
                    const t = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
                    std.debug.print(" [{d}]=0x{x:0>4}", .{ @as(i32, low) + @as(i32, @intCast(k)), t });
                    pc += 2;
                }
                std.debug.print("\n", .{});
            } else if (op == 0xAB) { // LOOKUPSWITCH_W: u32 keys, 4-byte-aligned, u16 targets
                const count: u16 = std.mem.readInt(u16, class_bytes[pc + 2 ..][0..2], .little);
                const keys_base: u32 = (pc + 4 + 3) & ~@as(u32, 3);
                std.debug.print("  default=0x{x:0>4}  count={d}  pairs(wide):", .{ default_pc, count });
                for (0..count) |i| {
                    const k = std.mem.readInt(u32, class_bytes[keys_base + 4 * @as(u32, @intCast(i)) ..][0..4], .little);
                    const t = std.mem.readInt(u16, class_bytes[keys_base + 4 * @as(u32, count) + 2 * @as(u32, @intCast(i)) ..][0..2], .little);
                    std.debug.print(" 0x{x:0>8}→0x{x:0>4}", .{ k, t });
                }
                pc = keys_base + @as(u32, count) * 6;
                std.debug.print("\n", .{});
            } else { // LOOKUPSWITCH 0xCC: u16 key + u16 target pairs
                const count: u16 = std.mem.readInt(u16, class_bytes[pc + 2 ..][0..2], .little);
                std.debug.print("  default=0x{x:0>4}  count={d}  pairs:", .{ default_pc, count });
                pc += 4;
                for (0..count) |_| {
                    const k = std.mem.readInt(u16, class_bytes[pc..][0..2], .little);
                    const t = std.mem.readInt(u16, class_bytes[pc + 2 * count ..][0..2], .little);
                    std.debug.print(" {d}→0x{x:0>4}", .{ k, t });
                    pc += 2;
                }
                pc += 2 * count;
                std.debug.print("\n", .{});
            }
        }
    }
}
