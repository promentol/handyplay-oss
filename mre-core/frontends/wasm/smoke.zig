//! Minimal WASM toolchain smoke: run a 2-instruction ARM blob through the
//! emscripten-built Unicorn and return R0 (expect 42). Exported for JS to call.
const c = @cImport(@cInclude("unicorn/unicorn.h"));

const CODE_ADDR: u64 = 0x10000;
const ARM_CODE = [_]u8{
    0x2a, 0x00, 0xa0, 0xe3, // mov r0, #42
    0x1e, 0xff, 0x2f, 0xe1, // bx lr
};

export fn run42() i32 {
    var uc: ?*c.uc_engine = null;
    if (c.uc_open(c.UC_ARCH_ARM, c.UC_MODE_ARM, &uc) != c.UC_ERR_OK) return -1;
    defer _ = c.uc_close(uc);
    if (c.uc_mem_map(uc, CODE_ADDR, 0x1000, c.UC_PROT_ALL) != c.UC_ERR_OK) return -2;
    if (c.uc_mem_write(uc, CODE_ADDR, &ARM_CODE, ARM_CODE.len) != c.UC_ERR_OK) return -3;
    if (c.uc_emu_start(uc, CODE_ADDR, CODE_ADDR + 4, 0, 0) != c.UC_ERR_OK) return -4;
    var r0: u32 = 0;
    _ = c.uc_reg_read(uc, c.UC_ARM_REG_R0, &r0);
    return @intCast(r0);
}
