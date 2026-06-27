//! Phase 0 de-risk: prove the vendored Unicorn library links and executes ARM
//! code from Zig. Runs a 2-instruction blob and checks R0 == 42.
const std = @import("std");

const c = @cImport(@cInclude("unicorn/unicorn.h"));

const CODE_ADDR: u64 = 0x10000;

// ARM (not Thumb) encoding:
//   mov r0, #42   -> 0xE3A0002A
//   bx  lr        -> 0xE12FFF1E
const ARM_CODE = [_]u8{
    0x2a, 0x00, 0xa0, 0xe3, // mov r0, #42
    0x1e, 0xff, 0x2f, 0xe1, // bx lr
};

pub fn main() !void {
    var uc: ?*c.uc_engine = null;
    if (c.uc_open(c.UC_ARCH_ARM, c.UC_MODE_ARM, &uc) != c.UC_ERR_OK) {
        std.debug.print("uc_open failed\n", .{});
        return error.UcOpen;
    }
    defer _ = c.uc_close(uc);

    if (c.uc_mem_map(uc, CODE_ADDR, 0x1000, c.UC_PROT_ALL) != c.UC_ERR_OK)
        return error.UcMemMap;

    if (c.uc_mem_write(uc, CODE_ADDR, &ARM_CODE, ARM_CODE.len) != c.UC_ERR_OK)
        return error.UcMemWrite;

    // Run exactly the first instruction (mov r0, #42).
    if (c.uc_emu_start(uc, CODE_ADDR, CODE_ADDR + 4, 0, 0) != c.UC_ERR_OK)
        return error.UcEmuStart;

    var r0: u32 = 0;
    _ = c.uc_reg_read(uc, c.UC_ARM_REG_R0, &r0);

    std.debug.print("R0 = {d}\n", .{r0});
    if (r0 != 42) {
        std.debug.print("FAIL: expected R0 == 42\n", .{});
        return error.UnexpectedResult;
    }
    std.debug.print("Unicorn smoke OK (mrp-player)\n", .{});
}
