//! Public API umbrella for the MRE emulator core. Frontends and tools import this
//! module (`@import("core")`) rather than reaching into individual files.
pub const memory = @import("memory.zig");
pub const Memory = memory.Memory;
pub const Manager = memory.Manager;

pub const loader = struct {
    pub const tags = @import("loader/tags.zig");
    pub const elf = @import("loader/elf.zig");
    pub const ads = @import("loader/ads.zig");
    pub const armapp = @import("loader/armapp.zig");
    pub const LoadedApp = armapp.LoadedApp;
    pub const load = armapp.load;
    pub const sniff = armapp.sniff;
};

pub const cpu = @import("cpu/unicorn.zig");
pub const bridge = @import("bridge.zig");
pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const natives = @import("natives.zig");
pub const resources = @import("resources.zig");
pub const vm = @import("vm.zig");
pub const Vm = vm.Vm;
pub const savestate = @import("savestate.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
