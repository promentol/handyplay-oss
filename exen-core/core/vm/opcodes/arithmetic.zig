//! Arithmetic + bitwise + i32/i64 conversion opcodes
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

pub fn opIinc(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.pc + 2 > frame.bytecode.len) return Error.StackUnderflow;
    const slot = frame.bytecode[frame.pc];
    const inc: i8 = @bitCast(frame.bytecode[frame.pc + 1]);
    frame.pc += 2;
    if (slot >= frame.locals_count) return Error.StackUnderflow;
    const cur: i32 = @bitCast(frame.slab[slot]);
    frame.slab[slot] = @bitCast(cur + @as(i32, inc));
}

// opcode 0x94 (LCMP) — canonical sub_40CC67 (ref:11294):
//   SP -= 16; v1 = SP;                          // pop 4 slots = 2 longs
//   if (*(u64*)v1 <= *(u64*)(v1+2)) {           // unsigned 64-bit compare
//       if (v1[0]==v1[2] && v1[1]==v1[3])
//           push 0;
//       else
//           push -1;
//   } else {
//       push 1;
//   }
// Stack: ..., long1(lo,hi), long2(lo,hi) → ..., int(sign(val1 - val2))
// LCMP (opcode 0x94, sub_40CC67) — JVM spec: SIGNED 64-bit compare.
// The reference listing shows `*(_QWORD *) <= *(_QWORD *)` which
// looks unsigned, but `_QWORD` is just IDA's "64-bit value" type — the
// actual x86 `setle`/`setg` machine code is signed. The legacy
// freej2me JS emulator's LCMP at `exen-player/src/emulator/opcodes.js:702`
// builds a signed BigInt (hi << 32 | (lo >>> 0) preserves hi's sign)
// and compares signed; that matches JVM spec and the games it runs.
// Treating LCMP as unsigned broke Banjo's elapsed-time gate (high bit
// of u32 ms-since-epoch makes `now < start` evaluate wrong unsigned).
pub fn opLcmp(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a: i64 = @bitCast((@as(u64, a_hi) << 32) | a_lo);
    const b: i64 = @bitCast((@as(u64, b_hi) << 32) | b_lo);
    frame.sp -= 4;
    const result: u32 = if (a < b) @bitCast(@as(i32, -1)) else if (a > b) 1 else 0;
    try frame.push(result);
}

// opcode 0x85 (I2L) — canonical sub_40AE2B (ref:10019):
//   SP -= 4;
//   *(_QWORD *)SP = *(int*)SP;   // C-promotion sign-extends int to int64
//   SP += 8;
// Net: pop one int slot, push a 2-slot long with sign-extended value.
// Stack layout: ..., int → ..., long(lo, hi). long is 2 slots, lo at lower SP.
pub fn opI2l(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    const v: i32 = @bitCast(frame.slab[frame.sp - 1]);
    const sx: i64 = v;
    frame.slab[frame.sp - 1] = @truncate(@as(u64, @bitCast(sx)));
    try frame.push(@truncate(@as(u64, @bitCast(sx)) >> 32));
}

// opcode 0x91 (I2B) — canonical sub_40ADC0 (ref:9980):
//   result = (unsigned __int8) *top;   // truncate to u8 (zero-extend)
//   *top   = (char) result;            // cast to i8 → sign-extend to int
pub fn opI2b(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    const v = frame.slab[frame.sp - 1];
    const b: i8 = @bitCast(@as(u8, @truncate(v)));
    const sx: i32 = b;
    frame.slab[frame.sp - 1] = @bitCast(sx);
}

// opcode 0x92 (I2C) — canonical sub_40ADE8 (ref:9992):
//   result = *(unsigned __int8 *) top;  // read top low byte as u8
//   *top   = result;                    // store back zero-extended
// ExEn treats char as byte-packed (NOT 16-bit per JVM spec), so I2C
// truncates to u8 and zero-extends — equivalent to `&= 0xFF`.
pub fn opI2c(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    frame.slab[frame.sp - 1] &= 0xFF;
}

// opcode 0x93 (I2S) — canonical sub_40AE0A (ref:10005):
//   v0     = (__int16 *) top;
//   result = *v0;                       // read low 16 bits as signed
//   *(_DWORD *)v0 = result;             // write back sign-extended
pub fn opI2s(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp == 0) return Error.StackUnderflow;
    const v = frame.slab[frame.sp - 1];
    const s: i16 = @bitCast(@as(u16, @truncate(v)));
    const sx: i32 = s;
    frame.slab[frame.sp - 1] = @bitCast(sx);
}

pub fn opIadd(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    const sum: u32 = a +% b;
    try frame.push(sum);
}

pub fn opIsub(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    const diff: u32 = a -% b;
    try frame.push(diff);
}

pub fn opImul(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    const prod: u32 = a *% b;
    try frame.push(prod);
}

pub fn opLadd(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    const a: u64 = (@as(u64, a_hi) << 32) | a_lo;
    const b: u64 = (@as(u64, b_hi) << 32) | b_lo;
    const r: u64 = a +% b;
    frame.sp -= 4;
    frame.slab[frame.sp] = @truncate(r);
    frame.slab[frame.sp + 1] = @truncate(r >> 32);
    frame.sp += 2;
}

/// LMUL (opcode 0x69, sub_40D1E4 at ref:11540).
/// Canonical body:
///   SP -= 16;                       // pop 4 slots (= 2 longs)
///   *(QWORD*)SP *= *(QWORD*)(SP+8); // 64-bit signed multiply, wrap on overflow
///   SP += 8;                        // push 2 slots (= 1 long result)
/// Net SP delta: -16 + 8 = -8 bytes (= -2 slots).
pub fn opLmul(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    const a: u64 = (@as(u64, a_hi) << 32) | a_lo;
    const b: u64 = (@as(u64, b_hi) << 32) | b_lo;
    const r: u64 = a *% b;
    frame.sp -= 4;
    frame.slab[frame.sp] = @truncate(r);
    frame.slab[frame.sp + 1] = @truncate(r >> 32);
    frame.sp += 2;
}

/// LREM (opcode 0x71, sub_40D4C0 at ref:11655) — long remainder.
/// Canonical body:
///   SP -= 16;                                                 // pop 4 slots
///   if (divisor != 0 && !(divisor == LONG_MIN && dividend == LONG_MIN)) {
///       *(int64*)SP = *(int64*)SP % *(int64*)(SP+8);
///       SP += 8;                                              // push long result
///       return SP;                                            // success path
///   }
///   *(dword_51F900 + 28) = -2030684661;                       // fault code
///   return sub_409580();                                      // early return — no push, SP stays at -16
///
/// Net SP delta: success = -8 bytes (-2 slots); fault = -16 bytes (-4 slots).
/// We halt the VM on either fault — matches `vm.signalFault` for canonical
/// non-catcheable abort semantics.
pub fn opLrem(vm: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    const a: i64 = @bitCast((@as(u64, a_hi) << 32) | a_lo);
    const b: i64 = @bitCast((@as(u64, b_hi) << 32) | b_lo);
    // Canonical fault: divisor == 0 OR (dividend == LONG_MIN AND divisor == LONG_MIN).
    // The fault branch sets dword_51F900[28] = 0x870e0e0b (cast of -2030684661
    // = 0x870E0E0B) and early-returns via sub_409580 — never pushes a result.
    if (b == 0 or (a == std.math.minInt(i64) and b == std.math.minInt(i64))) {
        frame.sp -= 4; // canonical SP -= 16 only; no SP += 8 on fault path
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = 0 };
        return;
    }
    const result: i64 = @rem(a, b);
    const r_u: u64 = @bitCast(result);
    frame.sp -= 4;
    frame.slab[frame.sp] = @truncate(r_u);
    frame.slab[frame.sp + 1] = @truncate(r_u >> 32);
    frame.sp += 2;
}

/// LAND (opcode 0x7f, sub_40CB3B at ref:11232) — long bitwise AND.
/// Canonical body:
///   SP -= 16;                       // pop 4 slots (= 2 longs)
///   v2[0] = v2[0] & v2[2];          // a_lo &= b_lo
///   v2[1] = v2[1] & v2[3];          // a_hi &= b_hi
///   SP += 8;                        // push 2 slots (= 1 long result)
/// Net SP delta: -16 + 8 = -8 bytes (= -2 slots).
pub fn opLand(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    frame.sp -= 4;
    frame.slab[frame.sp] = a_lo & b_lo;
    frame.slab[frame.sp + 1] = a_hi & b_hi;
    frame.sp += 2;
}

/// LSHR (opcode 0x7b, sub_40D645 at ref:11714) — signed long right shift.
/// Canonical body:
///   SP -= 12;                                    // pop 3 slots (long + int-shift)
///   *(int64*)SP >>= *(DWORD*)(SP + 8);           // signed >> in place
///   SP += 8;                                     // push 2 slots (long result)
/// Net SP delta: -12 + 8 = -4 bytes (= -1 slot).
/// Per JVM spec the shift count is masked with 0x3F (low 6 bits) for longs.
pub fn opLshr(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 3) return Error.StackUnderflow;
    const shift_u32 = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 3];
    const a_hi = frame.slab[frame.sp - 2];
    const a: i64 = @bitCast((@as(u64, a_hi) << 32) | a_lo);
    const shift: u6 = @truncate(shift_u32 & 0x3F);
    const r: i64 = a >> shift;
    const r_u: u64 = @bitCast(r);
    frame.sp -= 3;
    frame.slab[frame.sp] = @truncate(r_u);
    frame.slab[frame.sp + 1] = @truncate(r_u >> 32);
    frame.sp += 2;
}

pub fn opIrem(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    if (b == 0 or (b == -1 and a == std.math.minInt(i32))) {
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = 0 };
        return;
    }
    try frame.push(@bitCast(@rem(a, b)));
}

pub fn opIdiv(vm: *Vm, frame: *Frame, _: u8) Error!void {
    const b: i32 = @bitCast(try frame.pop());
    const a: i32 = @bitCast(try frame.pop());
    if (b == 0 or (b == -1 and a == std.math.minInt(i32))) {
        vm.halted = true;
        vm.halt_reason = .{ .method_not_found = 0 };
        return;
    }
    try frame.push(@bitCast(@divTrunc(a, b)));
}

pub fn opIneg(_: *Vm, frame: *Frame, _: u8) Error!void {
    const v: i32 = @bitCast(try frame.pop());
    try frame.push(@bitCast(-%v));
}

pub fn opIshl(_: *Vm, frame: *Frame, _: u8) Error!void {
    const s = try frame.pop();
    const v = try frame.pop();
    try frame.push(v << @intCast(s & 0x1F));
}

pub fn opIshr(_: *Vm, frame: *Frame, _: u8) Error!void {
    const s = try frame.pop();
    const v: i32 = @bitCast(try frame.pop());
    const shift: u5 = @intCast(s & 0x1F);
    const r: i32 = v >> shift;
    try frame.push(@bitCast(r));
}

pub fn opIushr(_: *Vm, frame: *Frame, _: u8) Error!void {
    const s = try frame.pop();
    const v = try frame.pop();
    try frame.push(v >> @intCast(s & 0x1F));
}

pub fn opIand(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    try frame.push(a & b);
}

pub fn opIor(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    try frame.push(a | b);
}

pub fn opIxor(_: *Vm, frame: *Frame, _: u8) Error!void {
    const b = try frame.pop();
    const a = try frame.pop();
    try frame.push(a ^ b);
}

pub fn opLsub(_: *Vm, frame: *Frame, _: u8) Error!void {
    if (frame.sp < 4) return Error.StackUnderflow;
    const b_lo = frame.slab[frame.sp - 2];
    const b_hi = frame.slab[frame.sp - 1];
    const a_lo = frame.slab[frame.sp - 4];
    const a_hi = frame.slab[frame.sp - 3];
    const a: u64 = (@as(u64, a_hi) << 32) | a_lo;
    const b: u64 = (@as(u64, b_hi) << 32) | b_lo;
    const r: u64 = a -% b;
    frame.sp -= 4;
    frame.slab[frame.sp] = @truncate(r);
    frame.slab[frame.sp + 1] = @truncate(r >> 32);
    frame.sp += 2;
}
