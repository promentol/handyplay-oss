//! Self-contained method disassembler.
//! Usage:
//!   zig run tools/disasm_method.zig -- samples/TheTerminator.exn 0x82a4b082 0x0dcbf391

const std = @import("std");

const Op = struct { name: []const u8, operands: i32 };

const OPS = blk: {
    var t: [256]Op = [_]Op{.{ .name = "?", .operands = 0 }} ** 256;
    t[0x00] = .{ .name = "NOP", .operands = 0 };
    t[0x01] = .{ .name = "ACONST_NULL", .operands = 0 };
    t[0x02] = .{ .name = "ICONST_M1", .operands = 0 };
    t[0x03] = .{ .name = "ICONST_0", .operands = 0 };
    t[0x04] = .{ .name = "ICONST_1", .operands = 0 };
    t[0x05] = .{ .name = "ICONST_2", .operands = 0 };
    t[0x06] = .{ .name = "ICONST_3", .operands = 0 };
    t[0x07] = .{ .name = "ICONST_4", .operands = 0 };
    t[0x08] = .{ .name = "ICONST_5", .operands = 0 };
    t[0x10] = .{ .name = "BIPUSH", .operands = 1 };
    t[0x11] = .{ .name = "SIPUSH", .operands = 2 };
    t[0x12] = .{ .name = "LDC", .operands = 2 };
    t[0x14] = .{ .name = "LDC2_W", .operands = 2 };
    t[0x19] = .{ .name = "ALOAD", .operands = 1 };
    t[0x2A] = .{ .name = "ALOAD_0", .operands = 0 };
    t[0x2B] = .{ .name = "ALOAD_1", .operands = 0 };
    t[0x2C] = .{ .name = "ALOAD_2", .operands = 0 };
    t[0x2D] = .{ .name = "ALOAD_3", .operands = 0 };
    t[0x32] = .{ .name = "AALOAD", .operands = 0 };
    t[0x33] = .{ .name = "BALOAD", .operands = 0 };
    t[0x34] = .{ .name = "CALOAD", .operands = 0 };
    t[0x3A] = .{ .name = "ASTORE", .operands = 1 };
    t[0x4A] = .{ .name = "ASTORE_op", .operands = 1 };
    t[0x4B] = .{ .name = "ASTORE_0", .operands = 0 };
    t[0x4C] = .{ .name = "ASTORE_1", .operands = 0 };
    t[0x4D] = .{ .name = "ASTORE_2", .operands = 0 };
    t[0x4E] = .{ .name = "ASTORE_3", .operands = 0 };
    t[0x4F] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x50] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x51] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x52] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x53] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x54] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x55] = .{ .name = "ARRSTORE", .operands = 0 };
    t[0x56] = .{ .name = "POP", .operands = 0 };
    t[0x57] = .{ .name = "POP", .operands = 0 };
    t[0x58] = .{ .name = "POP2", .operands = 0 };
    t[0x59] = .{ .name = "DUP", .operands = 0 };
    t[0x5A] = .{ .name = "DUP_X1", .operands = 0 };
    t[0x5C] = .{ .name = "DUP2", .operands = 0 };
    t[0x60] = .{ .name = "IADD", .operands = 0 };
    t[0x61] = .{ .name = "LADD", .operands = 0 };
    t[0x64] = .{ .name = "ISUB", .operands = 0 };
    t[0x65] = .{ .name = "LSUB", .operands = 0 };
    t[0x68] = .{ .name = "IMUL", .operands = 0 };
    t[0x6C] = .{ .name = "IDIV", .operands = 0 };
    t[0x70] = .{ .name = "IREM", .operands = 0 };
    t[0x74] = .{ .name = "INEG", .operands = 0 };
    t[0x78] = .{ .name = "ISHL", .operands = 0 };
    t[0x7A] = .{ .name = "ISHR", .operands = 0 };
    t[0x7C] = .{ .name = "IUSHR", .operands = 0 };
    t[0x7E] = .{ .name = "IAND", .operands = 0 };
    t[0x80] = .{ .name = "IOR", .operands = 0 };
    t[0x82] = .{ .name = "IXOR", .operands = 0 };
    t[0x84] = .{ .name = "IINC", .operands = -2 };
    t[0x91] = .{ .name = "I2B", .operands = 0 };
    t[0x92] = .{ .name = "I2C", .operands = 0 };
    t[0x93] = .{ .name = "I2S", .operands = 0 };
    t[0x99] = .{ .name = "IFEQ", .operands = 2 };
    t[0x9A] = .{ .name = "IFNE", .operands = 2 };
    t[0x9B] = .{ .name = "IFLT", .operands = 2 };
    t[0x9C] = .{ .name = "IFGE", .operands = 2 };
    t[0x9D] = .{ .name = "IFGT", .operands = 2 };
    t[0x9E] = .{ .name = "IFLE", .operands = 2 };
    t[0x9F] = .{ .name = "IF_ICMPEQ", .operands = 2 };
    t[0xA0] = .{ .name = "IF_ICMPNE", .operands = 2 };
    t[0xA1] = .{ .name = "IF_ICMPLT", .operands = 2 };
    t[0xA2] = .{ .name = "IF_ICMPGE", .operands = 2 };
    t[0xA3] = .{ .name = "IF_ICMPGT", .operands = 2 };
    t[0xA4] = .{ .name = "IF_ICMPLE", .operands = 2 };
    t[0xA5] = .{ .name = "IFNULL", .operands = 2 };
    t[0xA6] = .{ .name = "IFNONNULL", .operands = 2 };
    t[0xA7] = .{ .name = "GOTO", .operands = 2 };
    t[0xB0] = .{ .name = "ARETURN", .operands = 0 };
    t[0xB1] = .{ .name = "RETURN", .operands = 0 };
    t[0xBB] = .{ .name = "NEW", .operands = 2 };
    t[0xBC] = .{ .name = "NEWARRAY", .operands = 2 };
    t[0xBE] = .{ .name = "ARRAYLENGTH", .operands = 0 };
    t[0xC0] = .{ .name = "CHECKCAST", .operands = 2 };
    t[0xC6] = .{ .name = "IFNULL", .operands = 2 };
    t[0xC7] = .{ .name = "IFNONNULL", .operands = 2 };
    t[0xCC] = .{ .name = "LOOKUPSWITCH", .operands = -1 };
    t[0xCD] = .{ .name = "TABLESWITCH", .operands = -1 };
    t[0xD0] = .{ .name = "LDC_STRING", .operands = 2 };
    t[0xD5] = .{ .name = "LOAD_op", .operands = 1 };
    t[0xD6] = .{ .name = "STORE_op", .operands = 1 };
    t[0xD9] = .{ .name = "ALOAD_0_DUP", .operands = 0 };
    t[0xDA] = .{ .name = "ASTORE_0", .operands = 0 };
    t[0xDB] = .{ .name = "LLOAD_0", .operands = 0 };
    t[0xDC] = .{ .name = "LSTORE_0", .operands = 0 };
    t[0xDD] = .{ .name = "LOAD_1", .operands = 0 };
    t[0xDE] = .{ .name = "STORE_1", .operands = 0 };
    t[0xDF] = .{ .name = "LLOAD_1", .operands = 0 };
    t[0xE0] = .{ .name = "LSTORE_1", .operands = 0 };
    t[0xE1] = .{ .name = "LOAD_2", .operands = 0 };
    t[0xE2] = .{ .name = "STORE_2", .operands = 0 };
    t[0xE3] = .{ .name = "LLOAD_2", .operands = 0 };
    t[0xE4] = .{ .name = "LSTORE_2", .operands = 0 };
    t[0xE5] = .{ .name = "LOAD_3", .operands = 0 };
    t[0xE6] = .{ .name = "STORE_3", .operands = 0 };
    t[0xE7] = .{ .name = "LLOAD_3", .operands = 0 };
    t[0xE8] = .{ .name = "LSTORE_3", .operands = 0 };
    t[0xE9] = .{ .name = "IRETURN", .operands = 0 };
    t[0xEA] = .{ .name = "LRETURN", .operands = 0 };
    t[0xED] = .{ .name = "INVOKEVIRTUAL_ALT", .operands = 2 };
    t[0xEE] = .{ .name = "INVOKEVIRTUAL", .operands = 2 };
    t[0xEF] = .{ .name = "INVOKE_OWN", .operands = 2 };
    t[0xF0] = .{ .name = "INVOKESPECIAL", .operands = 2 };
    t[0xF1] = .{ .name = "INVOKESTATIC_ALT", .operands = 2 };
    t[0xF2] = .{ .name = "INVOKESTATIC", .operands = 2 };
    t[0xF3] = .{ .name = "GETSTATIC", .operands = 2 };
    t[0xF4] = .{ .name = "PUTSTATIC", .operands = 2 };
    t[0xF5] = .{ .name = "GETFIELD_OWN", .operands = 2 };
    t[0xF6] = .{ .name = "PUTFIELD_OWN", .operands = 2 };
    t[0xF7] = .{ .name = "GETSTATIC_FULL", .operands = 2 };
    t[0xF8] = .{ .name = "PUTSTATIC_FULL", .operands = 2 };
    t[0xF9] = .{ .name = "GETFIELD", .operands = 2 };
    t[0xFA] = .{ .name = "PUTFIELD_FULL", .operands = 2 };
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
            } else {
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
