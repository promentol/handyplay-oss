# ExEn exception handling — canonical spec + our gap

Reverse-engineered 2026-07-03 from `emulator.c` (packages/exen-player/emulator/).
Blueprint for adding catchable try/catch to the Zig VM. Line numbers refer
to that file.

## Two-tier model

- **Tier A — catchable Java exceptions.** Set a pending class-hash into
  `ctx+28` (`sub_410198` just stores it), then `sub_409580()` materializes
  the exception object and runs the handler search `sub_409651`. Covers
  explicit `athrow` AND all VM-internal faults (NPE, array-bounds, div-by-
  zero, etc.) — all catchable because the search walks per-method exception
  tables.
- **Tier B — non-catchable fatal.** Call `sub_407A13()` directly: logs
  "Internal exception occured", sets host run-state = 2 (tick aborts, next
  WM_TIMER tick resumes clean). Used ONLY for VM invariant violations
  (missing framework methods at startup, native-frame setup failure) — and
  as the terminal fall-through when a Tier-A throw finds no handler in any
  frame.

`dword_51F900` = VM context (`+28` = pending-exception class-hash, 0 = none;
`+46` = exception-state flags). `dword_51F904` = current frame. Frame header
(36 bytes): +0 caller link, +8 method record, +12 class/code base, +16 SP
(grows +4 from frame+36), +20 locals base, +30 (u16) PC, +34 depth.

## Exception table (the thing we don't parse)

Per bytecode method:
- method record `+8` (u16) → **Code-attribute** offset (relative to class-data base).
- Code-attribute `+4` (u16) → **exception-table** offset (rel. class base); 0 = no table.
- Table = u16 **count**, then `count` × 8-byte entries (4 × u16):

  | off | field |
  |---|---|
  | +0 | start_pc |
  | +2 | end_pc (INCLUSIVE: `PC <= end_pc`) |
  | +4 | handler_pc |
  | +6 | catch_type — 0 = catch-all/finally; else offset (rel. class base) to a u16 class-id |

## ATHROW (0xBF → sub_408DBD, :8626)

Pop one operand. Null ref → arm NPE (hash 910855525) + `sub_409580()`.
Non-null → incref (`obj+14`) and `sub_409651(ref)`.

## Handler search + unwind — sub_409651 (:9028)

```
for (f = current_frame; f != 0; f = f.caller) {      # unwind outward
  code_attr = *(u16)(f.method+8) + f.codebase
  tbl = *(u16)(code_attr+4); if (!tbl) continue
  base = tbl + f.codebase; count = *(u16)base
  for each entry:
    if (f.PC in [start_pc, end_pc]):
      for (k = thrown; k != 0; k = k.super):          # subclass-aware match
        if (catch_type == 0 || k.classId == *(u16)(catch_type + f.codebase)):
          ctx.pending = 0; current_frame = f; f.PC = handler_pc
          push thrown ref onto f's SP; SP += 4
          return
}
return sub_407A13()   # no handler in any frame → fatal
```

Unwinding is implicit: setting `current_frame = f` restores that frame's SP
(+16) and locals (+20) as they stood at its call site. ⚠ NOT-FULLY-CONFIRMED:
on a SAME-frame catch, SP is not explicitly reset to the operand base before
the exception is pushed — strict JVM empties the stack. Verify whether the
ExEn compiler guarantees empty-stack handler entry before relying on it.

## Internal-fault catalog (Tier A, by CRC-32 of class name)

| code (dec) | class | trigger |
|---|---|---|
| 910855525 | NullPointerException | null deref / athrow-null (22 sites) |
| 490483763 | ArrayIndexOutOfBounds | index <0 or >=len |
| 1920171873 | Exception (generic) | operand not an array |
| 2264282635 | ArithmeticException | ÷0, INT_MIN/-1 |
| 127202840 | NegativeArraySize | newarray negative len |
| 324157225 | LinkageError | field/method/interface resolve fail |
| 972291671 | IllegalAccessException | static/instance mismatch on field ops |
| 4061643639 | Error | get/putfield access error variant |
| 4070070037 | ClassNotFoundException | class resolve fail |
| 4076382748 | OutOfMemoryError | alloc fail (special flag bit8) |
| 2730961905 | StackOverflowError | frame-stack ceiling on invoke |

Materialize: `sub_410067(153, hash)` → `sub_4102D4` (hash→class index; 7 boxed
primitives cached at ctx+32..+44, else linear scan) → alloc → run constructor
if the class declares one. Object carries class-id at `obj+10`, refcount at
`obj+14`.

## Our current gap (core/vm/)

We implement **Tier B only**. `opAthrow` (core/vm/opcodes/ret.zig) pops the
ref and immediately `signalFault(EX_NULL_POINTER)` — every throw is a fatal
tick-abort. We never parse the Code-attribute/exception-table (MethodInfo
reads only the 6-byte body header: max_stack, locals). No frame-chain unwind,
no catch_type matching. NPE/internal faults funnel through the same single
`internal_exception` halt tier. So a gamelet that uses try/catch to *recover*
is silently tick-aborted where canonical would resume in its handler.

## Whether the corpus needs it

Open question — no corpus gamelet has yet been shown to depend on catchable
recovery (they generally run to the fatal path only on genuine bugs). Worth a
scan: grep methods for a non-empty exception table (Code-attr+4 != 0) and see
which gamelets ship try/catch, and whether any tick-aborts we currently log
correspond to a range that has a handler. Implement only if a real gamelet
regresses without it — the machinery (table parse + unwind) is ~a day.
