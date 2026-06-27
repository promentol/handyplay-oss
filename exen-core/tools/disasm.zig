//! TheTerminator disassembler — dumps every class, every method, and
//! the full bytecode stream with opcode names + immediate operands.
//!
//!   zig run disasm.zig                          → dumps TheTerminator.exn to stdout
//!   zig run disasm.zig -- catalog.exn           → dumps the given .exn
//!   zig run disasm.zig -- TheTerminator.exn 4   → dumps only class index 4
//!
//! Operand decoding follows the JVM/ExEn 2 convention recovered in
//! `interp.zig`. The class file format is 4CVP, parsed via the
//! existing class_registry module.
const std = @import("std");
const class_registry = @import("../core/classfile/registry.zig");

const Op = struct {
    name: []const u8,
    /// Number of immediate operand bytes (after the opcode byte). -1
    /// = variable (TABLESWITCH / LOOKUPSWITCH — handled out-of-band).
    operands: i32,
};

/// 256-entry ExEn 2 dispatch table. Source of truth: the 258-entry
/// `off_454498[]` function-pointer table at ref:1520 — slots
/// pointing to `sub_4102CF` are the unknown-opcode trap and treated
/// as `?` here. Names match `exen/docs/opcodes.md` (which is also
/// derived from the same ref table).
///
/// Operand-width convention:
///   `operands = 0`   no immediate
///   `operands = 1`   one u8 immediate
///   `operands = 2`   one 2-byte-aligned u16 immediate (PC = (PC+1) & ~1)
///   `operands = -1`  variable (TABLESWITCH / LOOKUPSWITCH)
///   `operands = -2`  IINC: u8 idx + s8 delta (no alignment)
const OPS = blk: {
    var t: [256]Op = [_]Op{.{ .name = "?", .operands = 0 }} ** 256;

    // 0x00..0x0A — constants & null push
    t[0x00] = .{ .name = "NOP", .operands = 0 };
    t[0x01] = .{ .name = "ACONST_NULL", .operands = 0 };
    t[0x02] = .{ .name = "ICONST_M1", .operands = 0 };
    t[0x03] = .{ .name = "ICONST_0", .operands = 0 };
    t[0x04] = .{ .name = "ICONST_1", .operands = 0 };
    t[0x05] = .{ .name = "ICONST_2", .operands = 0 };
    t[0x06] = .{ .name = "ICONST_3", .operands = 0 };
    t[0x07] = .{ .name = "ICONST_4", .operands = 0 };
    t[0x08] = .{ .name = "ICONST_5", .operands = 0 };
    t[0x09] = .{ .name = "LCONST_0", .operands = 0 };
    t[0x0A] = .{ .name = "LCONST_1", .operands = 0 };

    // 0x0B..0x0F — float/double constants (JVM standard)
    t[0x0B] = .{ .name = "FCONST_0", .operands = 0 };
    t[0x0C] = .{ .name = "FCONST_1", .operands = 0 };
    t[0x0D] = .{ .name = "FCONST_2", .operands = 0 };
    t[0x0E] = .{ .name = "DCONST_0", .operands = 0 };
    t[0x0F] = .{ .name = "DCONST_1", .operands = 0 };

    // 0x10..0x14 — pushes with operands
    t[0x10] = .{ .name = "BIPUSH", .operands = 1 };
    t[0x11] = .{ .name = "SIPUSH", .operands = 2 };
    t[0x12] = .{ .name = "LDC_W", .operands = 2 };
    t[0x14] = .{ .name = "LDC2_W", .operands = 2 };

    // 0x15..0x29 — JVM-style typed loads (the gamelet uses ExEn's
    // 0xD5/0xD9..0xE8 forms; including these names so misaligned
    // reads remain intelligible).
    t[0x15] = .{ .name = "ILOAD_J", .operands = 1 };
    t[0x16] = .{ .name = "LLOAD_J", .operands = 1 };
    t[0x17] = .{ .name = "FLOAD", .operands = 1 };
    t[0x18] = .{ .name = "DLOAD", .operands = 1 };
    t[0x1A] = .{ .name = "ILOAD_0_J", .operands = 0 };
    t[0x1B] = .{ .name = "ILOAD_1_J", .operands = 0 };
    t[0x1C] = .{ .name = "ILOAD_2_J", .operands = 0 };
    t[0x1D] = .{ .name = "ILOAD_3_J", .operands = 0 };
    t[0x1E] = .{ .name = "LLOAD_0_J", .operands = 0 };
    t[0x1F] = .{ .name = "LLOAD_1_J", .operands = 0 };
    t[0x20] = .{ .name = "LLOAD_2_J", .operands = 0 };
    t[0x21] = .{ .name = "LLOAD_3_J", .operands = 0 };
    t[0x22] = .{ .name = "FLOAD_0", .operands = 0 };
    t[0x23] = .{ .name = "FLOAD_1", .operands = 0 };
    t[0x24] = .{ .name = "FLOAD_2", .operands = 0 };
    t[0x25] = .{ .name = "FLOAD_3", .operands = 0 };
    t[0x26] = .{ .name = "DLOAD_0", .operands = 0 };
    t[0x27] = .{ .name = "DLOAD_1", .operands = 0 };
    t[0x28] = .{ .name = "DLOAD_2", .operands = 0 };
    t[0x29] = .{ .name = "DLOAD_3", .operands = 0 };

    // 0x36..0x46 — JVM-style typed stores
    t[0x36] = .{ .name = "ISTORE_J", .operands = 1 };
    t[0x37] = .{ .name = "LSTORE_J", .operands = 1 };
    t[0x38] = .{ .name = "FSTORE", .operands = 1 };
    t[0x39] = .{ .name = "DSTORE", .operands = 1 };
    t[0x3B] = .{ .name = "ISTORE_0_J", .operands = 0 };
    t[0x3C] = .{ .name = "ISTORE_1_J", .operands = 0 };
    t[0x3D] = .{ .name = "ISTORE_2_J", .operands = 0 };
    t[0x3E] = .{ .name = "ISTORE_3_J", .operands = 0 };
    t[0x3F] = .{ .name = "LSTORE_0_J", .operands = 0 };
    t[0x40] = .{ .name = "LSTORE_1_J", .operands = 0 };
    t[0x41] = .{ .name = "LSTORE_2_J", .operands = 0 };
    t[0x42] = .{ .name = "LSTORE_3_J", .operands = 0 };
    t[0x43] = .{ .name = "FSTORE_0", .operands = 0 };
    t[0x44] = .{ .name = "FSTORE_1", .operands = 0 };
    t[0x45] = .{ .name = "FSTORE_2", .operands = 0 };
    t[0x46] = .{ .name = "FSTORE_3", .operands = 0 };
    t[0x50] = .{ .name = "LASTORE", .operands = 0 };
    t[0x51] = .{ .name = "FASTORE", .operands = 0 };

    // 0x62..0x76 — float arithmetic
    t[0x62] = .{ .name = "FADD", .operands = 0 };
    t[0x63] = .{ .name = "DADD", .operands = 0 };
    t[0x66] = .{ .name = "FSUB", .operands = 0 };
    t[0x67] = .{ .name = "DSUB", .operands = 0 };
    t[0x6A] = .{ .name = "FMUL", .operands = 0 };
    t[0x6B] = .{ .name = "DMUL", .operands = 0 };
    t[0x6E] = .{ .name = "FDIV", .operands = 0 };
    t[0x6F] = .{ .name = "DDIV", .operands = 0 };
    t[0x72] = .{ .name = "FREM", .operands = 0 };
    t[0x73] = .{ .name = "DREM", .operands = 0 };
    t[0x76] = .{ .name = "FNEG", .operands = 0 };
    t[0x77] = .{ .name = "DNEG", .operands = 0 };

    // 0x86..0x90 — conversions
    t[0x86] = .{ .name = "I2F", .operands = 0 };
    t[0x87] = .{ .name = "I2D", .operands = 0 };
    t[0x89] = .{ .name = "L2F", .operands = 0 };
    t[0x8A] = .{ .name = "L2D", .operands = 0 };
    t[0x8B] = .{ .name = "F2I", .operands = 0 };
    t[0x8C] = .{ .name = "F2L", .operands = 0 };
    t[0x8D] = .{ .name = "F2D", .operands = 0 };
    t[0x8E] = .{ .name = "D2I", .operands = 0 };
    t[0x8F] = .{ .name = "D2L", .operands = 0 };
    t[0x90] = .{ .name = "D2F", .operands = 0 };

    // 0x95..0x98 — float comparisons
    t[0x95] = .{ .name = "FCMPL", .operands = 0 };
    t[0x96] = .{ .name = "FCMPG", .operands = 0 };
    t[0x97] = .{ .name = "DCMPL", .operands = 0 };
    t[0x98] = .{ .name = "DCMPG", .operands = 0 };

    // 0xAD..0xAF — JVM typed returns
    t[0xAD] = .{ .name = "LRETURN_J", .operands = 0 };
    t[0xAE] = .{ .name = "FRETURN", .operands = 0 };
    t[0xAF] = .{ .name = "DRETURN", .operands = 0 };

    // 0xB2..0xBA — JVM field/invoke (ExEn equivalents at 0xF3..0xFA)
    t[0xB2] = .{ .name = "GETSTATIC_J", .operands = 2 };
    t[0xB3] = .{ .name = "PUTSTATIC_J", .operands = 2 };
    t[0xB4] = .{ .name = "GETFIELD_J", .operands = 2 };
    t[0xB5] = .{ .name = "PUTFIELD_J", .operands = 2 };
    t[0xB6] = .{ .name = "INVOKEVIRTUAL_J", .operands = 2 };
    t[0xB7] = .{ .name = "INVOKESPECIAL_J", .operands = 2 };
    t[0xB8] = .{ .name = "INVOKESTATIC_J", .operands = 2 };
    t[0xB9] = .{ .name = "INVOKEINTERFACE_J", .operands = 2 };
    t[0xBA] = .{ .name = "INVOKEDYNAMIC", .operands = 2 };
    t[0xBD] = .{ .name = "ANEWARRAY", .operands = 2 };

    // 0xC8/0xC9 — wide GOTO/JSR
    t[0xC8] = .{ .name = "GOTO_W", .operands = 2 };
    t[0xC9] = .{ .name = "JSR_W", .operands = 2 };
    t[0xCA] = .{ .name = "BREAKPOINT", .operands = 0 };
    t[0xCB] = .{ .name = "OP_CB", .operands = 0 };

    // 0xD1..0xD4 — ExEn extensions (TBD)
    t[0xD1] = .{ .name = "OP_D1", .operands = 0 };
    t[0xD2] = .{ .name = "OP_D2", .operands = 0 };
    t[0xD3] = .{ .name = "OP_D3", .operands = 0 };
    t[0xD4] = .{ .name = "OP_D4", .operands = 0 };

    // 0xFC..0xFF — ExEn extensions (TBD)
    t[0xFC] = .{ .name = "OP_FC", .operands = 0 };
    t[0xFD] = .{ .name = "OP_FD", .operands = 0 };
    t[0xFE] = .{ .name = "OP_FE", .operands = 0 };
    t[0xFF] = .{ .name = "OP_FF", .operands = 0 };

    // ALOAD / ALOAD_0..3
    t[0x19] = .{ .name = "ALOAD", .operands = 1 };
    t[0x2A] = .{ .name = "ALOAD_0", .operands = 0 };
    t[0x2B] = .{ .name = "ALOAD_1", .operands = 0 };
    t[0x2C] = .{ .name = "ALOAD_2", .operands = 0 };
    t[0x2D] = .{ .name = "ALOAD_3", .operands = 0 };

    // Typed array loads (TALOAD₁..TALOAD₅, AALOAD)
    t[0x2E] = .{ .name = "TALOAD1", .operands = 0 };
    t[0x2F] = .{ .name = "TALOAD2", .operands = 0 };
    t[0x32] = .{ .name = "AALOAD", .operands = 0 };
    t[0x33] = .{ .name = "TALOAD3", .operands = 0 };
    t[0x34] = .{ .name = "TALOAD4", .operands = 0 };
    t[0x35] = .{ .name = "TALOAD5", .operands = 0 };

    // ASTORE family (positions verified against ref table)
    t[0x3A] = .{ .name = "ASTORE", .operands = 1 };
    t[0x4B] = .{ .name = "ASTORE_0", .operands = 0 };
    t[0x4C] = .{ .name = "ASTORE_1", .operands = 0 };
    t[0x4D] = .{ .name = "ASTORE_2", .operands = 0 };
    t[0x4E] = .{ .name = "ASTORE_3", .operands = 0 };

    // Typed array stores (positions verified)
    t[0x4F] = .{ .name = "TASTORE1", .operands = 0 };
    t[0x50] = .{ .name = "TASTORE_LONG", .operands = 0 };
    t[0x53] = .{ .name = "AASTORE", .operands = 0 };
    t[0x54] = .{ .name = "TASTORE2", .operands = 0 };
    t[0x55] = .{ .name = "TASTORE3", .operands = 0 };
    t[0x56] = .{ .name = "TASTORE4", .operands = 0 };

    // Stack manipulation (positions verified)
    t[0x57] = .{ .name = "POP", .operands = 0 };
    t[0x58] = .{ .name = "POP2", .operands = 0 };
    t[0x59] = .{ .name = "DUP", .operands = 0 };
    t[0x5A] = .{ .name = "DUP_X1", .operands = 0 };
    t[0x5B] = .{ .name = "ROT3_F", .operands = 0 };
    t[0x5C] = .{ .name = "DUP2", .operands = 0 };
    t[0x5D] = .{ .name = "ROT3_B", .operands = 0 };
    t[0x5E] = .{ .name = "PERM4", .operands = 0 };
    t[0x5F] = .{ .name = "SWAP", .operands = 0 };

    // Arithmetic (interp.zig uses JVM-compatible bindings here:
    // IADD=0x60, ISUB=0x64, IMUL=0x68, IDIV=0x6C, etc.)
    t[0x60] = .{ .name = "IADD", .operands = 0 };
    t[0x61] = .{ .name = "LADD", .operands = 0 };
    t[0x64] = .{ .name = "ISUB", .operands = 0 };
    t[0x65] = .{ .name = "LSUB", .operands = 0 };
    t[0x68] = .{ .name = "IMUL", .operands = 0 };
    t[0x69] = .{ .name = "LMUL", .operands = 0 };
    t[0x6C] = .{ .name = "IDIV", .operands = 0 };
    t[0x6D] = .{ .name = "LDIV", .operands = 0 };
    t[0x70] = .{ .name = "IREM", .operands = 0 };
    t[0x71] = .{ .name = "LREM", .operands = 0 };
    t[0x74] = .{ .name = "INEG", .operands = 0 };
    t[0x75] = .{ .name = "LNEG", .operands = 0 };
    t[0x78] = .{ .name = "ISHL", .operands = 0 };
    t[0x79] = .{ .name = "LSHL", .operands = 0 };
    t[0x7A] = .{ .name = "ISHR", .operands = 0 };
    t[0x7B] = .{ .name = "LSHR", .operands = 0 };
    t[0x7C] = .{ .name = "IUSHR", .operands = 0 };
    t[0x7D] = .{ .name = "LUSHR", .operands = 0 };
    t[0x7E] = .{ .name = "IAND", .operands = 0 };
    t[0x7F] = .{ .name = "LAND", .operands = 0 };
    t[0x80] = .{ .name = "IOR", .operands = 0 };
    t[0x81] = .{ .name = "LOR", .operands = 0 };
    t[0x82] = .{ .name = "IXOR", .operands = 0 };
    t[0x83] = .{ .name = "LXOR", .operands = 0 };
    t[0x84] = .{ .name = "IINC", .operands = -2 };

    // Conversions
    t[0x85] = .{ .name = "I2L", .operands = 0 };
    t[0x88] = .{ .name = "L2I", .operands = 0 };
    t[0x91] = .{ .name = "I2B", .operands = 0 };
    t[0x92] = .{ .name = "I2C", .operands = 0 };
    t[0x93] = .{ .name = "I2S", .operands = 0 };
    t[0x94] = .{ .name = "LCMP", .operands = 0 };

    // Conditional branches — IFEQ..IFLE / IF_ICMP* / IF_ACMP* / GOTO
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
    t[0xA5] = .{ .name = "IFNULL", .operands = 2 }; // ExEn alias also used for ACMPEQ
    t[0xA6] = .{ .name = "IFNONNULL", .operands = 2 };
    t[0xA7] = .{ .name = "GOTO", .operands = 2 };
    t[0xA8] = .{ .name = "JSR", .operands = 2 };
    t[0xA9] = .{ .name = "RET", .operands = 0 };
    t[0xAA] = .{ .name = "TABLESWITCH", .operands = -1 };
    t[0xAB] = .{ .name = "LOOKUPSWITCH", .operands = -1 };

    // Returns
    t[0xAC] = .{ .name = "IRETURN", .operands = 0 };
    t[0xB0] = .{ .name = "ARETURN", .operands = 0 };
    t[0xB1] = .{ .name = "RETURN", .operands = 0 };

    // NEW / NEWARRAY / ARRAYLENGTH
    t[0xBB] = .{ .name = "NEW", .operands = 2 };
    t[0xBC] = .{ .name = "NEWARRAY", .operands = 2 };
    t[0xBE] = .{ .name = "ARRAYLENGTH", .operands = 0 };
    t[0xBF] = .{ .name = "ATHROW", .operands = 0 };
    t[0xC0] = .{ .name = "OP_C0", .operands = 2 }; // peephole jump-marker; reads u16 but doesn't branch
    t[0xC1] = .{ .name = "CHECKCAST_INDIRECT", .operands = 2 };
    t[0xC2] = .{ .name = "NOP_C2", .operands = 0 };
    t[0xC3] = .{ .name = "NOP_C3", .operands = 0 };
    t[0xC5] = .{ .name = "MULTIANEWARRAY", .operands = 2 }; // 1 byte dim + 2-aligned u16 class
    t[0xC6] = .{ .name = "IFNULL", .operands = 2 };
    t[0xC7] = .{ .name = "IFNONNULL", .operands = 2 };

    // Lookup/Table switches (ExEn flavours)
    t[0xCC] = .{ .name = "LOOKUPSWITCH_INDIRECT", .operands = -1 };
    t[0xCD] = .{ .name = "TABLESWITCH_RANGE", .operands = -1 };
    t[0xD0] = .{ .name = "LDC_STRING", .operands = 2 };

    // ExEn integer/long local-variable ops
    t[0xD5] = .{ .name = "ILOAD", .operands = 1 };
    t[0xD6] = .{ .name = "ISTORE", .operands = 1 };
    t[0xD7] = .{ .name = "LLOAD", .operands = 1 };
    t[0xD8] = .{ .name = "LSTORE", .operands = 1 };
    t[0xD9] = .{ .name = "ILOAD_0", .operands = 0 };
    t[0xDA] = .{ .name = "ISTORE_0", .operands = 0 };
    t[0xDB] = .{ .name = "LLOAD_0", .operands = 0 };
    t[0xDC] = .{ .name = "LSTORE_0", .operands = 0 };
    t[0xDD] = .{ .name = "ILOAD_1", .operands = 0 };
    t[0xDE] = .{ .name = "ISTORE_1", .operands = 0 };
    t[0xDF] = .{ .name = "LLOAD_1", .operands = 0 };
    t[0xE0] = .{ .name = "LSTORE_1", .operands = 0 };
    t[0xE1] = .{ .name = "ILOAD_2", .operands = 0 };
    t[0xE2] = .{ .name = "ISTORE_2", .operands = 0 };
    t[0xE3] = .{ .name = "LLOAD_2", .operands = 0 };
    t[0xE4] = .{ .name = "LSTORE_2", .operands = 0 };
    t[0xE5] = .{ .name = "ILOAD_3", .operands = 0 };
    t[0xE6] = .{ .name = "ISTORE_3", .operands = 0 };
    t[0xE7] = .{ .name = "LLOAD_3", .operands = 0 };
    t[0xE8] = .{ .name = "LSTORE_3", .operands = 0 };
    t[0xE9] = .{ .name = "IRETURN", .operands = 0 };
    t[0xEA] = .{ .name = "LRETURN", .operands = 0 };

    // Invokes — these positions match the bytecode TheTerminator.exn
    // actually emits (and what `interp.zig` dispatches). They differ
    // from ref's authoritative off_454498[] by one slot;
    // realigning to that table causes the gamelet to StackUnderflow
    // on its first virtual call. Naming reflects empirical
    // interp.zig behaviour.
    t[0xED] = .{ .name = "INVOKEVIRTUAL_ALT", .operands = 2 };
    t[0xEE] = .{ .name = "INVOKEVIRTUAL", .operands = 2 };
    t[0xEF] = .{ .name = "INVOKE_OWN", .operands = 2 };
    t[0xF0] = .{ .name = "INVOKESPECIAL", .operands = 2 };
    t[0xF1] = .{ .name = "INVOKESTATIC_ALT", .operands = 2 };
    t[0xF2] = .{ .name = "INVOKESTATIC", .operands = 2 };

    // Field / static access — same offset-from-canonical convention.
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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse "TheTerminator.exn";
    const filter_class: ?u16 = if (args.next()) |s| std.fmt.parseInt(u16, s, 10) catch null else null;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 16 << 20);
    defer allocator.free(raw);

    // The class records start after the simulator's offset table.
    // Same logic as exen.zig:loadExn — read the sentinel at file
    // offset 0x38 + 4*method_count.
    const method_count = std.mem.readInt(u32, raw[0x34..][0..4], .little);
    const sentinel_off = 0x38 + 4 * method_count;
    const tail_start = std.mem.readInt(u32, raw[sentinel_off..][0..4], .little);

    var reg = class_registry.Registry.init(allocator);
    defer reg.deinit();
    const n = try reg.scanBuffer(raw, tail_start, .gamelet);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    try stdout.print("=== {s}: {d} classes (tail_start=0x{x:0>5}) ===\n\n", .{ path, n, tail_start });

    var class_idx: u16 = 0;
    while (class_idx < n) : (class_idx += 1) {
        if (filter_class) |want| {
            if (class_idx != want) continue;
        }
        const hash = reg.by_index.get(class_idx) orelse continue;
        const cls = reg.lookup(hash) orelse continue;
        try dumpClass(stdout, class_idx, cls);
    }
}

fn dumpClass(out: anytype, idx: u16, cls: class_registry.ClassRecord) !void {
    const mc = cls.methodCount();
    const fc = cls.fieldCount();
    try out.print("─" ** 80 ++ "\n", .{});
    try out.print("CLASS[{d}] 0x{x:0>8}  size={d} bytes  methods={d}  fields={d}\n", .{
        idx, cls.hash, cls.bytes.len, mc, fc,
    });
    try out.print("─" ** 80 ++ "\n", .{});

    // Field table.
    if (fc > 0) {
        try out.print("  FIELDS:\n", .{});
        var p = cls.firstFieldInfoOffset();
        var i: u16 = 0;
        while (i < fc) : (i += 1) {
            if (p + 12 > cls.bytes.len) break;
            const h = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
            const tag = std.mem.readInt(u16, cls.bytes[p + 6 ..][0..2], .little);
            const slot = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
            try out.print("    [{d:>2}] hash=0x{x:0>8} tag=0x{x:0>4} slot={d}\n", .{ i, h, tag, slot });
            p = (p + 15) & ~@as(usize, 3);
        }
        try out.print("\n", .{});
    }

    // Methods.
    var p = cls.firstMethodInfoOffset();
    var i: u16 = 0;
    while (i < mc) : (i += 1) {
        if (p + 12 > cls.bytes.len) break;
        const h = std.mem.readInt(u32, cls.bytes[p..][0..4], .little);
        const flags = std.mem.readInt(u16, cls.bytes[p + 4 ..][0..2], .little);
        const arg_count = std.mem.readInt(u16, cls.bytes[p + 6 ..][0..2], .little);
        const body_off = std.mem.readInt(u16, cls.bytes[p + 8 ..][0..2], .little);
        const is_native = (flags & 0x100) != 0;
        try out.print("  METHOD[{d:>2}] 0x{x:0>8}  flags=0x{x:0>4} args={d} body=0x{x:0>4}  ", .{
            i, h, flags, arg_count, body_off,
        });
        if (is_native) {
            const idx_native = std.mem.readInt(u32, cls.bytes[body_off..][0..4], .little);
            try out.print("NATIVE [{d}]\n", .{idx_native});
        } else {
            const max_stack = std.mem.readInt(u16, cls.bytes[body_off..][0..2], .little);
            const locals = std.mem.readInt(u16, cls.bytes[body_off + 2 ..][0..2], .little);
            const code_off = body_off + 6;
            // body extends to either the next method's body_off or
            // the class's end; we walk until RETURN/IRETURN/ARETURN
            // to find a sensible cap.
            try out.print("BYTECODE  max_stack={d} locals={d}\n", .{ max_stack, locals });
            try dumpBytecode(out, cls.bytes, code_off);
        }
        p = (p + 15) & ~@as(usize, 3);
    }
    try out.print("\n", .{});
}

fn dumpBytecode(out: anytype, bytes: []const u8, start: usize) !void {
    var pc: usize = start;
    while (pc < bytes.len) {
        const op = bytes[pc];
        const info = OPS[op];
        try out.print("    {x:0>4}: {x:0>2}  {s:<16}", .{ pc - start, op, info.name });
        if (info.operands == -2) {
            // IINC: u8 slot, s8 delta — no alignment.
            if (pc + 3 > bytes.len) {
                try out.print("(truncated)\n", .{});
                break;
            }
            const slot = bytes[pc + 1];
            const delta: i8 = @bitCast(bytes[pc + 2]);
            try out.print("slot={d} delta={d}\n", .{ slot, delta });
            pc += 3;
        } else if (info.operands == -1) {
            // TABLESWITCH / LOOKUPSWITCH — pad to 2-byte boundary,
            // read default(2) + low(2) + high(2), then (high-low+1)
            // pairs of 2 bytes. We approximate.
            const aligned = (pc + 1 + 1) & ~@as(usize, 1);
            if (op == 0xAA) {
                if (aligned + 6 > bytes.len) break;
                const def = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                const lo = std.mem.readInt(i16, bytes[aligned + 2 ..][0..2], .little);
                const hi = std.mem.readInt(i16, bytes[aligned + 4 ..][0..2], .little);
                try out.print("default=0x{x:0>4} low={d} high={d}\n", .{ def, lo, hi });
                const span: i32 = @as(i32, hi) - @as(i32, lo) + 1;
                const count: usize = if (span > 0) @intCast(span) else 0;
                pc = aligned + 6 + count * 2;
            } else { // LOOKUPSWITCH
                if (aligned + 4 > bytes.len) break;
                const def = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                const npairs = std.mem.readInt(u16, bytes[aligned + 2 ..][0..2], .little);
                try out.print("default=0x{x:0>4} npairs={d}\n", .{ def, npairs });
                pc = aligned + 4 + @as(usize, npairs) * 4;
            }
        } else if (info.operands == 0) {
            try out.print("\n", .{});
            pc += 1;
        } else {
            const n: usize = @intCast(info.operands);
            if (n == 2) {
                // 2-byte-aligned u16: PC = (PC + 1 + 1) & ~1, then
                // read 2 bytes from the aligned position.
                const aligned = (pc + 2) & ~@as(usize, 1);
                if (aligned + 2 > bytes.len) {
                    try out.print("(truncated)\n", .{});
                    break;
                }
                const v = std.mem.readInt(u16, bytes[aligned..][0..2], .little);
                try out.print("0x{x:0>4}\n", .{v});
                pc = aligned + 2;
            } else if (n == 1) {
                if (pc + 2 > bytes.len) {
                    try out.print("(truncated)\n", .{});
                    break;
                }
                try out.print("0x{x:0>2}\n", .{bytes[pc + 1]});
                pc += 2;
            } else {
                try out.print("\n", .{});
                pc += 1 + n;
            }
        }
        if (op == 0xAC or op == 0xB0 or op == 0xB1) {
            // Stop at the first return — handles overlapping method
            // bodies in the simulator's class-record format.
            try out.print("\n", .{});
            break;
        }
    }
}
