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

pub fn buildOpTable() [256]Handler {
    var t: [256]Handler = .{unimpl_mod.unimpl} ** 256;

    // Bindings are ordered by opcode byte. Group comments mark JVM-style
    // ranges for navigation. See `core/debug/names.zig` for canonical
    // names and `reference/ref`'s `off_454498[258]` (line 1522)
    // for the canonical sub_* each opcode maps to.

    // ── 0x00–0x14: constants & const-push ────────────────────────────
    t[0x00] = consts.opNop;
    t[0x01] = consts.opAconstNull;
    t[0x02] = consts.opIconst;     // ICONST_M1
    t[0x03] = consts.opIconst;     // ICONST_0
    t[0x04] = consts.opIconst;     // ICONST_1
    t[0x05] = consts.opIconst;     // ICONST_2
    t[0x06] = consts.opIconst;     // ICONST_3
    t[0x07] = consts.opIconst;     // ICONST_4
    t[0x08] = consts.opIconst;     // ICONST_5
    t[0x10] = consts.opBipush;
    t[0x11] = consts.opSipush;
    t[0x12] = consts.opLdc;
    t[0x14] = consts.opLdc2W;

    // ── 0x19–0x35: loads (ALOAD / IALOAD family) ─────────────────────
    t[0x19] = load_store.opAload;
    t[0x2A] = load_store.opAload0;
    t[0x2B] = load_store.opAload1;
    t[0x2C] = load_store.opAload2;
    t[0x2D] = load_store.opAload3;
    // Array loads — canonical splits by element width/sign-handling.
    // 0x2E / 0x32 collapse onto opIaload (4-byte raw read). 0x33 / 0x34
    // prefer inst.bytes over fields[] so packed char[] / byte[] payloads
    // past idx=62 don't return 0 (broke Crash's menu-text array). 0x35
    // (SALOAD) falls back to opIaload — typical bytecode pre-extends via
    // I2S before SASTORE so the stored u32 already carries upper bits.
    t[0x2E] = array.opIaload;      // canonical sub_40AECD — tag 0x59 (int[])
    t[0x32] = array.opIaload;      // canonical sub_4088B0 — AALOAD
    t[0x33] = array.opBaload;      // canonical sub_408EB0 — BALOAD (byte, signed)
    t[0x34] = array.opCaload;      // canonical sub_4090F0 — CALOAD (char, unsigned)
    t[0x35] = array.opIaload;      // canonical sub_40FA40 — SALOAD (short, signed)

    // ── 0x3A–0x56: stores (ASTORE / ARRSTORE family) ─────────────────
    t[0x3A] = load_store.opAstore;
    t[0x4A] = load_store.opStoreOp; // ASTORE with byte operand (refcount variant)
    t[0x4B] = load_store.opStore0;
    t[0x4C] = load_store.opStore1;
    t[0x4D] = load_store.opStore2;
    t[0x4E] = load_store.opStore3;
    // Array stores — simulator splits by element size, but our hash-padded
    // fields-as-array storage routes them all through opArrStore which
    // writes to inst.bytes (low byte), inst.ints (if allocated), AND
    // inst.fields[1+idx] — covering int/short/byte/aref uniformly.
    t[0x4F] = array.opArrStore;    // IASTORE
    t[0x50] = array.opArrStore;    // LASTORE
    t[0x51] = array.opArrStore;    // FASTORE
    t[0x52] = array.opArrStore;    // DASTORE
    t[0x53] = array.opArrStore;    // AASTORE
    t[0x54] = array.opArrStore;    // BASTORE
    t[0x55] = array.opArrStore;    // CASTORE
    t[0x56] = array.opArrStore;    // canonical sub_40FB44 — SASTORE: short[] write

    // ── 0x57–0x5F: stack manipulation ────────────────────────────────
    t[0x57] = stack.opPop;
    t[0x58] = stack.opPop2;
    t[0x59] = stack.opDup;
    t[0x5A] = stack.opDupX1;
    t[0x5B] = stack.opDupX2;       // canonical sub_4093D9 — DUP_X2: ..,A,B,C → ..,C,A,B,C
    t[0x5C] = stack.opDup2;
    t[0x5D] = stack.opDup2X1;
    t[0x5E] = stack.opDup2X2;
    t[0x5F] = stack.opSwap;

    // ── 0x60–0x94: arithmetic / conversion ───────────────────────────
    t[0x60] = arithmetic.opIadd;
    t[0x61] = arithmetic.opLadd;
    t[0x64] = arithmetic.opIsub;
    t[0x65] = arithmetic.opLsub;
    t[0x68] = arithmetic.opImul;
    t[0x69] = arithmetic.opLmul;   // canonical sub_40D1E4 — 64-bit signed multiply
    t[0x71] = arithmetic.opLrem;   // canonical sub_40D4C0 — long remainder (signed %)
    t[0x7B] = arithmetic.opLshr;   // canonical sub_40D645 — signed long >>, count low-6 bits
    t[0x7F] = arithmetic.opLand;   // canonical sub_40CB3B — long bitwise AND
    t[0x6B] = unimpl_mod.opNoop;   // canonical sub_4102CF — empty no-op slot
    t[0x6C] = arithmetic.opIdiv;
    t[0x70] = arithmetic.opIrem;
    t[0x74] = arithmetic.opIneg;
    t[0x78] = arithmetic.opIshl;
    t[0x7A] = arithmetic.opIshr;
    t[0x7C] = arithmetic.opIushr;
    t[0x7E] = arithmetic.opIand;
    t[0x80] = arithmetic.opIor;
    t[0x82] = arithmetic.opIxor;
    t[0x84] = arithmetic.opIinc;
    t[0x85] = arithmetic.opI2l;
    // Canonical sub_4102CF (empty function) — reserved no-op slots
    // surrounding 0x88 (sub_40C990, the only real op in this band).
    t[0x86] = unimpl_mod.opNoop;
    t[0x87] = unimpl_mod.opNoop;
    // 0x88 → sub_40C990. Body: SP -= 8; **(SP) = **(SP); SP += 4.
    // Net SP delta = −4 bytes (1 slot popped). Unlike POP (0x57) it
    // does NOT zero the popped cell — separate handler for byte-byte
    // canonical parity. MotoGp uses it at PC=0x0458 in method 0xdf3efa13.
    t[0x88] = stack.opPopNoclear;
    t[0x89] = unimpl_mod.opNoop;
    t[0x8A] = unimpl_mod.opNoop;
    t[0x8B] = unimpl_mod.opNoop;
    t[0x8C] = unimpl_mod.opNoop;
    t[0x8D] = unimpl_mod.opNoop;
    t[0x8E] = unimpl_mod.opNoop;
    t[0x91] = arithmetic.opI2b;
    t[0x92] = arithmetic.opI2c;
    t[0x93] = arithmetic.opI2s;
    t[0x94] = arithmetic.opLcmp;

    // ── 0x99–0xA7: branches (IFEQ / IF_ICMP* / IFNULL / GOTO) ────────
    t[0x99] = branch.opIfeq;
    t[0x9A] = branch.opIfne;
    t[0x9B] = branch.opIflt;
    t[0x9C] = branch.opIfge;
    t[0x9D] = branch.opIfgt;
    t[0x9E] = branch.opIfle;
    t[0x9F] = branch.opIfIcmpeq;
    t[0xA0] = branch.opIfIcmpne;
    t[0xA1] = branch.opIfIcmplt;
    t[0xA2] = branch.opIfIcmpge;
    t[0xA3] = branch.opIfIcmpgt;
    t[0xA4] = branch.opIfIcmple;
    // 0xA5/0xA6: probably IF_ICMPxx variants in canonical; bytecode
    // pattern (single-pop, branch-on-zero) is identical to IFNULL/IFNONNULL.
    // Canonical IFNULL/IFNONNULL proper are at 0xC6/0xC7 (sub_40BA44 /
    // sub_40B9C7).
    t[0xA5] = branch.opIfnull;
    t[0xA6] = branch.opIfnonnull;
    t[0xA7] = branch.opGoto;

    // ── 0xAB: wide-operand switch ────────────────────────────────────
    t[0xAB] = switch_op.opLookupswitchW;

    // ── 0xB0–0xC1: returns / object / array meta ─────────────────────
    // 0xB0 = ARETURN (sub_408E23) — like IRETURN but for object refs.
    // Simulator decrements a refcount byte at instance+15; we ignore that
    // (objects live until VM shutdown).
    t[0xB0] = ret.opIreturn;
    t[0xB1] = ret.opReturn;
    t[0xBB] = object.opNew;
    t[0xBC] = array.opNewarray;
    t[0xBE] = array.opArraylength;
    t[0xC0] = object.opCheckcast;
    t[0xC1] = object.opInstanceof;

    // ── 0xC5–0xCD: multi-array / null-branches / switch ──────────────
    t[0xC5] = array.opMultianewarray;
    t[0xC6] = branch.opIfnull;     // canonical sub_40BA44
    t[0xC7] = branch.opIfnonnull;  // canonical sub_40B9C7
    t[0xCC] = switch_op.opLookupswitch;
    t[0xCD] = switch_op.opTableswitch;

    // ── 0xD0: LDC_STRING ─────────────────────────────────────────────
    t[0xD0] = consts.opLdcString;

    // ── 0xD5–0xE8: variable LOAD/STORE (one-byte operand) ────────────
    t[0xD5] = load_store.opLoadOp;
    t[0xD6] = load_store.opStoreOp;
    t[0xD9] = load_store.opAload0Dup; // ILOAD/ALOAD_0
    t[0xDA] = load_store.opStore0;    // ISTORE/ASTORE_0
    t[0xDB] = load_store.opLload0;    // LLOAD/DLOAD_0
    t[0xDC] = load_store.opLstore0;   // LSTORE/DSTORE_0
    t[0xDD] = load_store.opLoad1;     // ILOAD/ALOAD_1
    t[0xDE] = load_store.opStore1;
    t[0xDF] = load_store.opLload1;
    t[0xE0] = load_store.opLstore1;
    t[0xE1] = load_store.opLoad2;     // ILOAD/ALOAD_2
    t[0xE2] = load_store.opStore2;
    t[0xE3] = load_store.opLload2;
    t[0xE4] = load_store.opLstore2;
    t[0xE5] = load_store.opLoad3;     // ILOAD/ALOAD_3
    t[0xE6] = load_store.opStore3;
    t[0xE7] = load_store.opLload3;
    t[0xE8] = load_store.opLstore3;

    // ── 0xE9–0xEA: returns (alt) ─────────────────────────────────────
    t[0xE9] = ret.opIreturn;
    t[0xEA] = ret.opLreturn;

    // ── 0xED–0xF2: invoke family ─────────────────────────────────────
    // 0xED → sub_40C1FA: receiver-class direct dispatch (arg_count @ +6).
    // 0xEE → sub_40C304: full virtual dispatch (arg_count @ +4).
    // Both resolve via `resolveVirtual` walking the super chain.
    t[0xED] = invoke.opInvokevirtualAlt;
    t[0xEE] = invoke.opInvokevirtual;
    t[0xEF] = invoke.opInvokeOwn;
    t[0xF0] = invoke.opInvokespecial;
    t[0xF1] = invoke.opInvokestaticAlt;
    t[0xF2] = invoke.opInvokestatic;

    // ── 0xF3–0xFA: field access ──────────────────────────────────────
    t[0xF3] = field.opGetstatic;
    t[0xF4] = field.opPutstatic;
    t[0xF5] = field.opGetfieldOwn;
    t[0xF6] = field.opPutfieldOwn;
    t[0xF7] = field.opGetstaticFull;
    t[0xF8] = field.opPutstaticFull;
    t[0xF9] = field.opGetfield;
    t[0xFA] = field.opPutfieldFull;

    return t;
}
