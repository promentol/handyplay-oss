//! Umbrella module: orchestrates the WinMain → dispatcher boot path on top
//! of `sdl_demo.zig`. Owns the process-wide VM singletons.
//!
//! Boot order matches sub_438C06:34760 + the WinMain prologue at sub_438D1E:34810
//! (minus Win32-specific cosmetics — see the plan for the exclusion list).

const std = @import("std");

pub const ini_mod = @import("ini.zig");
pub const vm_state = @import("vm_state.zig");
pub const exn = @import("exn/loader.zig");
pub const exn_metadata = @import("exn/metadata.zig");
pub const exn_metadata_fs = @import("exn/metadata_fs.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const handlers = @import("handlers.zig");
pub const render = @import("render.zig");
pub const gfx = @import("gfx.zig");
pub const classfile = @import("classfile/methods.zig");
pub const class_registry = @import("classfile/registry.zig");
pub const interp = @import("vm/interp.zig");
pub const obj_arena_mod = @import("vm/object_arena.zig");
pub const png = @import("codecs/png.zig");
pub const codec = @import("codecs/codec_1to5.zig");
pub const text = @import("text.zig");
pub const bridge = @import("bridge.zig");
pub const debug = @import("debug/names.zig");
pub const audio = @import("audio.zig");
pub const haptic = @import("haptic.zig");
pub const savestate = @import("savestate.zig");

const log = std.log.scoped(.exen);

// ── globals (recovered names in comments) ─────────────────────────────────
var g_alloc: std.mem.Allocator = undefined;
var g_vm: vm_state.VmState = undefined;       // dword_45FE8C
var g_vm_heap: []u8 = &.{};                   // lParam (composite heap)
var g_ini: ?*ini_mod.Ini = null;              // parsed simulator.ini
var g_flash_dir: []u8 = &.{};                 // byte_51B000
var g_server_dir: []u8 = &.{};                // Source
var g_eeprom_path: []u8 = &.{};               // FileName
var g_loaded_exn: ?exn.ExnFile = null;        // owns the .exn buffer
var g_loaded_layout: ?exn.ExnLayout = null;   // parsed section table
var g_loaded_classfile: ?classfile.ClassFile = null; // parsed method offset table

/// Thin wrapper around the pure `exn.resolveResource` that reads
/// from process-wide state. Used by the `Resource.*` natives.
pub fn resolveResource(id: u32) ?exn.ResourceSlice {
    const cf = if (g_loaded_classfile) |*c| c else return null;
    const raw = if (g_loaded_exn) |e| e.raw else return null;
    return exn.resolveResource(cf, raw, id);
}

/// Look up the simulator-style "resource type" flag byte
/// (Resource.getResourceType / sub_429813).
pub fn resourceFlag(id: u32) ?u8 {
    const cf = if (g_loaded_classfile) |*c| c else return null;
    return exn.resourceFlag(cf, id);
}

/// Total number of resources in the loaded .exn — used by
/// `Resource.getNbResources` (sub_4297FA). The .exn's method-offset
/// table doubles as the resource directory (per `exn.resolveResource`),
/// so the count equals `method_count`.
pub fn resourceCount() u32 {
    const cf = if (g_loaded_classfile) |*c| c else return 0;
    return cf.method_count;
}

/// Borrowed slice of the loaded .exn raw bytes — the host owns the
/// buffer for the lifetime of the gamelet.
pub fn loadedRawBytes() ?[]const u8 {
    if (g_loaded_exn) |e| return e.raw;
    return null;
}

var g_screen_w: u32 = 121;                    // *dword_45C7C4
var g_screen_h: u32 = 143;                    // dword_45C7C8
var g_manuf_idx: u32 = 0;                     // currently active [Manuf.NNN]
/// One-shot override consulted by the next `boot()`. The tray Device
/// submenu sets this before calling `restart` so the gamelet boots
/// with a different screen profile.
pub var manuf_override: ?u32 = null;
var g_fb: ?gfx.Framebuffer = null;            // simulated LCD pixel buffer
var g_builtins_blob: ?[]u8 = null;            // unk_4494F0.bin contents
var g_registry: ?class_registry.Registry = null;
var g_vm_interp: ?interp.Vm = null;
/// Fixed-buffer arena backing the entire interp VM (see boot step 12). Save-states
/// dump this region. `g_vm_fba` must be a global so the captured Allocator is stable.
var g_vm_arena: []u8 = &.{};
var g_vm_fba: std.heap.FixedBufferAllocator = undefined;
/// FBA region: slab + class statics only (long-lived, never freed per-object → bump is
/// fine). Owned-object memory moved to `g_obj_arena` so it can be reclaimed by the GC.
pub const vm_arena_size: usize = 16 * 1024 * 1024;

/// Object-heap region: a fixed free-list arena owning every Instance, its field map,
/// its byte/int buffers, the handle table, and the palette side-table. This is what
/// makes the VM RTOS-ready — steady-state object alloc/free never touches a general-
/// purpose host allocator, only this buffer (on RTOS: a static array). The GC frees
/// back into it (unlike the bump FBA, which never reclaimed). See object_arena.zig.
var g_obj_buf: []u8 = &.{};
var g_obj_arena: obj_arena_mod.ObjectArena = undefined;
pub const obj_arena_size: usize = 48 * 1024 * 1024;

// ── public API ────────────────────────────────────────────────────────────

/// Boot the VM. Mirrors WinMain:34810-34924 (the path that always runs, before
/// the optional cmdline .exn auto-load). After this returns successfully,
/// you may call loadExn() to plug in a gamelet.
pub fn boot(
    allocator: std.mem.Allocator,
    ini_path: []const u8,
) !void {
    g_alloc = allocator;

    // 1. simulator.ini is OPTIONAL config (device profile + heap sizing), NOT firmware.
    //    With no ini we use the default device profile (Manuf.003: 132x176, 8bpp — what
    //    the reference simulator.ini's CURRENT_COLOR=3 selects), so the only required
    //    firmware is the 4CVP builtins blob loaded below. Pass an ini to override.
    const ini: ?*ini_mod.Ini = ini_mod.Ini.loadFromFile(allocator, ini_path) catch null;
    g_ini = ini;
    if (ini) |i| log.info("loaded {s}: {d} sections", .{ ini_path, i.sectionCount() }) else log.info("no simulator.ini — default device 132x176", .{});

    // 2. Resolve flash + server directories.
    g_flash_dir = try sanitizePath(allocator, if (ini) |i| (i.get("Path", "FLASH_PATH") orelse "flash/") else "flash/");
    g_server_dir = try sanitizePath(allocator, if (ini) |i| (i.get("Path", "SERVER_PATH") orelse "server/") else "server/");
    try ensureDir(g_flash_dir);
    try ensureDir(g_server_dir);
    log.info("flash={s} server={s}", .{ g_flash_dir, g_server_dir });

    // 3. eeprom.dat — create an empty one if absent (boot doesn't read it).
    g_eeprom_path = try std.fs.path.join(allocator, &.{ g_flash_dir, "eeprom.dat" });
    try ensureEepromExists(g_eeprom_path);

    // 4. Display profile. Default Manuf.003 (132x176, 8bpp); `manuf_override` or the ini
    //    can switch it. Change the defaults here to target a different screen.
    const manuf_idx: u32 = manuf_override orelse (if (ini) |i| @intCast(@max(0, i.getInt("Manuf.current", "CURRENT_COLOR", 3))) else 3);
    g_manuf_idx = manuf_idx;
    var section_buf: [16]u8 = undefined;
    const manuf_section = try std.fmt.bufPrint(&section_buf, "Manuf.{d:0>3}", .{manuf_idx});
    g_screen_w = if (ini) |i| i.getU32(manuf_section, "EXEN_DISPLAY_WIDTH", 132) else 132;
    g_screen_h = if (ini) |i| i.getU32(manuf_section, "EXEN_DISPLAY_HEIGHT", 176) else 176;
    const depth = if (ini) |i| i.getU32(manuf_section, "EXEN_DISPLAY_DEPTH", 8) else 8;
    log.info("device [{s}] {d}x{d} depth={d}", .{ manuf_section, g_screen_w, g_screen_h, depth });

    // 6. VM state init.
    g_vm.initBlank();
    log.info("vm_state initialized ({d} bytes, FUSIO/XCELL identity)", .{g_vm.bytes.len});

    // 7. Composite VM heap size (Manuf.003 defaults).
    const vm_size_small = if (ini) |i| i.getU32(manuf_section, "EXEN_VM_SIZE_SMALL", 46080) else 46080;
    const vm_size_big = if (ini) |i| i.getU32(manuf_section, "EXEN_VM_SIZE_BIG", 59392) else 59392;
    const core_size = if (ini) |i| i.getU32(manuf_section, "EXEN_CORE_MEMORY_SIZE", 32768) else 32768;
    const extra_enabled = if (ini) |i| (i.getInt("Extra Memory", "EXTRA_MEMORY", 0) != 0) else false;
    const extra: u32 = if (extra_enabled) 102_400 else 0;
    const vm_heap_size: usize = vm_size_small + vm_size_big + core_size + extra;
    g_vm_heap = try allocator.alignedAlloc(u8, .of(u32), vm_heap_size);
    @memset(g_vm_heap, 0);

    // 8. Register the six known opcode-group handlers.
    handlers.registerAll();
    log.info("dispatch table populated (groups 1..6)", .{});

    // 9. First dispatch through the real pipeline — sub_438C06:34799:
    //    sub_436E00(1536, vm_heap_size, vm_heap_ptr).
    //    Routes through invoke → publish → dispatch → handlers.group6.
    const ptr_as_u32: u32 = @truncate(@intFromPtr(g_vm_heap.ptr));
    log.info("==> first dispatch: opcode 0x0600 (VM_INIT) heap_size={d}", .{vm_heap_size});
    const rv = dispatcher.invoke(1536, @intCast(vm_heap_size), ptr_as_u32);
    log.info("==> first dispatch returned {d}", .{rv});

    // 10. Allocate the simulated LCD framebuffer. All on-screen drawing
    //     goes through `gfx.*` primitives writing into this buffer.
    //     The VM's `exen.Graphics.*` natives target this buffer.
    g_fb = try gfx.Framebuffer.init(allocator, g_screen_w, g_screen_h);
    log.info("framebuffer allocated: {d}x{d} ABGR8888", .{ g_screen_w, g_screen_h });

    // 11. Load the built-in 4CVP class definitions (~50 classes including
    //     vm.sys.Bootstrap, exen.Graphics, etc.) extracted from
    //     the reference simulator's .rdata section.
    const builtins_blob = std.fs.cwd().readFileAlloc(allocator, "assets/unk_4494F0.bin", 1 << 20) catch |err| {
        log.warn("unk_4494F0.bin not loaded: {s} — VM will be inert", .{@errorName(err)});
        return;
    };
    g_builtins_blob = builtins_blob;

    var registry = class_registry.Registry.init(allocator);
    const builtin_n = try registry.scanBuffer(builtins_blob, 0, .builtin);
    log.info("class registry: {d} built-in classes loaded", .{builtin_n});
    g_registry = registry;

    // 12. Initialize the bytecode VM with a generous slab. Crash's
    //     menu-navigation chain (predicate → next-sibling → predicate
    //     recursion within the same FIRE handler) deepens past 16K
    //     u32 frames; 64K gives breathing room until we can measure
    //     a realistic upper bound.
    // Slab = operand-stack + locals for all active frames. Per-frame:
    // locals + max_stack + 8 words. Terminator's score/UI bytecode has
    // a ~200-deep recursion (method 0x9118b171 on 0x2eb36ef0) that
    // walks the score table; with 64K words we'd overflow on long
    // runs. 256K gives ~24K frame depth, comfortable headroom.
    // Two fixed buffers the whole interp VM allocates from (no general-purpose host
    // malloc in steady state — the RTOS-ready property):
    //   • FBA (bump): the operand slab + class statics. Long-lived, never freed per
    //     object, so a bump allocator is the right tool. Flat-dumped by the save-state.
    //   • Object arena (free-list): every Instance, its field map, owned byte/int
    //     buffers, the handle table, and the palette side-table. The GC frees back
    //     into it (a bump arena couldn't, which is why the heap grew unboundedly).
    // Both globals are module-level so the Allocators the VM's maps capture (which hold
    // `&g_vm_fba` / `&g_obj_arena`) stay valid after `Vm.init`'s by-value return.
    g_vm_arena = try allocator.alloc(u8, vm_arena_size);
    g_vm_fba = std.heap.FixedBufferAllocator.init(g_vm_arena);
    g_obj_buf = try allocator.alignedAlloc(u8, .@"16", obj_arena_size);
    g_obj_arena = obj_arena_mod.ObjectArena.init(g_obj_buf);
    // FBA → slab + class statics (flat-dumped); object arena → the GC'd object heap
    // (serialized separately as a table in the save-state).
    g_vm_interp = try interp.Vm.init(g_vm_fba.allocator(), g_obj_arena.allocator(), &g_registry.?, 256 * 1024);
    // The heap frees owned buffers only when they live inside the object arena (a few
    // borrowed slices — e.g. cached image pixels — point elsewhere and must be skipped).
    g_vm_interp.?.heap.arena_lo = @intFromPtr(g_obj_arena.base);
    g_vm_interp.?.heap.arena_hi = @intFromPtr(g_obj_arena.base) + g_obj_arena.len;
    if (g_fb) |*fb| g_vm_interp.?.framebuffer = fb;

    // 13. Native font atlas — the 5×8 1bpp glyphs baked into
    //     the reference simulator at `unk_454DD0` (extracted to core/assets/font_5x8.bin).
    //     Matches sub_413A40(&unk_454DD0, 0x500, 8, 5, 9, 0x100) at
    //     ref:5699. No external font file required.
    text.init(allocator, "", 0) catch |err| {
        log.warn("font init failed: {s} — text won't render", .{@errorName(err)});
    };
}

/// Inject the host's native-method dispatcher. Frontends call this
/// AFTER `boot()` and BEFORE any gamelet bytecode runs, passing in
/// `natives.dispatch` (or a custom dispatcher for headless/test builds).
/// Without this the VM uses `interp.defaultNativeStub` directly — which
/// is fine for the current monolithic switch but won't pick up future
/// per-class implementations under `natives/`.
pub fn setNativeDispatcher(f: interp.NativeFn) void {
    if (g_vm_interp) |*vm| vm.native_fn = f;
}

/// Load a .exn gamelet (sub_43D57A:36969 + sub_43D350:36922 minus persistence).
pub fn loadExn(path: []const u8) !void {
    if (g_loaded_layout) |*old| {
        old.deinit();
        g_loaded_layout = null;
    }
    if (g_loaded_classfile) |*old| {
        old.deinit();
        g_loaded_classfile = null;
    }
    if (g_loaded_exn) |*old| {
        old.deinit();
        g_loaded_exn = null;
    }
    var loaded = exn.load(g_alloc, path) catch |err| {
        log.warn("loadExn({s}) failed: {s}", .{ path, @errorName(err) });
        return err;
    };
    errdefer loaded.deinit();

    log.info("loaded {s} ({d} bytes) magic=NEXE name={s}", .{
        path, loaded.raw.len, loaded.name,
    });

    // Register the gamelet's classes from its tail region into the
    // class registry. Tail starts at the sentinel of the offset
    // table (entry[N] at file +0x38+4N).
    if (g_registry) |*reg| {
        const method_count = std.mem.readInt(u32, loaded.raw[0x34..][0..4], .little);
        const sentinel_file_off = 0x38 + 4 * method_count;
        if (sentinel_file_off + 4 <= loaded.raw.len) {
            const tail_start = std.mem.readInt(u32, loaded.raw[sentinel_file_off..][0..4], .little);
            const n_added = reg.scanBuffer(loaded.raw, tail_start, .gamelet) catch |err| {
                log.warn("gamelet class scan failed: {s}", .{@errorName(err)});
                return;
            };
            log.info("registered {d} gamelet classes from {s}", .{ n_added, path });
        }
    }

    // Parse the class file's method offset table — the simulator
    // uses this same table as its "resource table" (sub_428AA0
    // @ ref:27322 indexes into it via Resource.init). Must
    // happen BEFORE bootstrapGamelet because Bootstrap.init invokes
    // Resource natives during its run.
    g_loaded_classfile = classfile.parse(g_alloc, loaded.raw) catch |err| blk: {
        log.warn("classfile.parse failed: {s} — Resource natives will return null", .{@errorName(err)});
        break :blk null;
    };
    if (g_loaded_classfile) |cf| {
        log.info("classfile: {d} methods/resources", .{cf.method_count});
    }
    // Hand the raw .exn bytes to the VM so Resource.read* natives
    // can dereference into them. Also publish `loaded` to the global
    // BEFORE bootstrap — class <clinit>s that fire during the boot
    // (e.g. exen.Resource's static initializer in download1.exn)
    // call Resource.init / readBytes which need a non-null
    // `g_loaded_exn`. We hold onto `loaded` ownership via the
    // alias for the rest of the function and clear errdefer so an
    // error after this point doesn't double-free.
    if (g_vm_interp != null) g_vm_interp.?.exn_raw = loaded.raw;
    g_loaded_exn = loaded;

    // Bootstrap: allocate a gamelet instance and stash it in
    // vm.sys.Bootstrap.statics[0]. Port of `sub_4069BA` simplified.
    // The .exn header has the FULL "<id>.<class>" string starting at
    // byte 0x14 (terminated by NUL). The CRC-32 of that full string
    // is what the gamelet's class records are hashed under.
    if (g_vm_interp != null) {
        var name_end: usize = 0x14;
        while (name_end < loaded.raw.len and loaded.raw[name_end] != 0 and (name_end - 0x14) < 33) : (name_end += 1) {}
        const full_name = loaded.raw[0x14..name_end];
        bootstrapGamelet(full_name) catch |err| {
            log.warn("bootstrap failed: {s}", .{@errorName(err)});
        };
    }

    var layout = exn.parseLayout(g_alloc, loaded.raw) catch |err| {
        log.warn("parseLayout failed: {s} (non-fatal — VM uses classfile parser directly)", .{@errorName(err)});
        return;
    };
    errdefer layout.deinit();
    log.info("layout: tag04=0x{x:0>2} tiers=({d},{d}),({d},{d}),({d},{d}) sections={d}", .{
        layout.tag_04,
        layout.tiers[0].blocks, layout.tiers[0].size,
        layout.tiers[1].blocks, layout.tiers[1].size,
        layout.tiers[2].blocks, layout.tiers[2].size,
        layout.sections.len,
    });
    var n_img: u32 = 0;
    var n_sub: u32 = 0;
    var n_text: u32 = 0;
    var n_opa: u32 = 0;
    for (layout.sections) |s| {
        switch (s.kind) {
            .image => n_img += 1,
            .subtable => n_sub += 1,
            .text => n_text += 1,
            .opaque_data => n_opa += 1,
        }
    }

    log.info("section kinds: image={d} subtable={d} text={d} opaque={d}", .{
        n_img, n_sub, n_text, n_opa,
    });

    const default_file_id = if (g_ini) |ini|
        ini.getU32("SmsServerConfig", "DefaultFileID", 128)
    else
        128;
    try exn.appendGamelet(&g_vm, &loaded, default_file_id);
    log.info("gamelet appended; method_count={d}", .{g_vm.methodCount()});

    g_loaded_layout = layout;
}

/// Allocate a gamelet instance and register it in
/// vm.sys.Bootstrap.statics[0]. Bootstrap shortcut: the simulator
/// would normally run vm.sys.Bootstrap.init() bytecode which does
/// this via NEW + PUTSTATIC, but those opcodes aren't yet
/// implemented. Host-side stand-in: directly allocate + assign.
fn bootstrapGamelet(gamelet_name: []const u8) !void {
    // Compute the gamelet's main class hash. The simulator's
    // sub_4069BA loader allocates the class under vm.sys.Bootstrap's
    // hash (0x6551F7DC) regardless of the gamelet's actual name,
    // but virtual dispatch needs the gamelet's REAL class hash so
    // method lookup can find the gamelet's overrides.
    //
    // The .exn header stores `<gameletId>.<className>` (e.g.
    // "PartEngine" for download1.exn or "TheTerminator.GameTopLevel").
    // For names without a '.', the gamelet's main class IS the
    // gameletId itself; CRC-32 of that string is the class hash.

    var hash_input_buf: [256]u8 = undefined;
    const hash_input: []const u8 = if (std.mem.indexOfScalar(u8, gamelet_name, '.') == null) blk: {
        // The .exn's name was truncated at '.' or '\0' by the loader,
        // so we need to reconstruct the full "<id>.<class>" form for
        // the hash. For download1.exn the full form is "PartEngine"
        // (Class 8 of its tail). For others it's <id>.<className>.
        break :blk gamelet_name;
    } else hash_input: {
        @memcpy(hash_input_buf[0..gamelet_name.len], gamelet_name);
        break :hash_input hash_input_buf[0..gamelet_name.len];
    };

    const class_hash = std.hash.Crc32.hash(hash_input);
    log.info("bootstrap: gamelet main class \"{s}\" → CRC-32 = 0x{x:0>8}", .{ hash_input, class_hash });

    // Verify the class is actually registered.
    if (g_registry.?.lookup(class_hash) == null) {
        log.warn("  gamelet class 0x{x:0>8} not in registry — bootstrap aborted", .{class_hash});
        return;
    }

    // CRITICAL: take a stable pointer to the VM. `g_vm_interp.?` in
    // separate expressions might or might not address the same Vm
    // depending on Zig's lvalue resolution; one pointer guarantees
    // all mutations land in the same struct.
    const vm = &g_vm_interp.?;

    // Allocate the instance.
    const handle = try vm.heap.alloc(class_hash);
    interp.Vm.bootstrap_gamelet_handle = handle;
    log.info("  allocated gamelet instance: handle=0x{x:0>8} class=0x{x:0>8}", .{ handle, class_hash });

    // Set vm.sys.Bootstrap.statics[0] = handle.
    const bs_obj = try vm.ensureClassObject(class_registry.CLASS_VM_SYS_BOOTSTRAP);
    bs_obj.statics[0] = handle;
    log.info("  vm.sys.Bootstrap.statics[0] = 0x{x:0>8}", .{handle});

    // Also seed the gamelet's own class.statics[0] with the instance
    // handle — TheTerminator and similar gamelets call a static
    // getInstance()-style helper that returns class.statics[0],
    // expecting the host to wire the singleton before any tick runs.
    // Without this, the first GETSTATIC during paint returns 0 and
    // INVOKEVIRTUAL on the singleton crashes.
    //
    // CRITICAL: only write if the gamelet's `<clinit>` (which runs
    // inside ensureClassObject the first time we touch the class
    // object) didn't already populate slot 0 itself. Pikubi's clinit
    // stores `getScreenWidth()` (= 132) into slot 0; an unconditional
    // overwrite to the instance handle (= 1) collapses every later
    // `fillRect(0, 0, SCREEN_WIDTH, ...)` to a 1-pixel column, leaving
    // old frames ghosting around the new draw region.
    const gamelet_obj = try vm.ensureClassObject(class_hash);
    if (gamelet_obj.statics[0] == 0) {
        gamelet_obj.statics[0] = handle;
        log.info("  gamelet.statics[0] = 0x{x:0>8}", .{handle});
    } else {
        log.info("  gamelet.statics[0] left as 0x{x:0>8} (clinit already set it)", .{gamelet_obj.statics[0]});
    }

    // Run the gamelet's own <init> constructor (method hash 0x3F52EF2F)
    // which exercises ALOAD_0 + INVOKESPECIAL + RETURN. This is what the
    // sub_4069BA loader would do via vm.sys.Bootstrap.init() bytecode
    // (which we haven't traced yet — it uses NEW + PUTSTATIC, neither
    // implemented).
    //
    // To invoke a constructor we need to push `this` onto the stack
    // first, then dispatch. Since invokeStatic doesn't push args, we
    // use a fake frame to set things up.
    log.info("  invoking gamelet <init>...", .{});
    const init_hash: u32 = 0x3F52EF2F;
    const ctor_mi = g_registry.?.findMethod(class_hash, init_hash) orelse {
        log.warn("    <init> not found", .{});
        return;
    };

    // Pass `this` (the freshly allocated instance handle) as the
    // single argument to the constructor.
    vm.halted = false;
    const args = [_]u32{handle};
    vm.invokeMethodInfo(ctor_mi, null, &args) catch |err| {
        log.warn("    <init> invoke failed: {s}", .{@errorName(err)});
    };
    log.info("    <init> halt: {any}", .{vm.halt_reason});

    // After construction, invoke vm.sys.Bootstrap.init(gamelet) —
    // hash 0x35b0f11e (METHOD_INIT).
    if (g_registry.?.findMethod(
        class_registry.CLASS_VM_SYS_BOOTSTRAP,
        class_registry.METHOD_INIT,
    )) |init_mi| {
        log.info("  invoking vm.sys.Bootstrap.init(0x{x:0>8})...", .{handle});
        vm.halted = false;
        vm.invokeMethodInfo(init_mi, null, &args) catch |err| {
            log.warn("    Bootstrap.init invoke failed: {s}", .{@errorName(err)});
        };
        log.info("    Bootstrap.init halt: {any}", .{vm.halt_reason});
    } else {
        log.warn("  vm.sys.Bootstrap.init (hash 0x{x:0>8}) not found", .{class_registry.METHOD_INIT});
    }


    // PartEngine-specific test scaffolding — only run for gamelets
    // whose main class is `PartEngine.Engine` (hash 0xB912A714).
    // TheTerminator and other non-PartEngine gamelets follow the
    // normal lifecycle (init → tick → keypress/keyrelease) driven
    // from the host's frame loop.
    if (class_hash == 0xB912A714) {
        const introdemo_hash: u32 = 0x43C20497;
        const part_handle = vm.heap.alloc(introdemo_hash) catch |err| {
            log.warn("  Part alloc failed: {s}", .{@errorName(err)});
            return;
        };
        const pe_obj = try vm.ensureClassObject(class_hash);
        pe_obj.statics[7] = part_handle;
        log.info("  PartEngine.statics[7] = 0x{x:0>8} (IntroDemo instance)", .{part_handle});

        interp.Vm.trace = true;
        const methods = [_]struct { hash: u32, name: []const u8 }{
            .{ .hash = 0x3F5273C7, .name = "partInit" },
            .{ .hash = 0x3F524413, .name = "partPaint" },
            .{ .hash = 0xD724477D, .name = "partUpdate" },
        };
        for (methods) |m| {
            log.info("  invoking {s}...", .{m.name});
            if (g_registry.?.findMethod(class_hash, m.hash)) |mi| {
                vm.halted = false;
                vm.invokeMethodInfo(mi, null, &args) catch |err| {
                    log.warn("    {s} failed: {s}", .{ m.name, @errorName(err) });
                };
                log.info("    {s} halt: {any}", .{ m.name, vm.halt_reason });
            } else {
                log.warn("    {s} not found", .{m.name});
            }
        }
        interp.Vm.trace = false;
    }
}

/// Per-frame driver. Mirrors sub_438840:34637 minus the cosmetic float
/// animations. Invokes `vm.sys.Bootstrap.tick` (slot +1208 / hash
/// 0x3F522033) — the bytecode for that method dispatches into the
/// gamelet's per-tick logic. Traps cleanly on the first unimplemented
/// opcode; logs reason for diagnostic.
var g_tick_count: u32 = 0;

/// Event-flag byte-array field hash, found via TheTerminator's spin-
/// loop trace: methods `fa368ada` / `fa36e765` test bits of
/// `this.field[0xa6f11127][idx]`. The simulator's WM_TIMER handler
/// (sub_438840) writes a timer-fire flag here every period_ms; on
/// keypress the dispatcher (sub_402F10) writes a different bit.
const EVENT_FIELD_HASH: u32 = 0xa6f11127;

/// ExEn key codes — phone-keypad convention. Most ExEn gamelets read
/// the key code as an ASCII numeric digit because the original
/// 2003-era phones had a 3×4 numeric keypad arranged so that:
///     1 2 3        ↖ ↑ ↗
///     4 5 6   ⇔    ← • →
///     7 8 9        ↙ ↓ ↘
///     * 0 #
/// '2'/'4'/'6'/'8' map naturally to UP/LEFT/RIGHT/DOWN, '5' to
/// CENTER/SELECT/FIRE. Soft keys vary by gamelet — '*' and '#' are
/// also common alternatives. Anything that doesn't fit gets the raw
/// ASCII value passed through.
pub const KEY_UP: i32 = '2';
pub const KEY_DOWN: i32 = '8';
pub const KEY_LEFT: i32 = '4';
pub const KEY_RIGHT: i32 = '6';
// FIRE/SELECT/OK is -8 per the canonical `sub_4375F0` (VK_RETURN→-8).
// Distinct from numeric '5' (which is 53) — phone keypads have a
// dedicated center-select button separate from the digit 5.
pub const KEY_FIRE: i32 = -8;
pub const KEY_SOFT1: i32 = '*';
pub const KEY_SOFT2: i32 = '#';

/// Per-tick pending keypress / release. Cleared after each tick()
/// fire (so a single SDL key event maps to exactly one gamelet
/// dispatch even if multiple SDL frames elapse before tick fires).
pub var g_keypress_pending: bool = false;
pub var g_keyrelease_pending: bool = false;
pub var g_key_code: i32 = 0;

/// Period (ms) the gamelet requested via `exen.Gamelet.startTimer`.
/// The host loop uses this to throttle `tick()` so animations play
/// at the original phone-era cadence (typically ~150ms for ExEn 2
/// games) instead of the 60Hz host frame rate.
pub var g_timer_period_ms: u32 = 0;

/// Reads the VM's exit-requested flag. The frontend polls this between
/// ticks to honour `Gamelet.exitVm()` (idx 73) which mirrors canonical
/// sub_424FD2's `*(dword_45FF3C+36) = 1` flag-set.
pub fn vmExitRequested() bool {
    if (g_vm_interp == null) return false;
    return g_vm_interp.?.exit_requested;
}

/// Hard ceiling on the per-tick period. Gamelets asking for slower
/// ticks get clamped to this; faster ones run at their requested
/// rate. With Crash/Terminator's typical 150 ms request and this set
/// to 75 ms, gameplay runs **2× faster than original phone speed**
/// (canonical ExEn devices ran ~7 Hz; we run ~13 Hz). Bumping this
/// up makes the game closer to canonical speed; bumping down makes
/// it faster (50 ms = 3×, 38 ms = 4×, etc.). The SDL frontend's
/// main-loop AND the audio backend's tempo scaler both read this so
/// they stay locked together.
pub const TICK_PERIOD_CEIL_MS: u32 = 75;

fn deliverEventFlags(vm: *interp.Vm) void {
    // Edge-triggered flag delivery on byte[0] of the event array:
    //   bit 0x80 = timer fire   (set every tick — animation pulse)
    //   bit 0x04 = keypress     (set ONE tick only, per press)
    // The byte[1] slot stores the most recent key code so the
    // gamelet's keypress handler can read which key was pressed
    // when it polls the array.
    //
    // Both bits get cleared at the start of each tick before being
    // re-set; without that, "wait until flag toggles" loops never
    // make further progress and key events stick to the gamelet's
    // last-seen value.
    //
    // CRITICAL: this MUST scope to the gamelet's main instance only.
    // `EVENT_FIELD_HASH` is `CRC32("flags")` — every gamelet class
    // that declares an unrelated field also called "flags" shares
    // the same hash. TheTerminator's menu class stores its own menu-
    // state flag bits under hash 0xa6f11127; iterating all instances
    // would also write the timer/keypress bits into the menu's flag
    // array (turning byte[1] into the FIRE key code 0xf8 = i8(-8)
    // truncated), making FIRE on "Jeu" trigger the wrong branch.
    // Restrict to `Bootstrap.statics[0]` — the canonical event-source
    // pointer, same one `dispatchKeyLifecycle` uses.
    const bs = vm.class_objects.get(class_registry.CLASS_VM_SYS_BOOTSTRAP) orelse return;
    const gamelet_handle = bs.statics[0];
    if (gamelet_handle == 0) return;
    const inst = vm.heap.get(gamelet_handle) orelse return;
    const arr_handle = inst.field_map.get(EVENT_FIELD_HASH) orelse return;
    if (arr_handle == 0) return;
    const arr = vm.heap.get(arr_handle) orelse return;
    const clear_mask: u8 = ~@as(u8, 0x80 | 0x04);
    if (arr.bytes) |b| {
        if (b.len > 0) {
            b[0] = (b[0] & clear_mask) | 0x80;
            if (g_keypress_pending) b[0] |= 0x04;
            if (g_keypress_pending and b.len > 1) {
                b[1] = @truncate(@as(u32, @bitCast(g_key_code)));
            }
        }
    }
    if (arr.fields.len > 1) {
        arr.fields[1] = (arr.fields[1] & clear_mask) | 0x80;
        if (g_keypress_pending) arr.fields[1] |= 0x04;
        if (g_keypress_pending and arr.fields.len > 2) {
            arr.fields[2] = @as(u32, @bitCast(g_key_code)) & 0xFF;
        }
    }
    // NOTE: do NOT clear `g_keypress_pending` here. Two consumers per
    // tick read it — first this function (sets the event-array bit
    // 0x04 for poll-based wait loops), then `dispatchKeyLifecycle` in
    // `tick()` (invokes the gamelet's keypress method). Clearing it
    // here made the lifecycle dispatch dead code, breaking menu nav
    // in gamelets like Crash that handle nav via `keypress(int)`
    // rather than poll-on-event-byte. Clearing happens once in tick()
    // after both consumers run.
}

pub fn tick(delta_ms: u32) void {
    g_tick_count += 1;
    if (g_vm_interp == null) return;
    const vm = &g_vm_interp.?;
    vm.clock_ms +%= delta_ms; // deterministic time source (see Vm.clock_ms)
    interp.Vm.trace = (g_tick_count == 1);
    vm.slab_top = 0;

    // Deliver event flags BEFORE the gamelet's tick runs so its
    // spin-loop predicates see the flags this iteration.
    deliverEventFlags(vm);

    // If a key event is pending, route it to the gamelet's
    // keypress/keyrelease lifecycle methods (passing the ExEn
    // key code), so menu navigation works. Consumed once per tick.
    if (g_keypress_pending) {
        dispatchKeyLifecycle(vm, class_registry.METHOD_KEYPRESS, g_key_code);
        g_keypress_pending = false;
    }
    if (g_keyrelease_pending) {
        dispatchKeyLifecycle(vm, class_registry.METHOD_KEYRELEASE, g_key_code);
        g_keyrelease_pending = false;
    }

    vm.halted = false;
    interp.Vm.instr_budget_used = 0;
    vm.invokeStatic(
        class_registry.CLASS_VM_SYS_BOOTSTRAP,
        class_registry.METHOD_TICK,
    ) catch |err| {
        // Canonical's `sub_407A13` ("non-catcheable Internal Exception"
        // trace) sets state==2 and the outer simulator loop resumes on
        // the next WM_TIMER fire. We mirror that by simply continuing —
        // the next `tick()` will run with `vm.halted = false` and a
        // fresh instruction budget. If the halt_reason is .internal_exception
        // we log it in canonical's shape; otherwise it's an opcode-level
        // hard error and we keep the more detailed warning.
        switch (vm.halt_reason) {
            .internal_exception => |code| log.warn(
                "tick #{d}: Internal Exception (code=0x{x:0>8}) — resuming next tick",
                .{ g_tick_count, code },
            ),
            else => log.warn(
                "tick #{d} invoke failed: {s} (reason={any})",
                .{ g_tick_count, @errorName(err), vm.halt_reason },
            ),
        }
    };

    // Garbage-collect between ticks (operand slab is quiescent here — slab_top is
    // back to its bootstrap baseline). Conservative mark-sweep rooted at class
    // statics + the bootstrap gamelet; bounds heap growth across a long session.
    vm.collectGarbage();

    // SPAWN-DEBUG (BanjoKazooie enemy hunt): once per second of frames,
    // dump the global game-state static (class 0x8c48fceb slot 9 =
    // field 0xdbaac735, pinned at 14 in prior sessions) and a census of
    // live heap instances by class. Lets a focused playthrough show
    // whether the game ever changes phase or accumulates enemy objects.
    if (g_tick_count % 30 == 0) {
        const gs: u32 = if (vm.class_objects.get(0x8c48fceb)) |co| co.statics[9] else 0xffffffff;
        var counts = std.AutoHashMap(u32, u32).init(std.heap.page_allocator);
        defer counts.deinit();
        var it = vm.heap.instances.valueIterator();
        while (it.next()) |pp| {
            const h = pp.*.class_hash;
            const gop = counts.getOrPut(h) catch continue;
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        }
        var census_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&census_buf);
        var cit = counts.iterator();
        while (cit.next()) |e| {
            switch (e.key_ptr.*) {
                0xbab5c664, 0x5562ca3b, 0x23c5e7e8, 0x7772dde3, 0x6bddc5b7 => {},
                else => fbs.writer().print("0x{x:0>8}:{d} ", .{ e.key_ptr.*, e.value_ptr.* }) catch {},
            }
        }
        std.log.scoped(.spawndbg).info("HEARTBEAT tick={d} live_total={d} gamestate=0x{x} live={s}", .{
            g_tick_count, vm.heap.instances.count(), gs, fbs.getWritten(),
        });
    }
}

// ── Save-state backend (per-gamelet, frontend-overridable) ─────────────────
//
// `Gamelet.saveCtx` / `loadCtx` (natives at idx 79/80) persist a per-gamelet
// byte buffer (max 300 bytes per canonical `sub_4153F8`). Two design points
// that differ from the canonical eeprom.dat (single shared file):
//
//   1. **Per-gamelet isolation.** Each gamelet gets its own save slot,
//      keyed by the .exn's `name` field (sanitised). Loading
//      TheTerminator's save no longer clobbers Pikubi's. Canonical
//      the reference simulator stores all in one eeprom.dat — but conflates
//      gamelet boundaries; our split is a behavioural improvement.
//
//   2. **Frontend-overridable.** The SDL frontend (or any host) can
//      register a `SaveBackend` via `setSaveBackend()` to redirect
//      save data anywhere (`~/.config/...`, cloud sync, in-memory for
//      tests, etc.). Default backend writes to
//      `<flash_dir>/save-<gamelet_name>.dat`.

pub const SaveBackend = struct {
    /// Write `data` to slot `name`. Return bytes actually persisted (0 on failure).
    save: *const fn (name: []const u8, data: []const u8) usize,
    /// Read up to `dst.len` bytes from slot `name`. Return bytes actually loaded.
    load: *const fn (name: []const u8, dst: []u8) usize,
};

var g_save_backend: ?SaveBackend = null;

/// Register a host-supplied save/load backend. Pass `null` to revert
/// to the default (per-gamelet files under `<flash_dir>/save-*.dat`).
pub fn setSaveBackend(b: ?SaveBackend) void {
    g_save_backend = b;
}

/// Sanitise the gamelet name into a filesystem-safe slot id.
/// Keeps `[A-Za-z0-9_-]`, replaces other chars with `_`.
fn sanitiseSlotName(buf: []u8, name: []const u8) []u8 {
    var n: usize = 0;
    while (n < name.len and n < buf.len) : (n += 1) {
        const c = name[n];
        buf[n] = if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                     (c >= '0' and c <= '9') or c == '_' or c == '-') c else '_';
    }
    return buf[0..n];
}

/// Resolve the current gamelet's slot name (from the loaded .exn), or
/// "default" if none is loaded yet.
fn currentSlotName(buf: []u8) []u8 {
    if (g_loaded_exn) |loaded| {
        return sanitiseSlotName(buf, loaded.name);
    }
    const fallback = "default";
    if (buf.len >= fallback.len) {
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    return buf[0..0];
}

/// Read up to `dst.len` bytes (max 300) from the current gamelet's save
/// slot into `dst`. Mirrors the canonical `sub_41547B` — clamps size
/// to 300, leaves the destination untouched on missing/short save
/// (gamelet sees zeros, which it interprets as "no saved game" /
/// fresh-defaults state). Returns the number of bytes actually copied.
///
/// Delegation order:
///   1. If host registered a `SaveBackend`, call its `load`.
///   2. Else, read from `<flash_dir>/save-<slot>.dat`.
pub fn eepromLoad(dst: []u8) usize {
    if (dst.len == 0) return 0;
    const cap: usize = @min(dst.len, 300);
    var name_buf: [128]u8 = undefined;
    const slot = currentSlotName(&name_buf);

    if (g_save_backend) |b| return b.load(slot, dst[0..cap]);

    // Default backend: per-gamelet file under flash_dir.
    if (g_flash_dir.len == 0) return 0;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}save-{s}.dat", .{ g_flash_dir, slot }) catch return 0;
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    return file.readAll(dst[0..cap]) catch 0;
}

/// Write up to `src.len` bytes (max 300) to the current gamelet's save
/// slot. Mirrors `sub_4153F8`:
///   sub_4041CA(SAVE_AREA + 0, Src, Size)   // memcpy into +60 fixed buffer
/// The canonical save area is a persistent **300-byte buffer**; a small
/// partial save (e.g. 4-byte level-number write) only overwrites the
/// first 4 bytes, leaving bytes 4..299 intact from previous full saves.
///
/// We therefore must NOT truncate. Open the file without truncate, seek
/// to 0, write `cap` bytes — any tail bytes from earlier larger saves
/// survive. (Crash bandicoot's "next level" transition first does a
/// full 300-byte save, then a 4-byte level-number-only save; with
/// truncate-on-save the next 300-byte load returns 4 bytes + 296 of
/// uninitialised garbage, sending the gamelet back to the default page.)
///
/// Delegation order: same as `eepromLoad` (backend first, default
/// per-gamelet file second).
pub fn eepromSave(src: []const u8) usize {
    if (src.len == 0) return 0;
    const cap: usize = @min(src.len, 300);
    var name_buf: [128]u8 = undefined;
    const slot = currentSlotName(&name_buf);

    if (g_save_backend) |b| return b.save(slot, src[0..cap]);

    // Default backend: per-gamelet file under flash_dir.
    if (g_flash_dir.len == 0) return 0;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}save-{s}.dat", .{ g_flash_dir, slot }) catch return 0;
    const file = std.fs.cwd().createFile(path, .{ .truncate = false, .read = true }) catch return 0;
    defer file.close();
    file.seekTo(0) catch return 0;
    file.writeAll(src[0..cap]) catch return 0;
    return cap;
}

/// Called from the SDL key handler when a key is pressed.
/// `key_code` should be an ExEn code (numeric ASCII for 0-9/*/#,
/// negative for arrows / soft keys).
pub fn signalKeypress(key_code: i32) void {
    g_keypress_pending = true;
    g_key_code = key_code;
    // Arm a focused trace burst so the next ~600 opcodes after this
    // key is dispatched get logged. This is for tracking down the
    // "JEU sub-menu skipped" bug — we want to see exactly what the
    // gamelet's keyPress handler routes to.
    _ = interp.Vm.trace_burst_remaining; // ad-hoc trace switch
}

pub fn signalKeyrelease(key_code: i32) void {
    g_keyrelease_pending = true;
    g_key_code = key_code;
}

/// Resolve and invoke the gamelet's `keypress` / `keyrelease`
/// lifecycle methods with the provided ExEn key code. Falls
/// silently if neither is overridden by the gamelet — the byte-
/// array flag we set in `deliverEventFlags` still wakes any
/// polling-based wait loop.
fn dispatchKeyLifecycle(vm: *interp.Vm, method_hash: u32, key_code: i32) void {
    const bs = vm.class_objects.get(class_registry.CLASS_VM_SYS_BOOTSTRAP) orelse return;
    const gamelet_handle = bs.statics[0];
    if (gamelet_handle == 0) return;
    const inst = vm.heap.get(gamelet_handle) orelse return;
    const mi = vm.resolveVirtual(inst.class_hash, method_hash) orelse return;
    // Bootstrap's lifecycle methods are dispatchers, not stubs — they
    // contain bytecode that routes to the gamelet's actual handler
    // (verified by the boot-time probe: even `tick` resolves only to
    // Bootstrap, yet ticking the gamelet animates the screen). Earlier
    // code bailed here thinking Bootstrap was a no-op, which made the
    // entire keypress/keyrelease path dead.
    vm.halted = false;
    interp.Vm.instr_budget_used = 0;
    // Bootstrap.{keyPress,keyRelease} have `locals=1` and read the
    // gamelet handle via GETSTATIC, not from a `this` param — so the
    // single local IS the key code, not the receiver. Earlier we
    // passed [gamelet_handle, key_code]; only the handle landed in
    // locals[0], the key code was dropped, and downstream TABLESWITCH
    // saw the handle value (1) instead of the real key (e.g. 56 for
    // DOWN) — landing in Gamelet.throwInternalException.
    var args = [_]u32{@bitCast(key_code)};
    vm.invokeMethodInfo(mi, null, &args) catch |err| {
        log.warn("key lifecycle dispatch failed: {s}", .{@errorName(err)});
    };
}

/// Borrowed view of the simulated LCD framebuffer. Host wraps it in
/// an SDL_Texture and uploads on each frame.
pub fn framebuffer() ?*gfx.Framebuffer {
    if (g_fb) |*fb| return fb;
    return null;
}

pub fn shutdown() void {
    if (g_vm_interp) |*vm| {
        // The VM allocated slab/class-statics from the FBA and its object heap from the
        // object arena; both are bulk-freed below, so the per-object frees here are
        // effectively no-ops. `deinit`'s param frees slab/class-statics (FBA).
        vm.deinit(g_vm_fba.allocator());
        g_vm_interp = null;
    }
    if (g_vm_arena.len != 0) {
        g_alloc.free(g_vm_arena);
        g_vm_arena = &.{};
    }
    if (g_obj_buf.len != 0) {
        g_alloc.free(g_obj_buf);
        g_obj_buf = &.{};
    }
    if (g_registry) |*r| {
        r.deinit();
        g_registry = null;
    }
    if (g_builtins_blob) |blob| {
        g_alloc.free(blob);
        g_builtins_blob = null;
    }
    if (g_fb) |*fb| {
        fb.deinit();
        g_fb = null;
    }
    if (g_loaded_layout) |*layout| {
        layout.deinit();
        g_loaded_layout = null;
    }
    if (g_loaded_classfile) |*cf| {
        cf.deinit();
        g_loaded_classfile = null;
    }
    if (g_loaded_exn) |*loaded| {
        loaded.deinit();
        g_loaded_exn = null;
    }
    if (g_vm_heap.len != 0) {
        g_alloc.free(g_vm_heap);
        g_vm_heap = &.{};
    }
    if (g_eeprom_path.len != 0) {
        g_alloc.free(g_eeprom_path);
        g_eeprom_path = &.{};
    }
    if (g_flash_dir.len != 0) {
        g_alloc.free(g_flash_dir);
        g_flash_dir = &.{};
    }
    if (g_server_dir.len != 0) {
        g_alloc.free(g_server_dir);
        g_server_dir = &.{};
    }
    if (g_ini) |ini| {
        ini.deinit();
        g_ini = null;
    }
    dispatcher.clearHandlers();
    text.deinit();
}

// ===========================================================================
// Save-states (libretro retro_serialize primitive, also via the WASM ABI).
//
// The whole interp VM allocates from one fixed buffer (`g_vm_arena`), so a snapshot
// is: the used arena bytes + the interp Vm struct (whose slab/map pointers index into
// the arena) + the separate composite heap + the VmState block + input/tick scalars +
// the framebuffer. Pointers are arena/global addresses, valid when reloaded into the
// same running core (same-session / rewind). Taken between ticks (quiescent VM).
// ===========================================================================
const ST_MAGIC: u32 = 0x4558_4E53; // "EXNS"
const ST_VERSION: u32 = 2; // v2: object heap serialized as a table (was flat-dumped in the FBA)

/// Serialized size of the object heap (the heap moved off the FBA to the gpa so the GC
/// can free it — see [[reference_exen_canonical_gc]] — so it can't ride the flat dump).
fn heapStateSize() usize {
    const h = &g_vm_interp.?.heap;
    var n: usize = 8; // next_handle + count
    var it = h.instances.valueIterator();
    while (it.next()) |pp| {
        const inst = pp.*;
        n += 8 + 64 * 4 + 32; // handle+class, fields[64], scalars (padded)
        n += 4 + (if (inst.field_map_init) inst.field_map.count() * 8 else 0);
        n += 4 + (if (inst.bytes) |b| b.len else 0);
        n += 4 + (if (inst.ints) |a| a.len * 4 else 0);
    }
    return n;
}

/// Stable-ish upper bound for retro_serialize_size (no frames run between this and
/// the serialize call, so the heap/arena can't grow under us).
pub fn stateSize() usize {
    if (g_vm_interp == null) return 0;
    const fb_bytes: usize = if (g_fb) |fb| fb.pixels.len * 4 else 0;
    return g_vm_fba.end_index + @sizeOf(interp.Vm) + g_vm_heap.len + g_vm.bytes.len + fb_bytes + heapStateSize() + 8192;
}

pub fn saveState(out: []u8) !usize {
    if (g_vm_interp == null) return error.NotBooted;
    var w = savestate.Cursor{ .buf = out };
    w.u32v(ST_MAGIC);
    w.u32v(ST_VERSION);
    w.usizev(g_vm_fba.end_index);
    w.bytes(g_vm_arena[0..g_vm_fba.end_index]);
    w.bytes(std.mem.asBytes(&g_vm_interp.?));
    w.usizev(g_vm_heap.len);
    w.bytes(g_vm_heap);
    w.bytes(&g_vm.bytes);
    w.u32v(g_tick_count);
    w.u32v(@intFromBool(g_keypress_pending));
    w.u32v(@intFromBool(g_keyrelease_pending));
    w.val(g_key_code);
    w.u32v(g_timer_period_ms);
    if (g_fb) |fb| {
        w.u32v(1);
        w.usizev(fb.pixels.len);
        w.bytes(std.mem.sliceAsBytes(fb.pixels));
    } else w.u32v(0);

    // object heap (lives on the gpa, NOT the FBA flat dump) — serialize as a table.
    // Handles are position-independent, so the handles still sitting in the slab/statics
    // (restored from the flat arena dump) keep pointing at the right rebuilt objects.
    const h = &g_vm_interp.?.heap;
    w.u32v(h.next_handle);
    w.u32v(h.instances.count());
    var hit = h.instances.iterator();
    while (hit.next()) |e| {
        const inst = e.value_ptr.*;
        w.u32v(e.key_ptr.*);
        w.u32v(inst.class_hash);
        for (inst.fields) |f| w.u32v(f);
        if (inst.field_map_init) {
            w.u32v(inst.field_map.count());
            var fit = inst.field_map.iterator();
            while (fit.next()) |fe| { w.u32v(fe.key_ptr.*); w.u32v(fe.value_ptr.*); }
        } else w.u32v(0);
        if (inst.bytes) |b| { w.u32v(@intCast(b.len)); w.bytes(b); } else w.u32v(0xFFFF_FFFF);
        if (inst.ints) |a| { w.u32v(@intCast(a.len)); for (a) |x| w.u32v(x); } else w.u32v(0xFFFF_FFFF);
        w.u32v(inst.pix_w);
        w.u32v(inst.pix_h);
        w.val(inst.is_render_target);
        w.val(inst.desc_origin_x);
        w.val(inst.desc_origin_y);
        w.u32v(inst.desc_logical_w);
        w.u32v(inst.desc_logical_h);
        w.val(inst.desc_depth);
        w.val(inst.is_image_descriptor);
    }
    return w.pos;
}

pub fn loadState(in: []const u8) !void {
    if (g_vm_interp == null) return error.NotBooted;
    var r = savestate.Reader{ .buf = in };
    if (try r.u32v() != ST_MAGIC) return error.BadMagic;
    if (try r.u32v() != ST_VERSION) return error.BadVersion;

    // arena (object heap + slab + class statics)
    const end_index = try r.usizev();
    if (end_index > g_vm_arena.len) return error.ArenaOverflow;
    @memcpy(g_vm_arena[0..end_index], try r.bytes(end_index));
    g_vm_fba.end_index = end_index;

    // interp Vm struct — preserve fields that point OUTSIDE the arena (set at boot)
    const cur = &g_vm_interp.?;
    const keep_registry = cur.registry;
    const keep_native = cur.native_fn;
    const keep_fb = cur.framebuffer;
    const keep_exn = cur.exn_raw;
    // The object heap lives on the gpa (off the FBA so the GC can free it). The dumped
    // Vm struct's `heap` (map ptr/allocator into gpa) must NOT clobber the live one —
    // we keep the live heap struct and rebuild its CONTENTS from the object table below.
    const keep_heap = cur.heap;
    @memcpy(std.mem.asBytes(cur), try r.bytes(@sizeOf(interp.Vm)));
    cur.registry = keep_registry;
    cur.native_fn = keep_native;
    cur.framebuffer = keep_fb;
    cur.exn_raw = keep_exn;
    cur.heap = keep_heap;

    // composite heap
    const heap_len = try r.usizev();
    if (heap_len != g_vm_heap.len) return error.HeapSizeMismatch;
    @memcpy(g_vm_heap, try r.bytes(heap_len));

    // VmState block + scalars
    @memcpy(&g_vm.bytes, try r.bytes(g_vm.bytes.len));
    g_tick_count = try r.u32v();
    g_keypress_pending = (try r.u32v()) != 0;
    g_keyrelease_pending = (try r.u32v()) != 0;
    g_key_code = try r.val(i32);
    g_timer_period_ms = try r.u32v();

    // framebuffer
    if ((try r.u32v()) != 0) {
        const n = try r.usizev();
        const px = try r.bytes(n * 4);
        if (g_fb) |*fb| if (n == fb.pixels.len) @memcpy(std.mem.sliceAsBytes(fb.pixels), px);
    }

    // object heap — free the current objects and rebuild the table (handles preserved,
    // so the handles restored into the slab/statics above resolve to the right objects).
    {
        const h = &g_vm_interp.?.heap;
        const A = h.allocator;
        h.clearAll();
        h.next_handle = try r.u32v();
        const count = try r.u32v();
        var oi: u32 = 0;
        while (oi < count) : (oi += 1) {
            const handle = try r.u32v();
            const inst = try A.create(interp.Instance);
            inst.* = .{ .class_hash = try r.u32v() };
            inst.field_map = std.AutoHashMap(u32, u32).init(A);
            inst.field_map_init = true;
            for (&inst.fields) |*f| f.* = try r.u32v();
            const fm = try r.u32v();
            var fj: u32 = 0;
            while (fj < fm) : (fj += 1) {
                const k = try r.u32v();
                const v = try r.u32v();
                try inst.field_map.put(k, v);
            }
            const blen = try r.u32v();
            if (blen != 0xFFFF_FFFF) inst.bytes = try A.dupe(u8, try r.bytes(blen));
            const ilen = try r.u32v();
            if (ilen != 0xFFFF_FFFF) {
                const arr = try A.alloc(u32, ilen);
                for (arr) |*x| x.* = try r.u32v();
                inst.ints = arr;
            }
            inst.pix_w = try r.u32v();
            inst.pix_h = try r.u32v();
            inst.is_render_target = try r.val(bool);
            inst.desc_origin_x = try r.val(i32);
            inst.desc_origin_y = try r.val(i32);
            inst.desc_logical_w = try r.u32v();
            inst.desc_logical_h = try r.u32v();
            inst.desc_depth = try r.val(u8);
            inst.is_image_descriptor = try r.val(bool);
            try h.instances.put(handle, inst);
        }
    }
}

pub fn screenWidth() u32 {
    return g_screen_w;
}

/// Index of the currently active [Manuf.NNN] profile (1..16). Reflects
/// what boot() last resolved — either `manuf_override` or the INI's
/// `[Manuf.current] CURRENT_COLOR`.
pub fn currentManufIndex() u32 {
    return g_manuf_idx;
}

/// Reads `[Manuf.NNN] NAME` from the currently-loaded simulator.ini.
/// Returns null if the section is unpopulated or boot() hasn't run.
/// The returned slice is owned by the Ini and remains valid until
/// shutdown().
pub fn deviceName(idx: u32) ?[]const u8 {
    const ini = g_ini orelse return null;
    var section_buf: [16]u8 = undefined;
    const section = std.fmt.bufPrint(&section_buf, "Manuf.{d:0>3}", .{idx}) catch return null;
    const name = ini.get(section, "NAME") orelse return null;
    if (name.len == 0) return null;
    return name;
}

pub fn deviceWidth(idx: u32) ?u32 {
    const ini = g_ini orelse return null;
    var section_buf: [16]u8 = undefined;
    const section = std.fmt.bufPrint(&section_buf, "Manuf.{d:0>3}", .{idx}) catch return null;
    const w = ini.getU32(section, "EXEN_DISPLAY_WIDTH", 0);
    if (w == 0) return null;
    return w;
}

pub fn deviceHeight(idx: u32) ?u32 {
    const ini = g_ini orelse return null;
    var section_buf: [16]u8 = undefined;
    const section = std.fmt.bufPrint(&section_buf, "Manuf.{d:0>3}", .{idx}) catch return null;
    const h = ini.getU32(section, "EXEN_DISPLAY_HEIGHT", 0);
    if (h == 0) return null;
    return h;
}

pub fn screenHeight() u32 {
    return g_screen_h;
}

/// Borrowed view of the currently loaded .exn file's raw bytes, if any.
pub fn loadedRaw() ?[]const u8 {
    if (g_loaded_exn) |loaded| return loaded.raw;
    return null;
}

/// Borrowed view of the parsed section layout, if a .exn has been loaded.
pub fn loadedLayout() ?*const exn.ExnLayout {
    if (g_loaded_layout) |*layout| return layout;
    return null;
}

/// Allocator used by `boot`. Callers can use this for transient decode
/// buffers (e.g. `render.decodeImage`) without holding their own allocator.
pub fn bootAllocator() std.mem.Allocator {
    return g_alloc;
}

// ── helpers ───────────────────────────────────────────────────────────────

/// Copy `src` into a fresh allocation owned by `allocator`, replacing any
/// backslashes with forward slashes so Windows-style paths from
/// `simulator.ini` work on Unix.
fn sanitizePath(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, src);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureEepromExists(path: []const u8) !void {
    if (std.fs.cwd().access(path, .{})) |_| {
        return;
    } else |_| {
        const f = try std.fs.cwd().createFile(path, .{});
        f.close();
    }
}
