# mrp-player

A Zig emulator for sky-mobi **MRP / Mythroad** feature-phone apps — built on a
vendored Unicorn ARM core, with native SDL3 and libretro frontends. Structured
as a sibling of `mre-core`.

## How it works

MRP apps (`.mrp`) are an archive of **native ARM/Thumb code** (compiled from C) plus
resources. The platform's native ARM **"dsm" engine** (`cfunction.ext`) loads and
runs that code; we run the whole thing *inside Unicorn*. Our job is the host side:
a flat guest memory map, a free-list heap allocator, and the `mr_*` C-API **bridge**
(graphics, file, timer, input, network, sound, edit).

- **Memory** (`core/memory.zig`): one flat buffer mapped at `0x80000`
  (CODE 1 MB · STACK 1 MB · heap 6 MB), with an LG free-list allocator.
- **Bridge** (`core/vm.zig`): two pointer tables (`mr_table`,
  `dsm_require_funcs`) live in guest memory; each function slot holds its own
  address and a `UC_HOOK_CODE` over the table range traps calls, dispatches to a
  native handler (args R0–R3 / stack, result R0), then sets `PC = LR`.
- **Lifecycle**: `ext_init` → `dsm_init` (checks `DSM_VERSION`) → `mr_start_dsm` →
  `mr_timer` / `mr_event`, all funnelled through `mr_extHelper` via `runCode`.
- **Leaf modules**: `gfx.zig` (240×320 RGB565 + `drawBitmap`), `fs.zig` (host
  file layer), `net.zig` (real synchronous TCP/UDP natively; `MR_FAILED` if unavailable).

## Build & run

```sh
# native unit tests + Unicorn smoke
zig build test
zig build smoke

# headless: boot the dsm launcher (or a package), print native coverage
zig build run                          # assets/ + dsm_gm.mrp + start.mr
zig build run -- assets ydqtwo.mrp start.mr

# SDL3 window (launcher by default)
zig build run-sdl
zig build run-sdl -- assets ydqtwo.mrp start.mr

# native libretro core -> zig-out/libretro/mrp_libretro.{dylib,so,dll}
zig build libretro
```

Keys: arrows/WASD = D-pad · Enter = OK · Q/E = soft keys · 0–9 = keypad ·
`-` = `*` · `=` = `#` · Esc = quit (SDL).

## Layout

```
core/        memory, cpu/unicorn (single @cImport), vm (VM+bridge+natives), gfx, fs, net
frontends/   sdl/ (SDL3), libretro/ (retro_* C ABI)
tools/       run (headless), uc_smoke
vendor/      Unicorn (native libunicorn.a)
```

## License

Dual-licensed: **AGPL-3.0** for open-source use, or a **commercial license** for
proprietary use. See the repository root: `LICENSE` and `COMMERCIAL.md`.
