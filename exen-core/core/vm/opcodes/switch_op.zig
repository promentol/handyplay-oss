//! Multi-way branch (LOOKUPSWITCH, TABLESWITCH)
//!
//! Auto-grouped from `core/vm/opcodes.zig` by `op*` family. Each
//! handler keeps its original 1-for-1 port of the `sub_*` body in
//! `reference/ref`.

const std = @import("std");
const err_mod = @import("../error.zig");
const frame_mod = @import("../frame.zig");
const vm_mod = @import("../vm.zig");
const cr = @import("../../classfile/registry.zig");
const log_fmt = @import("../log_fmt.zig");

const log = std.log.scoped(.interp);
const Error = err_mod.Error;
const Frame = frame_mod.Frame;
const Vm = vm_mod.Vm;
const classStr = log_fmt.classStr;
const methodStr = log_fmt.methodStr;

const EXEN_GAMELET = vm_mod.EXEN_GAMELET;
const JAVA_LANG_OBJECT = vm_mod.JAVA_LANG_OBJECT;

pub fn opLookupswitch(_: *Vm, frame: *Frame, _: u8) Error!void {
    const key_u = try frame.pop();
    const key: i32 = @bitCast(key_u);
    frame.alignPc();
    if (frame.pc + 4 > frame.bytecode.len) return Error.StackOverflow;
    const default_pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    const count: u16 = std.mem.readInt(u16, frame.bytecode[frame.pc + 2 ..][0..2], .little);
    const keys_base = frame.pc + 4;
    const targets_base = keys_base + 2 * @as(u32, count);
    if (targets_base + 2 * @as(u32, count) > frame.bytecode.len) return Error.StackOverflow;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const k_u: u16 = std.mem.readInt(u16, frame.bytecode[keys_base + 2 * i ..][0..2], .little);
        const k: i32 = @as(i16, @bitCast(k_u));
        if (k == key) {
            const tgt = std.mem.readInt(u16, frame.bytecode[targets_base + 2 * i ..][0..2], .little);
            log.debug("  LOOKUPSWITCH key={d} matched [{d}] → 0x{x:0>4}", .{ key, i, tgt });
            frame.pc = tgt;
            return;
        }
    }
    log.debug("  LOOKUPSWITCH key={d} default → 0x{x:0>4}", .{ key, default_pc });
    frame.pc = default_pc;
}

/// LOOKUPSWITCH_W (opcode 0xab, sub_40D294 at ref:11571) —
/// JVM-style wide lookup switch with 32-bit keys (vs 16-bit keys in
/// our 0xCC variant). Used by MutantAlert's class init when matching
/// against full class-hash constants.
///
/// Canonical layout after the opcode byte (PC aligned to even):
///   u16 default_pc
///   u16 count
///   (pad to 4-byte boundary — `v6 = (v3 + 7) & ~3`)
///   u32 keys[count]
///   u16 offsets[count]
///
/// Compare each u32 key against the popped value. On match, jump to
/// the corresponding u16 offset. Else jump to default_pc.
pub fn opLookupswitchW(_: *Vm, frame: *Frame, _: u8) Error!void {
    const key = try frame.pop(); // u32 — canonical compares as int
    frame.alignPc();
    if (frame.pc + 4 > frame.bytecode.len) return Error.StackOverflow;
    const default_pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    const count: u16 = std.mem.readInt(u16, frame.bytecode[frame.pc + 2 ..][0..2], .little);

    // Canonical: `v6 = (v3 + 7) & ~3` where v3 = frame.pc (after opcode +
    // alignment). v3 + 4 (default+count headers) advances past the
    // headers; then +3 then mask = round UP to next 4-byte boundary.
    const after_headers = frame.pc + 4;
    const keys_base = (after_headers + 3) & ~@as(u32, 3);
    const targets_base = keys_base + 4 * @as(u32, count);
    if (targets_base + 2 * @as(u32, count) > frame.bytecode.len) return Error.StackOverflow;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const k: u32 = std.mem.readInt(u32, frame.bytecode[keys_base + 4 * i ..][0..4], .little);
        if (k == key) {
            const tgt = std.mem.readInt(u16, frame.bytecode[targets_base + 2 * i ..][0..2], .little);
            log.debug("  LOOKUPSWITCH_W key=0x{x:0>8} matched [{d}] → 0x{x:0>4}", .{ key, i, tgt });
            frame.pc = tgt;
            return;
        }
    }
    log.debug("  LOOKUPSWITCH_W key=0x{x:0>8} default → 0x{x:0>4}", .{ key, default_pc });
    frame.pc = default_pc;
}

pub fn opTableswitch(_: *Vm, frame: *Frame, _: u8) Error!void {
    frame.alignPc();
    if (frame.pc + 6 > frame.bytecode.len) return Error.StackOverflow;
    const default_pc = std.mem.readInt(u16, frame.bytecode[frame.pc..][0..2], .little);
    const low: i16 = @bitCast(std.mem.readInt(u16, frame.bytecode[frame.pc + 2 ..][0..2], .little));
    const high: i16 = @bitCast(std.mem.readInt(u16, frame.bytecode[frame.pc + 4 ..][0..2], .little));
    const key: i32 = @bitCast(try frame.pop());

    if (key < low or key > high) {
        log.debug("  TABLESWITCH key={d} default→0x{x:0>4}", .{ key, default_pc });
        frame.pc = default_pc;
        return;
    }
    const idx: usize = @intCast(key - low);
    const table_off = frame.pc + 6 + idx * 2;
    if (table_off + 2 > frame.bytecode.len) return Error.StackOverflow;
    const target = std.mem.readInt(u16, frame.bytecode[table_off..][0..2], .little);
    log.debug("  TABLESWITCH key={d} [low={d}..high={d}] → 0x{x:0>4}", .{ key, low, high, target });
    frame.pc = target;
}
