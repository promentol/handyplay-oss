//! Public umbrella module for the mrp-player core: the frontend-agnostic VM,
//! memory model, bridge, graphics, file and socket layers. Frontends and tools
//! import this module as `core`.

pub const cpu = @import("cpu/unicorn.zig");
pub const Cpu = cpu.Cpu;

pub const memory = @import("memory.zig");
pub const Memory = memory.Memory;

pub const gfx = @import("gfx.zig");
pub const fs = @import("fs.zig");
pub const net = @import("net.zig");

pub const vm = @import("vm.zig");
pub const Vm = vm.Vm;
pub const Host = vm.Host;
pub const savestate = @import("savestate.zig");
