//! `ClassObject` — per-class statics. Mirrors ref's runtime
//! class struct: the gamelet's `GETSTATIC`/`PUTSTATIC` opcodes index
//! into `statics[slot]` exactly like the simulator's `class_obj +
//! 4*slot + 16` arithmetic.

pub const ClassObject = struct {
    hash: u32,
    statics: [256]u32 = .{0} ** 256,
    /// Heap handle that represents `Class<this>` to gamelet code.
    /// Lazily allocated by `Object.getClass` (and any other native that
    /// needs to hand the gamelet a Class<?> reference). 0 = not yet
    /// minted. Stays stable for the VM's lifetime: every getClass call
    /// against an instance of this class returns the same handle, so
    /// `==` checks against Class objects behave the way the canonical
    /// `sub_411710` lookup does.
    class_handle: u32 = 0,
};
