//! Opcode dispatch table — entry point for `core/vm/opcodes/`.
//!
//! `core/vm/vm.zig:runFrame` calls `buildOpTable()` at comptime and
//! looks up handlers by opcode byte. Each group lives in its own
//! file under this directory:
//!
//!   consts.zig     — NOP / ACONST_NULL / ICONST_* / BIPUSH / SIPUSH /
//!                    LDC / LDC2_W / LDC_STRING
//!   load_store.zig — ALOAD / ASTORE / LOAD_n / STORE_n / LLOAD / LSTORE
//!   stack.zig      — POP / POP2 / DUP / DUP_X1 / DUP2
//!   arithmetic.zig — IADD / ISUB / IMUL / IDIV / IREM / INEG /
//!                    ISHL / ISHR / IUSHR / IAND / IOR / IXOR / IINC /
//!                    I2B / I2C / I2S / LADD / LSUB
//!   array.zig      — NEWARRAY / IALOAD / BALOAD / ARRSTORE / ARRAYLENGTH
//!   object.zig     — NEW / CHECKCAST
//!   ret.zig        — RETURN / IRETURN (incl. ARETURN alias) / LRETURN
//!   invoke.zig     — INVOKEVIRTUAL / INVOKESTATIC / INVOKESPECIAL /
//!                    INVOKE_OWN (incl. _Alt descriptor variants)
//!   field.zig      — GETSTATIC / PUTSTATIC / GETFIELD / PUTFIELD
//!                    (incl. _own / _Full variants)
//!   branch.zig     — GOTO / IF_* / IF_ICMP_* / IFNULL / IFNONNULL
//!   switch_op.zig  — LOOKUPSWITCH / TABLESWITCH
//!   unimpl.zig     — catch-all for unbound opcode slots

const err_mod = @import("../error.zig");
const std = @import("std");
const frame_mod = @import("../frame.zig");
const vm_mod = @import("../vm.zig");

const Error = err_mod.Error;
const Frame = frame_mod.Frame;
const Vm = vm_mod.Vm;

pub const Handler = *const fn (vm: *Vm, frame: *Frame, op: u8) Error!void;

const arithmetic = @import("arithmetic.zig");
const array = @import("array.zig");
const branch = @import("branch.zig");
const consts = @import("consts.zig");
const field = @import("field.zig");
const invoke = @import("invoke.zig");
const load_store = @import("load_store.zig");
const object = @import("object.zig");
const ret = @import("ret.zig");
const stack = @import("stack.zig");
const switch_op = @import("switch_op.zig");
const unimpl_mod = @import("unimpl.zig");

/// Re-exported so tools (coverage_audit) can test a built table's slots
/// against the catch-all / deliberate-no-op handlers without mirroring
/// the binding list by hand.
pub const unimpl = unimpl_mod.unimpl;
pub const opNoop = unimpl_mod.opNoop;

/// One opcode binding row: byte + mnemonic + operand width + handler —
/// the SINGLE SOURCE OF TRUTH. The dispatch table, the trace/disasm
/// mnemonic table, and the operand-width table are all derived from
/// `op_specs` at comptime, so they cannot drift from each other.
/// Rows are ordered by opcode byte; group comments mark JVM-style
/// ranges. See `reference/ref`'s `off_454498[258]` (line 1522) for the
/// canonical sub_* each opcode maps to.
pub const OpSpec = struct {
    op: u8,
    /// JVM-style mnemonic for traces/disasm. "OP_??" for slots that
    /// are bound (or width-annotated) without a recovered name.
    mnemonic: []const u8 = "OP_??",
    /// Operand bytes after the opcode byte:
    ///    0  no immediate
    ///    1  one u8 (no alignment)
    ///    2  one u16, 2-byte aligned (PC = (PC + 2) & ~1)
    ///   -1  variable length (TABLESWITCH / LOOKUPSWITCH)
    ///   -2  IINC pair (u8 slot + s8 delta, no alignment)
    ///   -3  conditional class-ref (NEWARRAY / CHECKCAST /
    ///       INSTANCEOF): aligned u16 type tag at (PC+2)&~1, PLUS a
    ///       second u16 class ref iff the tag's low byte is 0x99
    ///       (canonical sub_40EE4D `v0 == 153` / the
    ///       sub_40BC23/sub_40BCEA operand layout)
    ///   -4  MULTIANEWARRAY: u8 dim, then aligned u16 type tag at
    ///       (PC+3)&~1, plus the same conditional 0x99 class ref
    width: i8 = 0,
    /// null = known byte with no Zig handler: named/steppable by tools,
    /// but the dispatch slot stays `unimpl` (VM halts if executed) —
    /// the opcode analogue of the natives `stub_names` convention.
    handler: ?Handler = null,
};

pub const op_specs = [_]OpSpec{
    // ── 0x00–0x14: constants & const-push ────────────────────────────
    .{ .op = 0x00, .mnemonic = "NOP",         .handler = consts.opNop },
    .{ .op = 0x01, .mnemonic = "ACONST_NULL", .handler = consts.opAconstNull },
    .{ .op = 0x02, .mnemonic = "ICONST_M1",   .handler = consts.opIconst },
    .{ .op = 0x03, .mnemonic = "ICONST_0",    .handler = consts.opIconst },
    .{ .op = 0x04, .mnemonic = "ICONST_1",    .handler = consts.opIconst },
    .{ .op = 0x05, .mnemonic = "ICONST_2",    .handler = consts.opIconst },
    .{ .op = 0x06, .mnemonic = "ICONST_3",    .handler = consts.opIconst },
    .{ .op = 0x07, .mnemonic = "ICONST_4",    .handler = consts.opIconst },
    .{ .op = 0x08, .mnemonic = "ICONST_5",    .handler = consts.opIconst },
    .{ .op = 0x09, .mnemonic = "LCONST_0",    .handler = consts.opLconst }, // canonical sub_40CD4C (2-slot long)
    .{ .op = 0x0A, .mnemonic = "LCONST_1",    .handler = consts.opLconst }, // canonical sub_40CD7B
    .{ .op = 0x10, .mnemonic = "BIPUSH",      .width = 1, .handler = consts.opBipush },
    .{ .op = 0x11, .mnemonic = "SIPUSH",      .width = 2, .handler = consts.opSipush },
    .{ .op = 0x12, .mnemonic = "LDC",         .width = 2, .handler = consts.opLdc },
    .{ .op = 0x14, .mnemonic = "LDC2_W",      .width = 2, .handler = consts.opLdc2W },
    // JVM ILOAD/LLOAD/FLOAD/DLOAD with u8 operand — no ExEn handler,
    // but static walkers must step the operand byte.
    .{ .op = 0x15, .width = 1 },
    .{ .op = 0x16, .width = 1 },
    .{ .op = 0x17, .width = 1 },
    .{ .op = 0x18, .width = 1 },

    // ── 0x19–0x35: loads (ALOAD / IALOAD family) ─────────────────────
    .{ .op = 0x19, .mnemonic = "ALOAD",   .width = 1, .handler = load_store.opAload },
    .{ .op = 0x2A, .mnemonic = "ALOAD_0", .handler = load_store.opAload0 },
    .{ .op = 0x2B, .mnemonic = "ALOAD_1", .handler = load_store.opAload1 },
    .{ .op = 0x2C, .mnemonic = "ALOAD_2", .handler = load_store.opAload2 },
    .{ .op = 0x2D, .mnemonic = "ALOAD_3", .handler = load_store.opAload3 },
    // Array loads — canonical splits by element width/sign-handling.
    // 0x2E / 0x32 collapse onto opIaload (4-byte raw read). 0x33 / 0x34 /
    // 0x35 prefer inst.bytes over fields[] so packed char[] / byte[] /
    // short[] payloads past idx=62 don't return 0 (broke Crash's
    // menu-text array; broke BanjoKazooie's 144-entry enemy frame table,
    // which drew every enemy as a 0×0 rect — see opSaload).
    .{ .op = 0x2E, .mnemonic = "IALOAD", .handler = array.opIaload }, // canonical sub_40AECD — tag 0x59 (int[])
    .{ .op = 0x2F, .mnemonic = "LALOAD", .handler = array.opLaload }, // canonical sub_40CA2F (2-slot long, stride-2 .ints)
    .{ .op = 0x32, .mnemonic = "AALOAD", .handler = array.opIaload }, // canonical sub_4088B0
    .{ .op = 0x33, .mnemonic = "BALOAD", .handler = array.opBaload }, // canonical sub_408EB0 (byte, signed)
    .{ .op = 0x34, .mnemonic = "CALOAD", .handler = array.opCaload }, // canonical sub_4090F0 (char, unsigned)
    .{ .op = 0x35, .mnemonic = "SALOAD", .handler = array.opSaload }, // canonical sub_40FA40 (tag-0x15 short[]/char[])
    // JVM ISTORE/LSTORE/FSTORE/DSTORE with u8 operand — steppable only.
    .{ .op = 0x36, .width = 1 },
    .{ .op = 0x37, .width = 1 },
    .{ .op = 0x38, .width = 1 },
    .{ .op = 0x39, .width = 1 },

    // ── 0x3A–0x56: stores (ASTORE / ARRSTORE family) ─────────────────
    .{ .op = 0x3A, .mnemonic = "ASTORE",    .width = 1, .handler = load_store.opAstore },
    .{ .op = 0x4A, .mnemonic = "ASTORE_op", .width = 1, .handler = load_store.opStoreOp }, // ASTORE with byte operand (refcount variant)
    .{ .op = 0x4B, .mnemonic = "ASTORE_0",  .handler = load_store.opStore0 },
    .{ .op = 0x4C, .mnemonic = "ASTORE_1",  .handler = load_store.opStore1 },
    .{ .op = 0x4D, .mnemonic = "ASTORE_2",  .handler = load_store.opStore2 },
    .{ .op = 0x4E, .mnemonic = "ASTORE_3",  .handler = load_store.opStore3 },
    // Array stores — simulator splits by element size, but our hash-padded
    // fields-as-array storage routes them all through opArrStore which
    // writes to inst.bytes (low byte), inst.ints (if allocated), AND
    // inst.fields[1+idx] — covering int/short/byte/aref uniformly.
    .{ .op = 0x4F, .mnemonic = "IASTORE", .handler = array.opArrStore },
    .{ .op = 0x50, .mnemonic = "LASTORE", .handler = array.opLastore }, // canonical sub_40CB8F: pops 4 (ref,idx,long), stride-2 .ints
    .{ .op = 0x51, .mnemonic = "FASTORE", .handler = array.opArrStore },
    .{ .op = 0x52, .mnemonic = "DASTORE", .handler = array.opArrStore },
    .{ .op = 0x53, .mnemonic = "AASTORE", .handler = array.opArrStore },
    .{ .op = 0x54, .mnemonic = "BASTORE", .handler = array.opArrStore },
    .{ .op = 0x55, .mnemonic = "CASTORE", .handler = array.opArrStore }, // (1-byte @ idx)
    .{ .op = 0x56, .mnemonic = "SASTORE", .handler = array.opSastore }, // canonical sub_40FB44: 2-byte @ 2*idx for short-only arrays

    // ── 0x57–0x5F: stack manipulation ────────────────────────────────
    .{ .op = 0x57, .mnemonic = "POP",     .handler = stack.opPop },
    .{ .op = 0x58, .mnemonic = "POP2",    .handler = stack.opPop2 },
    .{ .op = 0x59, .mnemonic = "DUP",     .handler = stack.opDup },
    .{ .op = 0x5A, .mnemonic = "DUP_X1",  .handler = stack.opDupX1 },
    .{ .op = 0x5B, .mnemonic = "DUP_X2",  .handler = stack.opDupX2 }, // canonical sub_4093D9: ..,A,B,C → ..,C,A,B,C
    .{ .op = 0x5C, .mnemonic = "DUP2",    .handler = stack.opDup2 },
    .{ .op = 0x5D, .mnemonic = "DUP2_X1", .handler = stack.opDup2X1 },
    .{ .op = 0x5E, .mnemonic = "DUP2_X2", .handler = stack.opDup2X2 },
    .{ .op = 0x5F, .mnemonic = "SWAP",    .handler = stack.opSwap },

    // ── 0x60–0x94: arithmetic / conversion ───────────────────────────
    .{ .op = 0x60, .mnemonic = "IADD",  .handler = arithmetic.opIadd },
    .{ .op = 0x61, .mnemonic = "LADD",  .handler = arithmetic.opLadd },
    .{ .op = 0x64, .mnemonic = "ISUB",  .handler = arithmetic.opIsub },
    .{ .op = 0x65, .mnemonic = "LSUB",  .handler = arithmetic.opLsub },
    .{ .op = 0x68, .mnemonic = "IMUL",  .handler = arithmetic.opImul },
    .{ .op = 0x69, .mnemonic = "LMUL",  .handler = arithmetic.opLmul }, // canonical sub_40D1E4 — 64-bit signed multiply
    .{ .op = 0x6B, .handler = unimpl_mod.opNoop }, // canonical sub_4102CF — empty no-op slot
    .{ .op = 0x6C, .mnemonic = "IDIV",  .handler = arithmetic.opIdiv },
    .{ .op = 0x6D, .mnemonic = "LDIV",  .handler = arithmetic.opLdiv }, // canonical sub_40CFCF — long division (signed /)
    .{ .op = 0x70, .mnemonic = "IREM",  .handler = arithmetic.opIrem },
    .{ .op = 0x71, .mnemonic = "LREM",  .handler = arithmetic.opLrem }, // canonical sub_40D4C0 — long remainder (signed %)
    .{ .op = 0x74, .mnemonic = "INEG",  .handler = arithmetic.opIneg },
    .{ .op = 0x75, .mnemonic = "LNEG",  .handler = arithmetic.opLneg }, // canonical sub_40D242 — long negate
    .{ .op = 0x78, .mnemonic = "ISHL",  .handler = arithmetic.opIshl },
    .{ .op = 0x79, .mnemonic = "LSHL",  .handler = arithmetic.opLshl }, // canonical sub_40D5EE — long <<, count low-6 bits
    .{ .op = 0x7A, .mnemonic = "ISHR",  .handler = arithmetic.opIshr },
    .{ .op = 0x7B, .mnemonic = "LSHR",  .handler = arithmetic.opLshr }, // canonical sub_40D645 — signed long >>, count low-6 bits
    .{ .op = 0x7C, .mnemonic = "IUSHR", .handler = arithmetic.opIushr },
    .{ .op = 0x7D, .mnemonic = "LUSHR", .handler = arithmetic.opLushr }, // canonical sub_40D83F — unsigned long >>
    .{ .op = 0x7E, .mnemonic = "IAND",  .handler = arithmetic.opIand },
    .{ .op = 0x7F, .mnemonic = "LAND",  .handler = arithmetic.opLand }, // canonical sub_40CB3B — long bitwise AND
    .{ .op = 0x80, .mnemonic = "IOR",   .handler = arithmetic.opIor },
    .{ .op = 0x81, .mnemonic = "LOR",   .handler = arithmetic.opLor }, // canonical sub_40D46C — long bitwise OR
    .{ .op = 0x82, .mnemonic = "IXOR",  .handler = arithmetic.opIxor },
    .{ .op = 0x83, .mnemonic = "LXOR",  .handler = arithmetic.opLxor }, // canonical sub_40D911 — long bitwise XOR
    .{ .op = 0x84, .mnemonic = "IINC",  .width = -2, .handler = arithmetic.opIinc },
    .{ .op = 0x85, .mnemonic = "I2L",   .handler = arithmetic.opI2l }, // canonical sub_40AE2B
    // Canonical sub_4102CF (empty function) — reserved no-op slots
    // surrounding 0x88 (sub_40C990, the only real op in this band).
    .{ .op = 0x86, .handler = unimpl_mod.opNoop },
    .{ .op = 0x87, .handler = unimpl_mod.opNoop },
    // 0x88 → sub_40C990. Body: SP -= 8; **(SP) = **(SP); SP += 4.
    // Net SP delta = −4 bytes (1 slot popped). Unlike POP (0x57) it
    // does NOT zero the popped cell — separate handler for byte-byte
    // canonical parity. MotoGp uses it at PC=0x0458 in method 0xdf3efa13.
    .{ .op = 0x88, .mnemonic = "POP_NOCLEAR", .handler = stack.opPopNoclear },
    .{ .op = 0x89, .handler = unimpl_mod.opNoop },
    .{ .op = 0x8A, .handler = unimpl_mod.opNoop },
    .{ .op = 0x8B, .handler = unimpl_mod.opNoop },
    .{ .op = 0x8C, .handler = unimpl_mod.opNoop },
    .{ .op = 0x8D, .handler = unimpl_mod.opNoop },
    .{ .op = 0x8E, .handler = unimpl_mod.opNoop },
    .{ .op = 0x91, .mnemonic = "I2B",  .handler = arithmetic.opI2b },
    .{ .op = 0x92, .mnemonic = "I2C",  .handler = arithmetic.opI2c },
    .{ .op = 0x93, .mnemonic = "I2S",  .handler = arithmetic.opI2s },
    .{ .op = 0x94, .mnemonic = "LCMP", .handler = arithmetic.opLcmp }, // canonical sub_40CC67 (unsigned 64-bit)

    // ── 0x99–0xAB: branches / subroutine / switch ────────────────────
    .{ .op = 0x99, .mnemonic = "IFEQ",      .width = 2, .handler = branch.opIfeq },
    .{ .op = 0x9A, .mnemonic = "IFNE",      .width = 2, .handler = branch.opIfne },
    .{ .op = 0x9B, .mnemonic = "IFLT",      .width = 2, .handler = branch.opIflt },
    .{ .op = 0x9C, .mnemonic = "IFGE",      .width = 2, .handler = branch.opIfge },
    .{ .op = 0x9D, .mnemonic = "IFGT",      .width = 2, .handler = branch.opIfgt },
    .{ .op = 0x9E, .mnemonic = "IFLE",      .width = 2, .handler = branch.opIfle },
    .{ .op = 0x9F, .mnemonic = "IF_ICMPEQ", .width = 2, .handler = branch.opIfIcmpeq },
    .{ .op = 0xA0, .mnemonic = "IF_ICMPNE", .width = 2, .handler = branch.opIfIcmpne },
    .{ .op = 0xA1, .mnemonic = "IF_ICMPLT", .width = 2, .handler = branch.opIfIcmplt },
    .{ .op = 0xA2, .mnemonic = "IF_ICMPGE", .width = 2, .handler = branch.opIfIcmpge },
    .{ .op = 0xA3, .mnemonic = "IF_ICMPGT", .width = 2, .handler = branch.opIfIcmpgt },
    .{ .op = 0xA4, .mnemonic = "IF_ICMPLE", .width = 2, .handler = branch.opIfIcmple },
    // 0xA5/0xA6: probably IF_ICMPxx variants in canonical; bytecode
    // pattern (single-pop, branch-on-zero) is identical to IFNULL/IFNONNULL.
    // Canonical IFNULL/IFNONNULL proper are at 0xC6/0xC7 (sub_40BA44 /
    // sub_40B9C7).
    .{ .op = 0xA5, .mnemonic = "IFNULL",    .width = 2, .handler = branch.opIfnull },
    .{ .op = 0xA6, .mnemonic = "IFNONNULL", .width = 2, .handler = branch.opIfnonnull },
    .{ .op = 0xA7, .mnemonic = "GOTO",      .width = 2, .handler = branch.opGoto },
    .{ .op = 0xA8, .mnemonic = "JSR",       .width = 2, .handler = branch.opJsr }, // canonical sub_40C8F0 (return PC → frame slot)
    // TODO: verify RET's width against branch.opRet's actual operand
    // consumption — kept at 0 to match the pre-refactor walker tables.
    .{ .op = 0xA9, .mnemonic = "RET",       .handler = branch.opRet }, // canonical sub_40F9E0 (PC ← frame slot)
    // 0xAA (sub_40FD68) is the second TABLESWITCH flavour. Its on-wire
    // layout (2-byte-aligned u16 default / i16 low / i16 high / u16
    // targets) matches 0xCD's, so it shares opTableswitch. ⚠ Inferred:
    // reference/ref body unavailable; no corpus gamelet hits it live.
    .{ .op = 0xAA, .mnemonic = "TABLESWITCH",    .width = -1, .handler = switch_op.opTableswitch },
    .{ .op = 0xAB, .mnemonic = "LOOKUPSWITCH_W", .width = -1, .handler = switch_op.opLookupswitchW },

    // ── 0xB0–0xC1: returns / object / array meta ─────────────────────
    // 0xB0 = ARETURN (sub_408E23) — like IRETURN but for object refs.
    // Simulator decrements a refcount byte at instance+15; we ignore that
    // (objects live until VM shutdown).
    .{ .op = 0xB0, .mnemonic = "ARETURN", .handler = ret.opIreturn },
    .{ .op = 0xB1, .mnemonic = "RETURN",  .handler = ret.opReturn },
    // JVM GETSTATIC..INVOKEINTERFACE band (0xB2–0xB9) — no ExEn handler,
    // but each carries a u16 operand static walkers must step over.
    .{ .op = 0xB2, .width = 2 },
    .{ .op = 0xB3, .width = 2 },
    .{ .op = 0xB4, .width = 2 },
    .{ .op = 0xB5, .width = 2 },
    .{ .op = 0xB6, .width = 2 },
    .{ .op = 0xB7, .width = 2 },
    .{ .op = 0xB8, .width = 2 },
    .{ .op = 0xB9, .width = 2 },
    .{ .op = 0xBB, .mnemonic = "NEW",      .width = 2, .handler = object.opNew },
    .{ .op = 0xBC, .mnemonic = "NEWARRAY", .width = -3, .handler = array.opNewarray },
    .{ .op = 0xBD, .width = 2 }, // JVM ANEWARRAY — steppable only
    .{ .op = 0xBE, .mnemonic = "ARRAYLENGTH", .handler = array.opArraylength },
    .{ .op = 0xBF, .mnemonic = "ATHROW", .handler = ret.opAthrow }, // canonical sub_408DBD (partial: uncaught → tick abort)
    .{ .op = 0xC0, .mnemonic = "CHECKCAST",  .width = -3, .handler = object.opCheckcast },
    .{ .op = 0xC1, .mnemonic = "INSTANCEOF", .width = -3, .handler = object.opInstanceof },

    // ── 0xC2–0xCD: NOPs / multi-array / null-branches / switch ───────
    // 0xC2/0xC3 (sub_40E900 / sub_40E905) are empty-bodied in canonical —
    // bind to opNoop so a stray byte doesn't halt the VM.
    .{ .op = 0xC2, .handler = unimpl_mod.opNoop },
    .{ .op = 0xC3, .handler = unimpl_mod.opNoop },
    .{ .op = 0xC5, .mnemonic = "MULTIANEWARRAY", .width = -4, .handler = array.opMultianewarray }, // canonical sub_40E90A
    .{ .op = 0xC6, .mnemonic = "IFNULL",    .width = 2, .handler = branch.opIfnull }, // canonical sub_40BA44
    .{ .op = 0xC7, .mnemonic = "IFNONNULL", .width = 2, .handler = branch.opIfnonnull }, // canonical sub_40B9C7
    .{ .op = 0xC8, .width = 2 }, // JVM GOTO_W — steppable only
    .{ .op = 0xC9, .width = 2 }, // JVM JSR_W — steppable only
    .{ .op = 0xCC, .mnemonic = "LOOKUPSWITCH", .width = -1, .handler = switch_op.opLookupswitch },
    .{ .op = 0xCD, .mnemonic = "TABLESWITCH",  .width = -1, .handler = switch_op.opTableswitch },

    // ── 0xD0: LDC_STRING ─────────────────────────────────────────────
    .{ .op = 0xD0, .mnemonic = "LDC_STRING", .width = 2, .handler = consts.opLdcString },

    // ── 0xD5–0xE8: variable LOAD/STORE (one-byte operand) ────────────
    .{ .op = 0xD5, .mnemonic = "LOAD_op",   .width = 1, .handler = load_store.opLoadOp },
    .{ .op = 0xD6, .mnemonic = "STORE_op",  .width = 1, .handler = load_store.opStoreOp },
    .{ .op = 0xD7, .mnemonic = "LLOAD_op",  .width = 1, .handler = load_store.opLloadOp }, // canonical sub_40D091 — LLOAD <u8 slot> (2-slot long)
    .{ .op = 0xD8, .mnemonic = "LSTORE_op", .width = 1, .handler = load_store.opLstoreOp }, // canonical sub_40D69C — LSTORE <u8 slot>
    .{ .op = 0xD9, .mnemonic = "ALOAD_0_DUP", .handler = load_store.opAload0Dup }, // ILOAD/ALOAD_0
    .{ .op = 0xDA, .mnemonic = "STORE_0",   .handler = load_store.opStore0 }, // ISTORE/ASTORE_0
    .{ .op = 0xDB, .mnemonic = "LLOAD_0",   .handler = load_store.opLload0 }, // LLOAD/DLOAD_0
    .{ .op = 0xDC, .mnemonic = "LSTORE_0",  .handler = load_store.opLstore0 }, // LSTORE/DSTORE_0
    .{ .op = 0xDD, .mnemonic = "LOAD_1",    .handler = load_store.opLoad1 }, // ILOAD/ALOAD_1
    .{ .op = 0xDE, .mnemonic = "STORE_1",   .handler = load_store.opStore1 },
    .{ .op = 0xDF, .mnemonic = "LLOAD_1",   .handler = load_store.opLload1 },
    .{ .op = 0xE0, .mnemonic = "LSTORE_1",  .handler = load_store.opLstore1 },
    .{ .op = 0xE1, .mnemonic = "LOAD_2",    .handler = load_store.opLoad2 }, // ILOAD/ALOAD_2
    .{ .op = 0xE2, .mnemonic = "STORE_2",   .handler = load_store.opStore2 },
    .{ .op = 0xE3, .mnemonic = "LLOAD_2",   .handler = load_store.opLload2 },
    .{ .op = 0xE4, .mnemonic = "LSTORE_2",  .handler = load_store.opLstore2 },
    .{ .op = 0xE5, .mnemonic = "LOAD_3",    .handler = load_store.opLoad3 }, // ILOAD/ALOAD_3
    .{ .op = 0xE6, .mnemonic = "STORE_3",   .handler = load_store.opStore3 },
    .{ .op = 0xE7, .mnemonic = "LLOAD_3",   .handler = load_store.opLload3 },
    .{ .op = 0xE8, .mnemonic = "LSTORE_3",  .handler = load_store.opLstore3 },

    // ── 0xE9–0xEA: returns (alt) ─────────────────────────────────────
    .{ .op = 0xE9, .mnemonic = "IRETURN", .handler = ret.opIreturn },
    .{ .op = 0xEA, .mnemonic = "LRETURN", .handler = ret.opLreturn },

    // ── 0xED–0xF2: invoke family ─────────────────────────────────────
    // 0xED → sub_40C1FA: receiver-class direct dispatch (arg_count @ +6).
    // 0xEE → sub_40C304: full virtual dispatch (arg_count @ +4).
    // Both resolve via `resolveVirtual` walking the super chain.
    .{ .op = 0xED, .mnemonic = "INVOKEVIRTUAL_ALT", .width = 2, .handler = invoke.opInvokevirtualAlt },
    .{ .op = 0xEE, .mnemonic = "INVOKEVIRTUAL",     .width = 2, .handler = invoke.opInvokevirtual },
    .{ .op = 0xEF, .mnemonic = "INVOKE_OWN",        .width = 2, .handler = invoke.opInvokeOwn },
    .{ .op = 0xF0, .mnemonic = "INVOKESPECIAL",     .width = 2, .handler = invoke.opInvokespecial },
    .{ .op = 0xF1, .mnemonic = "INVOKESTATIC_ALT",  .width = 2, .handler = invoke.opInvokestaticAlt },
    .{ .op = 0xF2, .mnemonic = "INVOKESTATIC",      .width = 2, .handler = invoke.opInvokestatic },

    // ── 0xF3–0xFA: field access ──────────────────────────────────────
    .{ .op = 0xF3, .mnemonic = "GETSTATIC",      .width = 2, .handler = field.opGetstatic },
    .{ .op = 0xF4, .mnemonic = "PUTSTATIC",      .width = 2, .handler = field.opPutstatic },
    .{ .op = 0xF5, .mnemonic = "GETFIELD_OWN",   .width = 2, .handler = field.opGetfieldOwn },
    .{ .op = 0xF6, .mnemonic = "PUTFIELD_OWN",   .width = 2, .handler = field.opPutfieldOwn },
    .{ .op = 0xF7, .mnemonic = "GETSTATIC_FULL", .width = 2, .handler = field.opGetstaticFull },
    .{ .op = 0xF8, .mnemonic = "PUTSTATIC_FULL", .width = 2, .handler = field.opPutstaticFull },
    .{ .op = 0xF9, .mnemonic = "GETFIELD",       .width = 2, .handler = field.opGetfield },
    .{ .op = 0xFA, .mnemonic = "PUTFIELD",       .width = 2, .handler = field.opPutfieldFull },
};

// Every op byte may appear at most once in op_specs — a duplicated row
// would silently shadow an earlier binding.
comptime {
    var seen = [_]bool{false} ** 256;
    for (op_specs) |s| {
        if (seen[s.op]) @compileError(std.fmt.comptimePrint(
            "duplicate op_specs row for 0x{X:0>2}", .{s.op}));
        seen[s.op] = true;
    }
}

/// The [256] dispatch table, derived from `op_specs`. Slots without a
/// row (or with a handler-less row) stay bound to `unimpl`.
pub fn buildOpTable() [256]Handler {
    var t: [256]Handler = .{unimpl_mod.unimpl} ** 256;
    for (op_specs) |s| {
        if (s.handler) |h| t[s.op] = h;
    }
    return t;
}

/// op byte → mnemonic, derived from `op_specs` ("OP_??" for unlisted).
pub const mnemonics: [256][]const u8 = blk: {
    var t: [256][]const u8 = .{"OP_??"} ** 256;
    for (op_specs) |s| t[s.op] = s.mnemonic;
    break :blk t;
};

/// op byte → operand width, derived from `op_specs` (encoding on OpSpec.width).
pub const operand_widths: [256]i8 = blk: {
    var t: [256]i8 = .{0} ** 256;
    for (op_specs) |s| t[s.op] = s.width;
    break :blk t;
};

pub fn opName(op: u8) []const u8 {
    return mnemonics[op];
}

test "op_specs dispatch table shape" {
    const std_t = @import("std").testing;
    const t = comptime buildOpTable();
    var bound: usize = 0;
    for (t) |h| {
        if (h != unimpl_mod.unimpl) bound += 1;
    }
    try std_t.expectEqual(@as(usize, 160), bound);
    try std_t.expect(t[0xEE] == invoke.opInvokevirtual);
    try std_t.expect(t[0x6B] == unimpl_mod.opNoop);
    try std_t.expect(t[0x13] == unimpl_mod.unimpl);
    try std_t.expect(t[0xB2] == unimpl_mod.unimpl); // width-only row stays unbound
}
