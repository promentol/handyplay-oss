//! `Frame` — one execution frame in the bytecode VM. Mirrors
//! `dword_51F904`'s layout in `ref`. The operand stack and the
//! locals area are CONTIGUOUS — some opcodes (e.g. DUP_X1's `sp - 8`)
//! deliberately access "below" the conceptual operand-stack base,
//! reading into the locals area. We model this by letting `slab` span
//! BOTH locals and stack, with `sp` indexing the combined slice
//! (initial sp = locals_count).

const std = @import("std");
const cr = @import("../classfile/registry.zig");
const err = @import("error.zig");

pub const Error = err.Error;

pub const Frame = struct {
    caller: ?*Frame = null,
    method: cr.MethodInfo,
    class_hash: u32,
    bytecode: []const u8,
    /// Combined slab view: [0..locals_count) is locals, [locals_count..sp)
    /// is the operand stack contents.
    slab: []u32,
    locals_count: u32,
    sp: u32,
    pc: u32,
    /// Set by RETURN-family opcodes so the outer runFrame loop can
    /// unwind just this frame without halting the whole VM. (We can't
    /// use Vm.halted for per-frame return because callers would also
    /// short-circuit.)
    returning: bool = false,
    /// Return value(s) from the latest RETURN opcode, copied onto the
    /// caller's stack when invokeMethodInfo returns.
    ret_value: [2]u32 = .{ 0, 0 },
    ret_slots: u8 = 0,
    /// Saved return PC for the JSR/RET subroutine pair. Canonical stores
    /// this in the per-frame slot at `(VC+32)` (see JSR sub_40C8F0 /
    /// RET sub_40F9E0). Single slot ⇒ non-nested subroutines only, which
    /// matches the finally-clause pattern JSR/RET was emitted for.
    jsr_ret_pc: u32 = 0,

    pub fn push(self: *Frame, value: u32) Error!void {
        if (self.sp >= self.slab.len) return Error.StackOverflow;
        self.slab[self.sp] = value;
        self.sp += 1;
    }
    pub fn pop(self: *Frame) Error!u32 {
        // The simulator's `sp -= 4` is unchecked — it allows dipping
        // below the conceptual operand-stack base into the locals
        // area (the slab is contiguous). We match that here; only
        // bound by `sp > 0`.
        if (self.sp == 0) return Error.StackUnderflow;
        self.sp -= 1;
        return self.slab[self.sp];
    }
    pub fn alignPc(self: *Frame) void {
        self.pc = (self.pc + 1) & ~@as(u32, 1);
    }
    pub fn readU16(self: *Frame) u16 {
        self.alignPc();
        const v = std.mem.readInt(u16, self.bytecode[self.pc..][0..2], .little);
        self.pc += 2;
        return v;
    }
    pub fn readU8(self: *Frame) u8 {
        const v = self.bytecode[self.pc];
        self.pc += 1;
        return v;
    }
};
