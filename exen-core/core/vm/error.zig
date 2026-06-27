//! VM error set shared by every module in `core/vm/`. Kept in its own
//! file so leaf modules (Frame, Heap) can import it without dragging
//! the rest of the interpreter into their dependency graph.

pub const Error = error{
    StackUnderflow,
    StackOverflow,
    UnknownOpcode,
    UnknownNative,
    MethodNotFound,
    NullPointer,
    OutOfMemory,
};
