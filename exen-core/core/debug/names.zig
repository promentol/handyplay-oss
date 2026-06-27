//! Human-readable names for opcodes, classes, methods, and natives.
//! Used by the interpreter's verbose log lines so traces show
//! `INVOKEVIRTUAL exen.Graphics.drawImage` instead of
//! `op 0xee method_hash=0x43d2c07b class=0xc6ed8e2a`.
//!
//! All class hashes recovered by computing CRC-32 of the class name
//! (e.g. `crc32("exen.Graphics") == 0xc6ed8e2a`) against the
//! `funcs_407AA2[]` index map in `docs/native_index_map.md`.
//! Methods recovered the same way (and confirmed by the runtime hashes
//! in `class_registry.zig`'s METHOD_* constants).

const std = @import("std");

/// One opcode's metadata: name + operand width (number of bytecode
/// bytes consumed after the opcode byte). The interpreter handles
/// 2-byte-operand alignment (`PC = (PC + 1) & ~1`) internally; this
/// table just reports the nominal width so a disassembler can step
/// over an instruction. `operands` = -1 marks variable-length
/// opcodes (TABLESWITCH / LOOKUPSWITCH) that callers must inspect.
pub const Op = struct {
    name: []const u8,
    operands: i8 = 0,
};

/// Single source of truth for the 256-entry opcode dispatch table.
/// Mirrors `off_454498[]` in `reference/ref` and the runtime
/// bindings in `core/vm/opcodes/mod.zig` (the binder there is the
/// final authority for which handler runs; this table just gives
/// names + operand widths for tracing and disasm).
pub const opcodes: [256]Op = blk: {
    var t: [256]Op = [_]Op{.{ .name = "OP_??", .operands = 0 }} ** 256;

    // 0x00..0x08 — primitive constants
    t[0x00] = .{ .name = "NOP" };
    t[0x01] = .{ .name = "ACONST_NULL" };
    t[0x02] = .{ .name = "ICONST_M1" };
    t[0x03] = .{ .name = "ICONST_0" };
    t[0x04] = .{ .name = "ICONST_1" };
    t[0x05] = .{ .name = "ICONST_2" };
    t[0x06] = .{ .name = "ICONST_3" };
    t[0x07] = .{ .name = "ICONST_4" };
    t[0x08] = .{ .name = "ICONST_5" };
    t[0x09] = .{ .name = "LCONST_0" };
    t[0x0A] = .{ .name = "LCONST_1" };

    // 0x10..0x14 — pushes with operand
    t[0x10] = .{ .name = "BIPUSH", .operands = 1 };
    t[0x11] = .{ .name = "SIPUSH", .operands = 2 };
    t[0x12] = .{ .name = "LDC", .operands = 2 };
    t[0x14] = .{ .name = "LDC2_W", .operands = 2 };

    // ALOAD family
    t[0x19] = .{ .name = "ALOAD", .operands = 1 };
    t[0x2A] = .{ .name = "ALOAD_0" };
    t[0x2B] = .{ .name = "ALOAD_1" };
    t[0x2C] = .{ .name = "ALOAD_2" };
    t[0x2D] = .{ .name = "ALOAD_3" };

    // Typed array loads (BALOAD/CALOAD/AALOAD/IALOAD)
    t[0x2E] = .{ .name = "IALOAD" };
    t[0x32] = .{ .name = "AALOAD" };
    t[0x33] = .{ .name = "BALOAD" };
    t[0x34] = .{ .name = "CALOAD" };
    t[0x35] = .{ .name = "IALOAD" };

    // ASTORE family
    t[0x3A] = .{ .name = "ASTORE", .operands = 1 };
    t[0x4A] = .{ .name = "ASTORE_op", .operands = 1 };
    t[0x4B] = .{ .name = "ASTORE_0" };
    t[0x4C] = .{ .name = "ASTORE_1" };
    t[0x4D] = .{ .name = "ASTORE_2" };
    t[0x4E] = .{ .name = "ASTORE_3" };

    // Typed array stores (interpreter routes 0x4F..0x55 to one handler)
    t[0x4F] = .{ .name = "ARRSTORE" };
    t[0x50] = .{ .name = "ARRSTORE" };
    t[0x51] = .{ .name = "ARRSTORE" };
    t[0x52] = .{ .name = "ARRSTORE" };
    t[0x53] = .{ .name = "ARRSTORE" };
    t[0x54] = .{ .name = "ARRSTORE" };
    t[0x55] = .{ .name = "ARRSTORE" };

    // Stack manipulation
    t[0x56] = .{ .name = "POP" };
    t[0x57] = .{ .name = "POP" };
    t[0x58] = .{ .name = "POP2" };
    t[0x59] = .{ .name = "DUP" };
    t[0x5A] = .{ .name = "DUP_X1" };
    t[0x5C] = .{ .name = "DUP2" };

    // Arithmetic (ExEn-canonical opcodes — IADD at 0x60, IMUL at 0x68)
    t[0x60] = .{ .name = "IADD" };
    t[0x61] = .{ .name = "LADD" };
    t[0x64] = .{ .name = "ISUB" };
    t[0x65] = .{ .name = "LSUB" };
    t[0x68] = .{ .name = "IMUL" };
    t[0x6C] = .{ .name = "IDIV" };
    t[0x70] = .{ .name = "IREM" };
    t[0x74] = .{ .name = "INEG" };
    t[0x78] = .{ .name = "ISHL" };
    t[0x7A] = .{ .name = "ISHR" };
    t[0x7C] = .{ .name = "IUSHR" };
    t[0x7E] = .{ .name = "IAND" };
    t[0x80] = .{ .name = "IOR" };
    t[0x82] = .{ .name = "IXOR" };
    t[0x84] = .{ .name = "IINC", .operands = 2 };

    // Type conversion
    t[0x85] = .{ .name = "I2L" }; // canonical sub_40AE2B
    t[0x91] = .{ .name = "I2B" };
    t[0x92] = .{ .name = "I2C" };
    t[0x93] = .{ .name = "I2S" };
    t[0x94] = .{ .name = "LCMP" }; // canonical sub_40CC67 (unsigned 64-bit)

    // Branches — 2-byte target offset (16-bit aligned)
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

    // Returns
    t[0xB0] = .{ .name = "ARETURN" };
    t[0xB1] = .{ .name = "RETURN" };

    // Allocation + array length
    t[0xBB] = .{ .name = "NEW", .operands = 2 };
    t[0xBC] = .{ .name = "NEWARRAY", .operands = 2 };
    t[0xC5] = .{ .name = "MULTIANEWARRAY" }; // canonical sub_40E90A; variable operand length
    t[0xBE] = .{ .name = "ARRAYLENGTH" };

    // CHECKCAST + null-check branches
    t[0xC0] = .{ .name = "CHECKCAST", .operands = 2 };
    t[0xC6] = .{ .name = "IFNULL", .operands = 2 };
    t[0xC7] = .{ .name = "IFNONNULL", .operands = 2 };

    // Switches — variable length (caller inspects payload)
    t[0xCC] = .{ .name = "LOOKUPSWITCH", .operands = -1 };
    t[0xCD] = .{ .name = "TABLESWITCH", .operands = -1 };

    // Extended LOAD/STORE and strings
    t[0xD0] = .{ .name = "LDC_STRING", .operands = 2 };
    t[0xD5] = .{ .name = "LOAD_op", .operands = 1 };
    t[0xD6] = .{ .name = "STORE_op", .operands = 1 };
    t[0xD9] = .{ .name = "ALOAD_0_DUP" };
    t[0xDA] = .{ .name = "STORE_0" };
    t[0xDB] = .{ .name = "LLOAD_0" };
    t[0xDC] = .{ .name = "LSTORE_0" };
    t[0xDD] = .{ .name = "LOAD_1" };
    t[0xDE] = .{ .name = "STORE_1" };
    t[0xDF] = .{ .name = "LLOAD_1" };
    t[0xE0] = .{ .name = "LSTORE_1" };
    t[0xE1] = .{ .name = "LOAD_2" };
    t[0xE2] = .{ .name = "STORE_2" };
    t[0xE3] = .{ .name = "LLOAD_2" };
    t[0xE4] = .{ .name = "LSTORE_2" };
    t[0xE5] = .{ .name = "LOAD_3" };
    t[0xE6] = .{ .name = "STORE_3" };
    t[0xE7] = .{ .name = "LLOAD_3" };
    t[0xE8] = .{ .name = "LSTORE_3" };
    t[0xE9] = .{ .name = "IRETURN" };
    t[0xEA] = .{ .name = "LRETURN" };

    // Method invocation — 2-byte descriptor offset
    t[0xED] = .{ .name = "INVOKEVIRTUAL_ALT", .operands = 2 };
    t[0xEE] = .{ .name = "INVOKEVIRTUAL", .operands = 2 };
    t[0xEF] = .{ .name = "INVOKE_OWN", .operands = 2 };
    t[0xF0] = .{ .name = "INVOKESPECIAL", .operands = 2 };
    t[0xF1] = .{ .name = "INVOKESTATIC_ALT", .operands = 2 };
    t[0xF2] = .{ .name = "INVOKESTATIC", .operands = 2 };

    // Field access — 2-byte descriptor offset
    t[0xF3] = .{ .name = "GETSTATIC", .operands = 2 };
    t[0xF4] = .{ .name = "PUTSTATIC", .operands = 2 };
    t[0xF5] = .{ .name = "GETFIELD_OWN", .operands = 2 };
    t[0xF6] = .{ .name = "PUTFIELD_OWN", .operands = 2 };
    t[0xF7] = .{ .name = "GETSTATIC_FULL", .operands = 2 };
    t[0xF8] = .{ .name = "PUTSTATIC_FULL", .operands = 2 };
    t[0xF9] = .{ .name = "GETFIELD", .operands = 2 };
    t[0xFA] = .{ .name = "PUTFIELD", .operands = 2 };

    break :blk t;
};

/// Return the opcode mnemonic (e.g. "INVOKEVIRTUAL"). Falls back to
/// `"OP_??"` for unbound slots.
pub fn opName(op: u8) []const u8 {
    return opcodes[op].name;
}

/// Class hash → human name. Returns `null` for unknown classes (the
/// caller should fall back to the raw hex hash). All 54 built-in 4CVP
/// records from `unk_4494F0.bin` are covered — names recovered by
/// scanning each record's bytes for a substring whose CRC32 matches
/// the record's hash (so every name here is canonical-verified).
pub fn className(hash: u32) ?[]const u8 {
    return switch (hash) {
        // java.lang.*
        0x4161c4a6 => "java.lang.Object",
        0x7772dde3 => "java.lang.String",
        0x42816699 => "java.lang.Class",
        0x47cb31c2 => "java.lang.StringBuffer",
        0x72737f61 => "java.lang.Exception",
        0xb00cb273 => "java.lang.Throwable",
        0xb21fbad6 => "java.lang.ClassLoader",
        0x20817ec1 => "java.lang.System",
        0xf217c377 => "java.lang.Error",
        0x1c65ec89 => "java.lang.Boolean",
        0x5da4d0c7 => "java.lang.Byte",
        0x9ec04138 => "java.lang.Character",
        0x2b927978 => "java.lang.Cloneable",
        0xefac077f => "java.lang.CloneNotSupportedException",
        0xccefcfea => "java.lang.Integer",
        0xfbf3e3c1 => "java.lang.Long",
        0xf2f8aa1c => "java.lang.OutOfMemoryError",
        0x62caf278 => "java.lang.VirtualMachineError",
        0x20e2efa4 => "java.lang.Short",

        // java.io.*
        0xf050084a => "java.io.Serializable",

        // vm.sys.*
        0x6551f7dc => "vm.sys.Bootstrap",
        0xb4f0ccbf => "vm.sys.Runtime",
        0x1a8f99cc => "vm.sys.Application",

        // exen.* (built-ins)
        0xc6ed8e2a => "exen.Graphics",
        0x23c5e7e8 => "exen.Image",
        0xbab5c664 => "exen.Resource",
        0xe127b0e1 => "exen.Gamelet",
        0xe7167d52 => "exen.AnimBitmap",
        0x7219d0b4 => "exen.PlayField",
        0xd414954a => "exen.AnimFlash",
        0x02255f70 => "exen.Displayable",
        0x6bddc5b7 => "exen.Sms",
        0xb6ee3b2a => "exen.DialogBox",
        0xd8f81132 => "exen.FX",
        0xdf774e57 => "exen.List",
        0x3298b202 => "exen.Math",
        0x8f9e8280 => "exen.Matrix3D",
        0xe36f9667 => "exen.Vector3D",
        0xd0b8e4ac => "exen.RayCast",
        0x11749d8a => "exen.util.Debug",
        0x1c4d8791 => "exen.Command",
        0x5562ca3b => "exen.Palette",
        0xf7f39575 => "exen.Component",
        0x335fb0fe => "exen.Animation",
        0x3834a617 => "exen.TextureMap",
        0xf214cebb => "exen.Rectangle",
        0x60fe5152 => "exen.Sprite",
        0xd4a75556 => "exen.CommandListener",
        0x36a7404d => "exen.Palette_RAW",
        0x9ac35be7 => "exen.Point2D",
        0xd0c31058 => "exen.RawData",

        // The "GameletBase" we previously labelled by structural role.
        // Real canonical name: `exen.GameletEnhanced`. The intermediate
        // class that extends `exen.Gamelet`, owns `m_displayable`,
        // delegates lifecycle (onKeyPress, onTimerTick, paint) plus a
        // `setDisplayable` setter — most user gamelets (Crash's,
        // Terminator's, Pikubi's top-level class) extend this rather
        // than `exen.Gamelet` directly.
        0x3c0c89c6 => "exen.GameletEnhanced",

        // catalog.*
        0xbbd967f9 => "catalog.Catalog",
        0xdd22a4ed => "catalog.GameProperty",

        else => null,
    };
}

/// Compound key combining (class_hash, method_hash) for precise lookup.
/// Hash collisions are common (e.g., `<init>` hashes to `0x3f52ef2f`
/// across 30+ classes), so we key on both: the VM resolves method calls
/// scoped to the receiver's class, and the trace formatter mirrors
/// that to print the canonical class-qualified name.
fn classMethodKey(class_hash: u32, method_hash: u32) u64 {
    return (@as(u64, class_hash) << 32) | @as(u64, method_hash);
}

/// (class_hash, method_hash) → "Class.method" — VERIFIED entries only.
///
/// Each entry below has been structurally verified against:
///   1. The method_table row in `docs/extracted/<class>.md`
///   2. The strings-region candidate name in the same .md
///   3. The canonical sub_* body in `reference/ref`
///
/// Returns null for any (class, method) pair that hasn't been
/// verified yet — the trace formatter (`log_fmt.methodStr`) then
/// falls back to showing the raw `0xHHHHHHHH` hash. This is
/// intentional: a hash with no name is honest; a hash with a wrong
/// name (positional drift) is worse than no name at all.
///
/// To add an entry: walk the (idx, sub_*) row in
/// `docs/native_walkthrough.md`, confirm via the workflow above,
/// then add `0xCCCCCCCCMMMMMMMM => "Class.method",` here.
pub fn methodName(class_hash: u32, method_hash: u32) ?[]const u8 {
    return switch (classMethodKey(class_hash, method_hash)) {
        // ── exen.Gamelet (0xe127b0e1) — Display-capability quintet ─────
        0xe127b0e1f53ebe5a => "Gamelet.isColor",         // idx 67, sub_424F70
        0xe127b0e1d7241794 => "Gamelet.numColors",       // idx 68, sub_424F86
        0xe127b0e1d72412a6 => "Gamelet.getBitmapDepth",  // idx 69, sub_424FAC
        0xe127b0e1d724429e => "Gamelet.getScreenWidth",  // idx 70, sub_424F99
        0xe127b0e1d724a161 => "Gamelet.getScreenHeight", // idx 71, sub_424FBF
        0xe127b0e1bc1d842c => "Gamelet.screenUpdate",     // idx 72, sub_424FF2 → flush offscreen to LCD
        0xe127b0e13f52686f => "Gamelet.exitVm",           // idx 73, sub_424FD2 → stop audio + reset device + exit flag
        0xe127b0e1305afb51 => "Gamelet.throwInternalException", // idx 74, sub_42506C → print + audio.stop + sub_407A13 halt
        0xe127b0e1305a3e02 => "Gamelet.startTimer",       // idx 76, sub_4250A3 → Win32 SetTimer wrapper
        0xe127b0e13f5219b9 => "Gamelet.stopTimer",        // idx 77, sub_4250BA → sub_406868 KillTimer; Zig: g_timer_period_ms = 0
        0xe127b0e1d7241463 => "Gamelet.getTimerTickCount", // idx 75, sub_425090 → sub_435D3F → GetTickCount() - boot_origin
        0xe127b0e1ea228a2e => "Gamelet.sendSms",          // idx 78, sub_4250C7: sub_42989D(name) SMS lookup → sub_4218D3 send; on miss: halt+state=3
        0xe127b0e16f6c1196 => "Gamelet.saveCtx",          // idx 79, sub_425156 → write byte[] to EEPROM save
        0xe127b0e16f6c1c2e => "Gamelet.loadCtx",          // idx 80, sub_4251D4 → read EEPROM save into byte[]
        0xe127b0e13f52acbf => "Gamelet.playVibrator",    // idx 81, sub_4253BC → if (device_has_vibrator) sub_434189(1000); argc=0 void (strings region row 60)
        0xe127b0e16f6cfd65 => "Gamelet.playMelody",      // idx 82, sub_425252 → sub_406601 device play
        0xe127b0e13f527866 => "Gamelet.stopMelody",      // idx 83, sub_4252DF → sub_406628 device stop
        0xe127b0e1b14f142d => "Gamelet.getNickName",     // idx 84, sub_4252EC → "Xcell" default profile
        0xe127b0e18a09c398 => "Gamelet.getVersionInfo",  // idx 87, sub_425427 → "FrameWork" → "V2.00" lookup

        // ── exen.Image (0x23c5e7e8) — palette + transparency + decode ──
        0x23c5e7e83f524ae3 => "Image.updateNativePaletteFromJavaPalette", // idx 15, sub_426235 (push)
        0x23c5e7e8d72472df => "Image.getNativePaletteSize",               // idx 16, sub_426302 (query)
        0x23c5e7e83f52d9c4 => "Image.updateJavaPaletteFromNativePalette", // idx 17, sub_426357 (pull)
        0x23c5e7e85aab0fd5 => "Image.setTransparentColor",   // idx 18, sub_426419
        0x23c5e7e8305ada09 => "Image.setPaletteAlpha",       // idx 19, sub_4264A3
        0x23c5e7e8d724fb06 => "Image.getTransparentColor",   // idx 20, sub_4264ED
        0x23c5e7e83f52b439 => "Image.removeTransparentColor",// idx 21, sub_426548
        0x23c5e7e8d7249a2e => "Image.getSizeOfEXimgStruct", // idx 22, sub_426210: returns literal 88 = sizeof(EXimg)
        0x23c5e7e8d724f604 => "Image.getManufDisplayHeaderSize", // idx 23, sub_426222: returns 0 (no manuf header)
        0x23c5e7e88a2a7e4d => "Image.<init>",                // idx 24, sub_4267F6: (w, h, depth) → void
        0x23c5e7e83f52d9a9 => "Image.transformToSystemPalette", // idx 25, sub_426589
        0x23c5e7e84f46098d => "Image.TransformBitmapFromResExed", // idx 26, sub_4265CA
        0x23c5e7e8a730ffdc => "Image.GetBitmapDepthFromResExed", // idx 27, sub_42664C: PNG IHDR parse → bit-depth (4 or 8)
        0x23c5e7e88206098d => "Image.TransformBitmapFromByteArray", // idx 28, sub_4266A1: decode byte[] payload INTO this Image
        0x23c5e7e86a70ffdc => "Image.GetBitmapDepthFromByteArray",  // idx 29, sub_426732: PNG IHDR parse from byte[] → bit-depth

        // ── java.lang.String (0x7772dde3) ──────────────────────────────
        0x7772dde3d045a46b => "Integer.toString",        // idx 165, sub_42ACB6: int → new String via itoa
        0x7772dde3d724ffd6 => "String.length",           // idx 158, sub_42AC79: reads u16 length prefix at char[]+0
        0x7772dde3b14f9686 => "String.getBytes",         // idx 159, sub_42A7B0: char[] → byte[] low-byte truncation
        0x7772dde36f6c22cb => "String.toUpperCase",      // idx 164, sub_42AB8C: copy-uppercase of arg into this.char[]
        0x7772dde3a0c67fcc => "String.toLowerCase",      // idx 160, sub_42A99F: copy-lowercase of this into a new String (verified via TourDeFrance trace)
        0x7772dde335b022cb => "String.<init>(byte[])",   // idx 163, sub_42AAFC: copies src byte[] into this.bytes
        0x7772dde3f33e22cb => "String.<init>(String)",   // idx 162, sub_42AA54: copy constructor — clones src String's char[] into this
        0x7772dde31b487e6f => "String.compareTo",        // idx 161, sub_42A85E: lexicographic compare; length tiebreak is REVERSED from Java spec (canonical quirk)

        // ── java.lang.Class (0x42816699) ───────────────────────────────
        0x4281669970063066 => "Class.forName",           // idx 155, sub_42A3BE: String → Class handle
        0x42816699d5710176 => "Class.newInstance",       // idx 156, sub_42A360: Class.this → new Object handle

        // ── exen.FX (0xd8f81132) ───────────────────────────────────────
        0xd8f811322d3e3675 => "FX.doRotozoomImage",      // idx 103, sub_424B70: rotozoom blit (image, gfx, x, y, angle, scale)
        0xd8f81132a845a8fd => "FX.doVerticalShutter",    // idx 107, sub_424E40: vertical-shutter blit (verified via Spyro trace)

        // ── exen.AnimBitmap (0xe7167d52) ───────────────────────────────
        0xe7167d523526a6fc => "AnimBitmap.draw",         // idx 43, sub_42469C: per-frame sprite blit via sub_4243D0 rect lookup
        0xe7167d52d82cb6c4 => "AnimBitmap.getRealFrame", // idx 45, sub_42467B: idx %% nbFrame with optional frameSequence remap (verified via Spyro trace)

        // ── exen.Math (0x3298b202) ─────────────────────────────────────
        0x3298b202305a2eee => "Math.setRandSeed",        // idx 120, sub_426AB4: store seed → PRNG state
        0x3298b202d7246024 => "Math.random",             // idx 121, sub_426ACA: pair-state PRNG → next u32
        0x3298b202d82c715b => "Math.abs",                // idx 119, sub_426A84: if (*a1 < 0) v2 = -*a1 else v2 = *a1
        0x3298b202d82c6eba => "Math.sin",                // idx 110, sub_426990: sin via SinusPeriod table (verified via Spyro trace)
        0x3298b202d82c749b => "Math.cos",                // idx 111, sub_4269AC: cos via SinusPeriod table (verified via Spyro trace)
        0x3298b202d82c507a => "Math.sqrt",               // idx 122, sub_426ADD: sub_41CE03 intSqrt + (-5 → -1) remap (verified via MotoGp trace)

        // ── exen.util.Debug (0x11749d8a) ───────────────────────────────
        0x11749d8a305aa2f2 => "Debug.printInt",          // idx 150, sub_429FC2: sub_422D10 format → sub_434760 host-print

        // ── exen.Displayable (0x02255f70) ──────────────────────────────
        0x02255f70f53edf41 => "Displayable.haveDisplayableCommand", // idx 65, sub_424A60: always returns 1 (device has command bar)
        0x02255f70857f21f9 => "Displayable.drawText",     // idx 66, sub_424A9D: save clip, set full-bitmap clip, blit (graphics, char[], color) via sub_4238F0, restore clip

        // ── exen.Sms (0x6bddc5b7) — SMS message composer (bit-stream API) ─
        // Names paired from extracted SMS class docs (method_table row → strings region row by argc + return type).
        0x6bddc5b73f529508 => "Sms.deleteSms",    // idx 89, sub_429A18: empty body — `return 0;`
        0x6bddc5b73f52ea09 => "Sms.createSms",    // idx 90, sub_4298C8: signature + header bits + a2[9..12]=0
        0x6bddc5b76f6cea09 => "Sms.createSms(byte[])", // idx 91, sub_42993B: byte[]-payload variant of createSms
        0x6bddc5b719fc8e2d => "Sms.createBlock",  // idx 92, sub_429A20: write block_id + reserve 11-bit count slot
        0x6bddc5b766ffc4af => "Sms.readBits",     // idx 93, sub_429AC0: bit-stream read
        0x6bddc5b77c081dfe => "Sms.writeBits",    // idx 94, sub_429B0A: bit-stream write
        0x6bddc5b7d724894d => "Sms.endBlock",     // idx 95, sub_429B8D: compute payload bit-length, write back to count slot, return length

        // ── exen.PlayField (0x7219d0b4) — tile-grid cell ops + composite ─
        0x7219d0b4603f215f => "PlayField.fillCells",       // idx 46, sub_427013: rect-fill cells with tile, bounds-clamped
        0x7219d0b488e6287e => "PlayField.moveTiles",       // idx 47, sub_42712F: overlap-safe copy of cell block (sx,sy)→(dx,dy)
        0x7219d0b4af9ba6fc => "PlayField.draw",            // idx 48, sub_427531: per-cell readCell + sub_418008 blit, state==6 default path
        0x7219d0b48a2afd3a => "PlayField.setCellTile",     // idx 49, sub_426FA8: bounds-check + writeCell(buf, x, y, tile)
        0x7219d0b4546bd22a => "PlayField.getCellTile",     // idx 50, sub_426F37: bounds-check + readCell(buf, x, y)
        0x7219d0b498941c13 => "PlayField.addSprite",       // idx 51, sub_427F95: append sprite to active list (head/tail link via +52/+56)
        0x7219d0b498949e99 => "PlayField.removeSprite",    // idx 52, sub_4280BD: unlink sprite from active list
        0x7219d0b43f52cca4 => "PlayField.removeAllSprite", // idx 53, sub_428208: walk list head, zero each sprite's next/prev, clear head/tail

        // ── java.lang.StringBuffer (0x47cb31c2) ────────────────────────
        0x47cb31c2d724ffd6 => "StringBuffer.length",          // idx 167, sub_42B17D: *a1 = *(u16*)(this[+24]); — buffer length-word
        0x47cb31c2305ae3ec => "StringBuffer.initStringBuffer", // idx 166, sub_42AEEF: sub_42AF2F(this, cap) capacity init
        0x47cb31c25afc22cb => "StringBuffer.append(String)",    // idx 169, sub_42B056: memcpy src.chars onto this.chars
        0x47cb31c2984422cb => "StringBuffer.append(char)",      // idx 171, sub_42B19F: ensureCapacity(+1) + write low byte + length++
        0x47cb31c2501322cb => "StringBuffer.append(int)",       // idx 172, sub_42B1ED: ensureCapacity(+11) + itoa via sub_411490
        0x47cb31c2b2ba3939 => "StringBuffer.toString",          // idx 174, sub_42AE4E: alloc new String + dup this.value

        // ── exen.Vector3D (0xe36f9667) ─────────────────────────────────
        0xe36f9667d72430ea => "Vector3D.squareLength",   // idx 129, sub_42A020: (x>>8)² + (y>>8)² + (z>>8)²
        0xe36f9667d724ffd6 => "Vector3D.length",         // idx 130, sub_42A074: sqrt(x²+y²+z²) via sub_41CEFA, -5→-1

        // ── exen.Graphics (0xc6ed8e2a) — all 15 natives idx 0..14 ──────
        0xc6ed8e2acf201fef => "Graphics.clearRect",      // idx 0,  sub_425C73 → fill with palette[255]
        0xc6ed8e2a43d2c07b => "Graphics.drawImage",      // idx 1,  sub_425699 → sub_418008 scaled/rotated blit
        0xc6ed8e2acf20ea2f => "Graphics.drawLine",       // idx 2,  sub_4257A1 → sub_4179D2 line rasterizer
        0xc6ed8e2a88e6858f => "Graphics.drawTriangle",   // idx 3,  sub_42585A → sub_417E45 polyline(n=3)
        0xc6ed8e2acf20931f => "Graphics.drawRect",       // idx 4,  sub_425940 → sub_417E45 polyline(n=4)
        0xc6ed8e2a81ff7c1a => "Graphics.drawChars",      // idx 5,  sub_425A50 → device-vtable[3] text-blit
        0xc6ed8e2a88e617a3 => "Graphics.fillTriangle",   // idx 6,  sub_425BA4 → sub_41885C scanline fill (STUB body)
        0xc6ed8e2acf209d48 => "Graphics.fillRect",       // idx 7,  sub_425D20 → sub_417D92 rect fill
        0xc6ed8e2a37003480 => "Graphics.fillTextureTriangle", // idx 8, sub_425DD8 → sub_4181E8 textured tri (STUB)
        0xc6ed8e2a8a2a1ed6 => "Graphics.setPixel",       // idx 9,  sub_425F6E → sub_417F1D single-pixel write
        0xc6ed8e2a546b5370 => "Graphics.getPixel",       // idx 10, sub_426015 → sub_417F97 single-pixel read
        0xc6ed8e2acf203326 => "Graphics.setClip",        // idx 11, sub_426096 → clamp+store clip rect
        0xc6ed8e2a3f52c140 => "Graphics.setInverseVideo",// idx 12, sub_426172 → sub_4022F1(1)
        0xc6ed8e2a3f52e55d => "Graphics.setNormalVideo", // idx 13, sub_426184 → sub_4022F1(0)
        0xc6ed8e2a8a2a1ebb => "Graphics.setColor",       // idx 14, sub_426196 → pack RGB → palette index lookup

        // ── exen.Resource (0xbab5c664) ─────────────────────────────────
        0xbab5c6642c81f11e => "Resource.<init>",         // idx 30, sub_428AA0: open by id, set base/length
        0xbab5c664f53eb8d1 => "Resource.readBoolean",    // idx 31, sub_428B4E: read 1 byte, advance pos, return (byte & 1)
        0xbab5c664d724d73f => "Resource.readInt",        // idx 32, sub_428BE5: read u32 LE, advance pos
        0xbab5c66468ff7ece => "Resource.readShort",      // idx 33, sub_428C79: read u16 LE, advance pos
        0xbab5c66469f7348d => "Resource.readByte",       // idx 34, sub_428D0D: read 1 byte, advance pos
        0xbab5c6642c811ec5 => "Resource.readBytes",      // idx 36, sub_428E41: read N bytes → byte[]
        0xbab5c664b2baae4a => "Resource.readUTF",        // idx 39, sub_429265: 2-byte length-prefixed Modified-UTF-8 → String
        0xbab5c664d0457739 => "Resource.readStringByIndex", // idx 40, sub_4295DF: read Nth 0xFF-separated string (pos NOT advanced)
        0xbab5c664d724e690 => "Resource.getResourceType",// idx 42, sub_429813: resource_flag_array[this.id]

        else => methodNameUnscoped(method_hash),
    };
}

pub fn methodNameUnscoped(hash: u32) ?[]const u8 {
    return switch (hash) {
        0x3f52ef2f => "<init>",
        0x3f5201b3 => "<clinit>",
        // The 8 Bootstrap-dispatched lifecycle hashes (shared with
        // Gamelet.on*). Collide across Displayable/Gamelet/GameletEnhanced
        // — show the canonical lifecycle name when class context is
        // unavailable.
        0x305ac1c2 => "onKeyPress",
        0x305a4030 => "onKeyRelease",
        0x3f52500b => "onTimerTick",
        0x35b0eb39 => "onInit",
        0x6f6c0565 => "onSmsReceived",
        0x305a7631 => "onSmsSent",
        0x35b0015c => "onNickNameChanged",
        0x3f523566 => "onExit",
        else => null,
    };
}

/// (class_hash, field_hash) → "Class.field". Same extraction pipeline
/// as methodName; field hashes can collide with method hashes across
/// classes (the VM disambiguates by opcode — GETFIELD/PUTFIELD vs
/// INVOKEVIRTUAL), so we keep a separate switch.
pub fn fieldName(class_hash: u32, field_hash: u32) ?[]const u8 {
    return switch (classMethodKey(class_hash, field_hash)) {
        // AnimBitmap (0xe7167d52)
        0xe7167d5218220a39 => "AnimBitmap.frameSequence",
        0xe7167d523dd39153 => "AnimBitmap.image",
        0xe7167d52a7f97fb5 => "AnimBitmap.listCoords",
        0xe7167d52d0425721 => "AnimBitmap.WITHMASK",
        0xe7167d52d0425e87 => "AnimBitmap.height",
        0xe7167d52d0426be6 => "AnimBitmap.width",
        0xe7167d52d04283a5 => "AnimBitmap.INVERSEVIDEO",
        0xe7167d52d042ec80 => "AnimBitmap.state",
        0xe7167d52d042f952 => "AnimBitmap.nbFrame",
        // AnimFlash (0xd414954a)
        0xd414954aa6f1ed5c => "AnimFlash.swfBuffer",
        0xd414954ad0425e87 => "AnimFlash.height",
        0xd414954ad0426be6 => "AnimFlash.width",
        0xd414954ad042895a => "AnimFlash.ty",
        0xd414954ad04298d3 => "AnimFlash.tx",
        0xd414954ad042bb71 => "AnimFlash.ctx",
        // Bootstrap (0x6551f7dc)
        0x6551f7dc4bb1375c => "Bootstrap.gamelet",
        // Class (0x42816699)
        0x428166996f990b75 => "Class.m_tClassType",
        0x42816699d0425d40 => "Class.m_refClassSeg",
        // Command (0x1c4d8791)
        0x1c4d8791529dd503 => "Command.m_label",
        0x1c4d8791d0422deb => "Command.CANCEL",
        0x1c4d8791d0425580 => "Command.m_type",
        0x1c4d8791d042c9c1 => "Command.OK",
        // Component (0xf7f39575)
        0xf7f39575d042e1c1 => "Component.height",
        0xf7f39575d042f048 => "Component.width",
        // DialogBox (0xb6ee3b2a)
        0xb6ee3b2a529dba7e => "DialogBox.m_text",
        0xb6ee3b2a529dc72e => "DialogBox.m_title",
        0xb6ee3b2ad042076c => "DialogBox.m_maxLinesToScroll",
        0xb6ee3b2ad04227f9 => "DialogBox.m_justify",
        0xb6ee3b2ad042322a => "DialogBox.JUSTIFY_LEFT",
        0xb6ee3b2ad0423c5c => "DialogBox.m_cptRate",
        0xb6ee3b2ad0425333 => "DialogBox.m_startTextY",
        0xb6ee3b2ad0425dca => "DialogBox.JUSTIFY_CENTER",
        0xb6ee3b2ad0427104 => "DialogBox.m_modRate",
        0xb6ee3b2ad042747b => "DialogBox.m_modCursor",
        0xb6ee3b2ad042beea => "DialogBox.JUSTIFY_RIGHT",
        0xb6ee3b2ad042d805 => "DialogBox.m_scrollLine",
        0xb6ee3b2ad042f0ad => "DialogBox.m_cptCursor",
        0xb6ee3b2ad1eafb8b => "DialogBox.m_sprite",
        0xb6ee3b2af2585a5e => "DialogBox.m_doDisplayCursor",
        0xb6ee3b2af25878d5 => "DialogBox.m_doRepaintSprite",
        0xb6ee3b2af258ffd9 => "DialogBox.m_doRepaintCursor",
        // Displayable (0x02255f70)
        0x02255f7034744ed9 => "Displayable.m_listener",
        0x02255f704bb19978 => "Displayable.m_gamelet",
        0x02255f70936b432d => "Displayable.m_commands",
        0x02255f70d042289c => "Displayable.m_height",
        0x02255f70d042a6de => "Displayable.m_timerLength",
        0x02255f70d042dfc3 => "Displayable.m_width",
        0x02255f70f2584c0f => "Displayable.m_displayCommands",
        // GameProperty (0xdd22a4ed)
        0xdd22a4ed529d8a90 => "GameProperty.name",
        0xdd22a4edd04278ab => "GameProperty.priceCurrency",
        0xdd22a4edd042903a => "GameProperty.zoneId",
        0xdd22a4edd042c630 => "GameProperty.stringResourceId",
        0xdd22a4edd042dce5 => "GameProperty.size",
        0xdd22a4edd042e190 => "GameProperty.fileId",
        0xdd22a4edd042f002 => "GameProperty.previewResourceId",
        0xdd22a4edd042fb19 => "GameProperty.melodyResourceId",
        // Gamelet (0xe127b0e1)
        0xe127b0e1260e00f6 => "Gamelet.gBuff",
        0xe127b0e13dd39153 => "Gamelet.image",
        0xe127b0e1d0420495 => "Gamelet.KEY_NUM3",
        0xe127b0e1d0420e1c => "Gamelet.KEY_POUND",
        0xe127b0e1d0420f72 => "Gamelet.UP",
        0xe127b0e1d042151c => "Gamelet.KEY_NUM2",
        0xe127b0e1d0421558 => "Gamelet.KEY_VAL",
        0xe127b0e1d042199c => "Gamelet.KEY_PAD_LEFT",
        0xe127b0e1d0421e4e => "Gamelet.DOWN",
        0xe127b0e1d0422787 => "Gamelet.KEY_NUM1",
        0xe127b0e1d0422afa => "Gamelet.GAME_D",
        0xe127b0e1d042318a => "Gamelet.FIRE",
        0xe127b0e1d042360e => "Gamelet.KEY_NUM0",
        0xe127b0e1d04242b1 => "Gamelet.KEY_NUM7",
        0xe127b0e1d0424fcc => "Gamelet.GAME_B",
        0xe127b0e1d0425338 => "Gamelet.KEY_NUM6",
        0xe127b0e1d0425e45 => "Gamelet.GAME_C",
        0xe127b0e1d04261a3 => "Gamelet.KEY_NUM5",
        0xe127b0e1d04265c4 => "Gamelet.KEY_PAD_UP",
        0xe127b0e1d0426e7c => "Gamelet.KEY_PAD_RIGHT",
        0xe127b0e1d042702a => "Gamelet.KEY_NUM4",
        0xe127b0e1d0427d57 => "Gamelet.GAME_A",
        0xe127b0e1d042aac2 => "Gamelet.RIGHT",
        0xe127b0e1d042abcf => "Gamelet.KEY_NUM9",
        0xe127b0e1d042b0d5 => "Gamelet.SMS_SENT_UNSUCCESSFULLY",
        0xe127b0e1d042ba46 => "Gamelet.KEY_NUM8",
        0xe127b0e1d042bb7e => "Gamelet.LEFT",
        0xe127b0e1d042bcac => "Gamelet.KEY_PAD_DOWN",
        0xe127b0e1d042cd48 => "Gamelet.KEY_STAR",
        0xe127b0e1d042f1b7 => "Gamelet.KEY_CLEAR",
        0xe127b0e1d042f342 => "Gamelet.SMS_SENT_SUCCESSFULLY",
        0xe127b0e1fd9580df => "Gamelet.palette",
        // GameletEnhanced (0x3c0c89c6)
        0x3c0c89c640347414 => "GameletEnhanced.m_displayable",
        // Graphics (0xc6ed8e2a)
        0xc6ed8e2a3dd3bff1 => "Graphics.pixIma",
        0xc6ed8e2a6f9915d9 => "Graphics.PM_NAND",
        0xc6ed8e2a6f991654 => "Graphics.PM_AND",
        0xc6ed8e2a6f994aa8 => "Graphics.PM_COPY",
        0xc6ed8e2a6f9963b0 => "Graphics.PM_XOR",
        0xc6ed8e2a6f998aea => "Graphics.curPaintMode",
        0xc6ed8e2a6f99a5cf => "Graphics.PM_OR",
        0xc6ed8e2a6f99ebea => "Graphics.PM_INVCOPY",
        0xc6ed8e2ad04224f4 => "Graphics.clipY",
        0xc6ed8e2ad042357d => "Graphics.clipX",
        0xc6ed8e2ad042441a => "Graphics.black",
        0xc6ed8e2ad0424e9a => "Graphics.TOP",
        0xc6ed8e2ad04253c7 => "Graphics.white",
        0xc6ed8e2ad0427a64 => "Graphics.clipWidth",
        0xc6ed8e2ad042bb7e => "Graphics.LEFT",
        0xc6ed8e2ad042cece => "Graphics.curColorIDX",
        0xc6ed8e2ad042f98c => "Graphics.clipHeight",
        // Image (0x23c5e7e8)
        0x23c5e7e8a6f1230d => "Image.image_imgT",
        0x23c5e7e8a6f15ba5 => "Image.image_Data",
        0x23c5e7e8d0425e87 => "Image.height",
        0x23c5e7e8d0426be6 => "Image.width",
        0x23c5e7e8d042b3aa => "Image.depth",
        0x23c5e7e8fd9580df => "Image.palette",
        // List (0xdf774e57)
        0xdf774e5718229b23 => "List.m_properties",
        0xdf774e5782081533 => "List.m_captions",
        0xdf774e57d0429698 => "List.m_current",
        0xdf774e57d042c5e5 => "List.LEAF",
        0xdf774e57d042df3e => "List.BRANCH",
        // Math (0x3298b202)
        0x3298b202d042b9fc => "Math.ERROR",
        0x3298b202d042fc8a => "Math.PI",
        // Matrix3D (0x8f9e8280)
        0x8f9e82801822f276 => "Matrix3D.element",
        // Palette (0x5562ca3b)
        0x5562ca3b18221e93 => "Palette.colorTabRGBA",
        0x5562ca3bd0421ecd => "Palette.staticPaletteVersion",
        0x5562ca3bd042d8f5 => "Palette.paletteVersion",
        // PlayField (0x7219d0b4)
        0x7219d0b43dd35280 => "PlayField.charSet",
        0x7219d0b4a6f13e72 => "PlayField.background",
        0x7219d0b4a7f9a686 => "PlayField.animTileIndex",
        0x7219d0b4d0420237 => "PlayField.ALL",
        0x7219d0b4d0420dbb => "PlayField.CHARSET_WITHMASK",
        0x7219d0b4d0422195 => "PlayField.viewX",
        0x7219d0b4d042301c => "PlayField.viewY",
        0x7219d0b4d0423114 => "PlayField.viewH",
        0x7219d0b4d04240e0 => "PlayField.animTileMaxIndex",
        0x7219d0b4d042415d => "PlayField.CHARSET_INVERSEVIDEO",
        0x7219d0b4d0424a14 => "PlayField.charW",
        0x7219d0b4d0425990 => "PlayField.CHARSET",
        0x7219d0b4d0426172 => "PlayField.nbBits",
        0x7219d0b4d0427691 => "PlayField.backgroundW",
        0x7219d0b4d0429ee7 => "PlayField.backgroundH",
        0x7219d0b4d042a262 => "PlayField.charH",
        0x7219d0b4d042aa63 => "PlayField.CHARSET_OPACITY",
        0x7219d0b4d042d962 => "PlayField.viewW",
        0x7219d0b4d042db25 => "PlayField.BACKGROUND",
        0x7219d0b4d042e597 => "PlayField.INDEX_TABLE",
        0x7219d0b4d042ec80 => "PlayField.state",
        0x7219d0b4d1ea9848 => "PlayField.lastSprite",
        0x7219d0b4d1ea9b34 => "PlayField.firstSprite",
        // RawData (0xd0c31058)
        0xd0c31058a6f1f432 => "RawData.m_data",
        0xd0c31058d0423616 => "RawData.m_currentBit",
        // RayCast (0xd0b8e4ac)
        0xd0b8e4ac88f81d8f => "RayCast.wallGraph_Table",
        0xd0b8e4ac88f81db0 => "RayCast.spriteImages",
        0xd0b8e4ac88f8b451 => "RayCast.maskImages",
        0xd0b8e4aca6f1240f => "RayCast.maze_map_pointer",
        0xd0b8e4aca6f13bf1 => "RayCast.internal_sprite_list",
        0xd0b8e4aca6f16466 => "RayCast.internal_rayc_values",
        0xd0b8e4aca6f17a61 => "RayCast.wallgraph_width_poxOf2",
        0xd0b8e4aca6f1a52d => "RayCast.sliceInfos",
        0xd0b8e4acd0429098 => "RayCast.num_monster_Max",
        0xd0b8e4acd042c2f5 => "RayCast.mapHeight",
        0xd0b8e4acd042d0fe => "RayCast.mapWidth",
        // Rectangle (0xf214cebb)
        0xf214cebbd042e1c1 => "Rectangle.height",
        0xf214cebbd042f048 => "Rectangle.width",
        // Resource (0xbab5c664)
        0xbab5c6646e91646d => "Resource.AUTHOR_NAME_CHUNK_ID",
        0xbab5c6646e917e81 => "Resource.GAME_NAME_CHUNK_ID",
        0xbab5c6646e91911c => "Resource.VERSION_BRANCH_CHUNK_ID",
        0xbab5c6646e91a1ff => "Resource.COMPILATION_DATE_CHUNK_ID",
        0xbab5c6646e91fb8e => "Resource.EXEN_FRAMEWORK_CHUNK_ID",
        0xbab5c664a6f11bf7 => "Resource._array",
        0xbab5c664d04255b5 => "Resource._len",
        0xbab5c664d0426778 => "Resource._id",
        0xbab5c664d042ab2b => "Resource._offset",
        0xbab5c664d042fc48 => "Resource._start",
        // Runtime (0xb4f0ccbf)
        0xb4f0ccbf49f9b655 => "Runtime.m_currentRuntime",
        0xb4f0ccbf5eebbb89 => "Runtime.m_defaultClassLoader",
        0xb4f0ccbfd042ed32 => "Runtime.m_nStatusCode",
        0xb4f0ccbff258a60a => "Runtime.m_bIsClosing",
        // Sms (0x6bddc5b7)
        0x6bddc5b76e910f1c => "Sms.MO_UNLOCK_ITEM",
        0x6bddc5b76e912cac => "Sms.MO_LOAD",
        0x6bddc5b76e914339 => "Sms.MT_LOAD",
        0x6bddc5b76e914a85 => "Sms.MT_ERROR",
        0x6bddc5b76e9169fd => "Sms.MT_ERROR_DATA_CAN_BE_FOUND",
        0x6bddc5b76e917653 => "Sms.MT_UNLOCK_ITEM",
        0x6bddc5b76e91820d => "Sms.MO_RANKING",
        0x6bddc5b76e918217 => "Sms.MT_ERROR_INTERNAL_SERVER_ERROR",
        0x6bddc5b76e9184ff => "Sms.MO_SAVE",
        0x6bddc5b76e919522 => "Sms.MT_REQUESTED_ITEM",
        0x6bddc5b76e91b46e => "Sms.MT_RESTORE",
        0x6bddc5b76e91d454 => "Sms.MT_RANKING",
        0x6bddc5b76e91e231 => "Sms.MO_SCORE",
        0x6bddc5b76e91e237 => "Sms.MO_RESTORE",
        0x6bddc5b76e91eb6a => "Sms.MT_SAVE",
        0x6bddc5b76e91ef38 => "Sms.MO_DOWNLOAD_ITEM",
        0x6bddc5b7a6f11c0e => "Sms.java_exsms",
        0x6bddc5b7d042022d => "Sms.m_tag",
        0x6bddc5b7d0425580 => "Sms.m_type",
        0x6bddc5b7d0425d9b => "Sms.SIZE_SMS",
        0x6bddc5b7d0428467 => "Sms.SMS_LEVEL_4",
        0x6bddc5b7d04289cd => "Sms.m_length",
        0x6bddc5b7d04295ee => "Sms.SMS_LEVEL_5",
        0x6bddc5b7d042a44f => "Sms.SMS_LAST_LEVEL",
        0x6bddc5b7d042adf9 => "Sms.m_pos",
        0x6bddc5b7d042cdf4 => "Sms.m_offset",
        0x6bddc5b7d042d3ca => "Sms.SMS_LEVEL_1",
        0x6bddc5b7d042d990 => "Sms.idGame",
        0x6bddc5b7d042e151 => "Sms.SMS_LEVEL_2",
        0x6bddc5b7d042f0d8 => "Sms.SMS_LEVEL_3",
        // Sprite (0x60fe5152)
        0x60fe51523bcb9986 => "Sprite.anim",
        0x60fe5152d0423f22 => "Sprite.prev",
        0x60fe5152d042538e => "Sprite.next",
        0x60fe5152d04265a2 => "Sprite.TRANSFORM_ROTATE_180",
        0x60fe5152d042773a => "Sprite.TRANSFORM_H_FLIP",
        0x60fe5152d0427787 => "Sprite.frame",
        0x60fe5152d042be63 => "Sprite.TRANSFORM_ROTATE_90",
        0x60fe5152d042c571 => "Sprite.TRANSFORM_ROTATE_270",
        0x60fe5152d042d35a => "Sprite.TRANSFORM_NONE",
        0x60fe5152d042e1c1 => "Sprite.transform",
        0x60fe5152d042f048 => "Sprite.isVisibleBool",
        0x60fe5152f2581bda => "Sprite.TRANSFORM_V_FLIP",
        // String (0x7772dde3)
        0x7772dde36f99bbef => "String.offset",
        0x7772dde36f99d469 => "String.count",
        0x7772dde3b7787b2d => "String.m_refArrayBuffer",
        0x7772dde3b7788185 => "String.value",
        0x7772dde3e2d9b514 => "String.m_strBuffer",
        // StringBuffer (0x47cb31c2)
        0x47cb31c2b7787b2d => "StringBuffer.m_refArrayBuffer",
        0x47cb31c2e2d9b514 => "StringBuffer.m_strBuffer",
        // TextureMap (0x3834a617)
        0x3834a617182219fc => "TextureMap.ptV",
        0x3834a61718222b67 => "TextureMap.ptU",
        0x3834a6173dd3345a => "TextureMap.pixImage",
        // Throwable (0xb00cb273)
        0xb00cb273529d5875 => "Throwable.detailMessage",

        else => null,
    };
}


/// Full table of native indices (0..184) → name. Generated by
/// `tools/extract_table.zig` from `assets/unk_4494F0.bin` — each
/// native method's `body_offset` in the .bin points to a u32 that IS
/// its `funcs_407AA2[]` index. The names here are the canonical labels
/// from the .bin's strings region; where the strings region didn't
/// pair a name (inherited methods or class-internal helpers), we fall
/// back to alternate-class lookup by hash, and finally to `?N`
/// placeholders for hashes that aren't named in any class.
///
/// Re-run `zig run tools/extract_table.zig` to regenerate. The
/// regenerator catches >100 mislabelings the prior hand-curated table
/// had — see `docs/extracted/<class>.md` for per-class details.
pub const native_names: [185][]const u8 = .{
    "Graphics.clearRect",
    "Graphics.drawImage",
    "Graphics.drawLine",
    "Graphics.drawTriangle",
    "Graphics.drawRect",
    "Graphics.drawChars",
    "Graphics.fillTriangle",
    "Graphics.fillRect",
    "Graphics.fillTextureTriangle",
    // Graphics natives 9..14 — labels match canonical sub bodies (the
    // .bin's positional pairing had setColor/setColorIndex/setPaintMode
    // shifted from setInverseVideo/setNormalVideo/setColor; we use the
    // behavioral names that match our handlers and the actual sub_*).
    "Graphics.setPixel",
    "Graphics.getPixel",
    "Graphics.setClip",
    "Graphics.setInverseVideo",
    "Graphics.setNormalVideo",
    "Graphics.setColor",
    // Image natives 15..29 — labels aligned with canonical sub bodies
    // (matches the rebound handlers in natives/exen/Image.zig). The
    // .bin's positional name-pairing drifted in this range; the labels
    // here describe what the sub at funcs_407AA2[N] actually does.
    "Image.updateNativePaletteFromJavaPalette",
    "Image.getNativePaletteSize",
    "Image.updateJavaPaletteFromNativePalette",
    "Image.setTransparentColor",
    "Image.setPaletteAlpha",
    "Image.getTransparentColor",
    "Image.removeTransparentColor",
    "Image.getSizeOfEXimgStruct",       // sub_426210 returns 88
    "Image.getManufDisplayHeaderSize",  // sub_426222 returns sub_4022C4()
    "Image.Init",                       // sub_4267F6 → sub_4176C7
    "Image.?25",                        // sub_426589 unidentified
    "Image.TransformBitmapFromResExed",
    "Image.transformToSystemPalette",
    "Image.TransformBlackAndWhiteBitmap",
    "Image.decodeCodec",                // sub_426732 codec-pick decode
    // Resource natives 30..42 — labels match canonical sub bodies.
    // The .bin's positional pairing shifted by 2 here (it claimed 39 =
    // getNbResources / 41 = getLength / 42 = readSound), but the sub
    // bodies reveal 39 = readUTF, 41 = getNbResources, 42 = getResourceType.
    "Resource.init",
    "Resource.readBoolean",
    "Resource.readInt",
    "Resource.readShort",
    "Resource.readByte",
    "Resource.readChar",
    "Resource.readBytes",
    "Resource.readShorts",
    "Resource.readInts",
    "Resource.readUTF",          // sub_429265 walks 0xFF delimiters
    "Resource.readString",       // sub_4295DF returns Nth string
    "Resource.getNbResources",   // sub_4297FA returns count
    "Resource.getResourceType",  // sub_429813 returns type byte
    "AnimBitmap.draw",
    "AnimBitmap.moduloFrame",
    "AnimBitmap.getRealFrame",
    "PlayField.fillCells",
    "PlayField.moveTiles",
    "PlayField.draw",
    "PlayField.setCellTile",
    "PlayField.getCellTile",
    "PlayField.addSprite",
    "PlayField.removeSprite",
    "PlayField.removeAllSprite",
    "AnimFlash.initAnimFlash",
    "AnimFlash.draw",
    "AnimFlash.delete",
    "AnimFlash.setFrame",
    "AnimFlash.getNbFrames",
    "AnimFlash.getNbLoops",
    "AnimFlash.setPosition",
    "AnimFlash.setSize",
    "AnimFlash.getRawFrames",
    "AnimFlash.getWidth",  // hash 0xd82c89f7 unnamed in AnimFlash, found as AnimBitmap.getWidth
    "AnimFlash.getHeight",  // hash 0xd82c5f6d unnamed in AnimFlash, found as AnimBitmap.getHeight
    "Displayable.?65",  // no name anywhere for hash 0xf53edf41
    "Displayable.drawText",  // idx 66, sub_424A9D: (graphics, char[], color) — saves clip, blits text via sub_4238F0, restores clip
    "Gamelet.getBitmapDepth",
    "Gamelet.getScreenWidth",
    "Gamelet.getScreenHeight",
    "Gamelet.screenUpdate",
    "Gamelet.exitVm",
    // The .bin labels idx 72 as "exit", but the canonical sub_424FF2 body
    // resolves a2+28 to a descriptor and calls sub_402304 — that's a
    // device-level FRAME FLUSH, not VM termination. Terminator's
    // playMelody routinely calls this hash as part of its tick loop.
    "Gamelet.screenUpdate",   // idx 72 sub_424FF2 — descriptor lookup + flush via sub_402304
    "Gamelet.exitVm",          // idx 73 sub_424FD2 — argc=0 stop-audio + reset-device + flag=1
    "Gamelet.throwInternalException", // idx 74 sub_410198 — argc=1 error code halt
    "Gamelet.stopTimer",
    "Gamelet.sendSms",
    "Gamelet.saveCtx",
    "Gamelet.loadCtx",
    "Gamelet.repaint",
    "Gamelet.update",
    "Gamelet.playVibrator",  // idx 81 sub_4253BC: if(device_has_vibrator) sub_434189(1000) — paired via strings region row 60 (argc=0 → void) + canonical body "ExManufVibrati" debug string
    "Gamelet.getNickName",
    "Gamelet.setNickName",
    "Gamelet.getVersionInfo",
    "Gamelet.getKeyCode",
    "Gamelet.getGameAction",
    "Gamelet.?87",  // no name anywhere for hash 0x8a09c398
    "Gamelet.?88",  // no name anywhere for hash 0x39524bcf
    "Sms.deleteSms",
    "Sms.createSms",
    "Sms.createSms",
    "Sms.createBlock",
    "Sms.readBits",
    "Sms.writeBits",
    "Sms.endBlock",
    "Sms.nextBlock",
    "Sms.getIdBlock",
    "Sms.getLengthBlock",
    "Sms.skipBits",
    "Sms.?100",  // no name anywhere for hash 0xb2ba469c
    "DialogBox.drawSprite",
    "DialogBox.?102",  // no name anywhere for hash 0x5fd77824
    "FX.doRotazoom",
    "FX.doMosaic",
    "FX.doShiftHorizontal",
    "FX.doShiftVertical",
    "FX.doShutterVertical",
    "FX.doShutterHorizontal",
    "List.drawList",
    "Math.sin",
    "Math.cos",
    "Math.getAngle",
    "Math.setSinusPeriod",
    "Math.getSinusPeriod",
    "Math.getSinOfPeriod",
    "Math.getCosOfPeriod",
    "Math.getCosPeriodPrecise",
    "Math.getSinPeriodPrecise",
    "Math.abs",
    "Math.setRandSeed",
    "Math.random",
    "Math.sqrt",
    "Matrix3D.copyFrom",
    "Matrix3D.rotX",
    "Matrix3D.rotY",
    "Matrix3D.rotZ",
    "Matrix3D.?127",  // no name anywhere for hash 0x6512b8f5
    "Matrix3D.?128",  // no name anywhere for hash 0x2b45b8f5
    "Vector3D.squareLength",
    "Vector3D.length",
    "Vector3D.normalise",
    "Vector3D.sum",
    "Vector3D.minus",
    "Vector3D.dot",
    "Vector3D.crossProduct",
    "Vector3D.?136",  // no name anywhere for hash 0x305a2351
    "RayCast.draw",
    "RayCast.isThereAWall",
    "RayCast.addMonster_internal",
    "RayCast.findFirstSpriteFreeID",
    "RayCast.removeSprite",
    "RayCast.moveSprite",
    "RayCast.setSpritePos",
    "RayCast.setSpriteSize",
    "RayCast.changeInternalValues_internal",
    "RayCast.castRay",
    "Debug.DisplayText",
    "Debug.WaitForKey",
    "Debug.DisplayMemoryBlocks",
    "Debug.printInt",  // hash 0x305aa2f2, idx 150 (sub_429FC2)
    "Object.hashCode",
    "Object.equals",
    "Object.?153",  // no name anywhere for hash 0xd5710643
    "Object.?154",  // no name anywhere for hash 0xdf3ed63a
    "Class.?155",  // no name anywhere for hash 0x70063066
    "Class.?156",  // no name anywhere for hash 0xd5710176
    "Class.?157",  // no name anywhere for hash 0xb2babd25
    "String.toCharArray",
    "String.getBytes",
    "String.equals",
    "String.append",
    "String.?162",  // no name anywhere for hash 0xf33e22cb
    "String.?163",  // no name anywhere for hash 0x35b022cb
    "String.?164",  // no name anywhere for hash 0x6f6c22cb
    "String.?165",  // no name anywhere for hash 0xd045a46b
    "StringBuffer.initStringBuffer",
    "StringBuffer.length",  // idx 167 sub_42B17D: *a1 = *(u16*)(this[+24])
    "StringBuffer.?168",  // no name anywhere for hash 0xd7242d63
    "StringBuffer.?169",  // no name anywhere for hash 0x5afc22cb
    "StringBuffer.?170",  // no name anywhere for hash 0x314322cb
    "StringBuffer.?171",  // no name anywhere for hash 0x984422cb
    "StringBuffer.?172",  // no name anywhere for hash 0x501322cb
    "StringBuffer.?173",  // no name anywhere for hash 0x0ff222cb
    "StringBuffer.append",  // hash 0xb2ba3939 unnamed in StringBuffer, found as String.append
    "Runtime.?175",  // no name anywhere for hash 0x3f528978
    "Runtime.?176",  // no name anywhere for hash 0x229b6695
    "Runtime.?177",  // no name anywhere for hash 0xd724a13d
    "Catalog.doesGameExist",
    "Catalog.launchGameIfPresent",
    "Catalog.isUserRegistred",
    "Catalog.downloadGame",
    "Catalog.doEditBox",
    "Catalog.atoi",
    "GameProperty.?184",  // no name anywhere for hash 0x3f52bcb7
};


pub fn nativeName(idx: u32) []const u8 {
    if (idx < native_names.len) return native_names[idx];
    return "?";
}

/// `funcs_407AA2[N]` → canonical `sub_*` address in `reference/ref`.
/// This is the AUTHORITATIVE identifier for what a native invocation
/// actually runs: read the matching `sub_*` body in ref to see
/// the canonical implementation. Unlike `native_names[]` (which comes
/// from positional name-pairing and can drift), the sub address is the
/// real ABI of the runtime. Regenerated by `tools/extract_table.zig`.
pub const native_sub_names: [185][]const u8 = .{
    "sub_425C73",
    "sub_425699",
    "sub_4257A1",
    "sub_42585A",
    "sub_425940",
    "sub_425A50",
    "sub_425BA4",
    "sub_425D20",
    "sub_425DD8",
    "sub_425F6E",
    "sub_426015",
    "sub_426096",
    "sub_426172",
    "sub_426184",
    "sub_426196",
    "sub_426235",
    "sub_426302",
    "sub_426357",
    "sub_426419",
    "sub_4264A3",
    "sub_4264ED",
    "sub_426548",
    "sub_426210",
    "sub_426222",
    "sub_4267F6",
    "sub_426589",
    "sub_4265CA",
    "sub_42664C",
    "sub_4266A1",
    "sub_426732",
    "sub_428AA0",
    "sub_428B4E",
    "sub_428BE5",
    "sub_428C79",
    "sub_428D0D",
    "sub_428DA2",
    "sub_428E41",
    "sub_42908E",
    "sub_429177",
    "sub_429265",
    "sub_4295DF",
    "sub_4297FA",
    "sub_429813",
    "sub_42469C",
    "sub_4245FE",
    "sub_42467B",
    "sub_427013",
    "sub_42712F",
    "sub_427531",
    "sub_426FA8",
    "sub_426F37",
    "sub_427F95",
    "sub_4280BD",
    "sub_428208",
    "sub_4248B0",
    "sub_4248C2",
    "sub_4248CA",
    "sub_4248D2",
    "sub_4248DA",
    "sub_4248EC",
    "sub_4248FE",
    "sub_424906",
    "sub_42490E",
    "sub_424916",
    "sub_42492A",
    "sub_424A60",
    "sub_424A9D",
    "sub_424F70",
    "sub_424F86",
    "sub_424FAC",
    "sub_424F99",
    "sub_424FBF",
    "sub_424FF2",
    "sub_424FD2",
    "sub_42506C",
    "sub_425090",
    "sub_4250A3",
    "sub_4250BA",
    "sub_4250C7",
    "sub_425156",
    "sub_4251D4",
    "sub_4253BC",
    "sub_425252",
    "sub_4252DF",
    "sub_4252EC",
    "sub_425372",
    "sub_4253E3",
    "sub_425427",
    "sub_42563E",
    "sub_429A18",
    "sub_4298C8",
    "sub_42993B",
    "sub_429A20",
    "sub_429AC0",
    "sub_429B0A",
    "sub_429B8D",
    "sub_429C43",
    "sub_429CB0",
    "sub_429D2A",
    "sub_429D86",
    "sub_429E0A",
    "sub_424940",
    "sub_42497C",
    "sub_424B70",
    "sub_424BFD",
    "sub_424C84",
    "sub_424D62",
    "sub_424E40",
    "sub_424ED2",
    "sub_426870",
    "sub_426990",
    "sub_4269AC",
    "sub_4269C8",
    "sub_4269EB",
    "sub_426A01",
    "sub_426A14",
    "sub_426A30",
    "sub_426A4C",
    "sub_426A68",
    "sub_426A84",
    "sub_426AB4",
    "sub_426ACA",
    "sub_426ADD",
    "sub_426B20",
    "sub_426B89",
    "sub_426BE3",
    "sub_426C3D",
    "sub_426C97",
    "sub_426D7B",
    "sub_42A020",
    "sub_42A074",
    "sub_42A0C8",
    "sub_42A132",
    "sub_42A1AD",
    "sub_42A228",
    "sub_42A28A",
    "sub_42A305",
    "sub_4284C9",
    "sub_428683",
    "sub_4286C9",
    "sub_428716",
    "sub_42874B",
    "sub_42877A",
    "sub_4287BE",
    "sub_4288D3",
    "sub_428910",
    "sub_428962",
    "sub_429F40",
    "sub_429FB2",
    "sub_429FBA",
    "sub_429FC2",
    "sub_42A660",
    "sub_42A6CC",
    "sub_42A718",
    "sub_42A6DF",
    "sub_42A3BE",
    "sub_42A360",
    "sub_42A3DA",
    "sub_42AC79",
    "sub_42A7B0",
    "sub_42A99F",
    "sub_42A85E",
    "sub_42AA54",
    "sub_42AAFC",
    "sub_42AB8C",
    "sub_42ACB6",
    "sub_42AEEF",
    "sub_42B17D",
    "sub_42AE20",
    "sub_42B056",
    "sub_42B0F2",
    "sub_42B19F",
    "sub_42B1ED",
    "sub_42B244",
    "sub_42AE4E",
    "sub_42B2A0",
    "sub_42B2AD",
    "sub_42B338",
    "sub_4240A0",
    "sub_4240E1",
    "sub_424178",
    "sub_424194",
    "sub_4242B2",
    "sub_424375",
    "sub_4243C0",
};

pub fn nativeSubName(idx: u32) []const u8 {
    if (idx < native_sub_names.len) return native_sub_names[idx];
    return "?";
}

/// Build a structural label for a (class_hash, method_hash) pair.
/// Unlike `methodName` (which guesses via positional name-pairing and
/// often gets it wrong), this returns only what's STRUCTURALLY derivable
/// from the method's row in its class's method_table. Never guesses
/// a name; callers can resolve to a human name via
/// `docs/extracted/<class>.md` if they really want.
///
/// Returns the buffer slice. Caller provides at least 64 bytes.
pub fn methodLabel(class_hash: u32, method_hash: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>8}#hash=0x{x:0>8}", .{ class_hash, method_hash }) catch "?";
}
