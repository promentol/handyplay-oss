//! catalog.Catalog — native funcs_407AA2[] indices 178..183
//!
//! Hash 0xbbd967f9. The launcher-shell natives: game-catalog queries,
//! download/launch requests, registration check, an edit box, and a
//! plain atoi. Canonical state lives in the NVRAM blob + the launcher
//! state machine at dword_45FF3C (pump sub_403AC2: state 5 = launch
//! via app-FSM from the resource store keyed id+0xFFFF, state 6 =
//! server download). Our model: `core.catalogState()` (persisted
//! catalog.dat) + the `CatalogHost` injection for launch/edit-box —
//! downloads succeed instantly (no server).
//!
//! Method hashes (builtin 4CVP record @0xac68):
//!   178 doesGameExist       0x7291113f  sub_4240A0
//!   179 launchGameIfPresent 0x7291b2a7  sub_4240E1
//!   180 isUserRegistred     0xf53e0494  sub_424178
//!   181 downloadGame        0xb8fd5108  sub_424194
//!   182 doEditBox           0xf33ed04e  sub_4242B2
//!   183 atoi                0x1b487d9d  sub_424375
//!
//! The GameProperty argument object (class 0xdd22a4ed) carries:
//!   field slot 0  0x529d8a90  name/URL (String/byte[] ref, canonical +24)
//!   field slot 7  0xd042e190  game id  (int, canonical +52)

const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "Catalog";
pub const first_index: u32 = 178;
pub const last_index: u32 = 183;

const FIELD_GP_NAME: u32 = 0x529d8a90;
const FIELD_GP_ID: u32 = 0xd042e190;

/// Read the game id from a GameProperty argument (canonical
/// `*(u16*)(obj + 52)` — field slot 7).
fn gamePropertyId(vm: *Vm, obj: Handle) ?u16 {
    const inst = vm.heap.get(obj) orelse return null;
    const raw = inst.field_map.get(FIELD_GP_ID) orelse return null;
    return @truncate(raw);
}

// ── [178] doesGameExist(gp) → bool — sub_4240A0 ────────────────────────────
// Canonical: sub_423BD0(id) — record present AND device-fingerprint
// valid. Our records are always fingerprint-valid (we write them).
fn doesGameExist(vm: *Vm, args: bridge.ArgFrame) i16 {
    const id = gamePropertyId(vm, args.handle(1)) orelse {
        args.setReturn(0);
        return 1;
    };
    args.setReturn(@intFromBool(core.catalogState().find(id) != null));
    return 1;
}

// ── [179] launchGameIfPresent(gp) → bool — sub_4240E1 ──────────────────────
// Canonical: stash id in the launcher request, re-check validity, set
// launcher state 5 (pump then loads the game from the resource store
// keyed id+0xFFFF) + mode-switch flags. Our launch goes through the
// CatalogHost (id → .exn mapping is host policy); no host = no launch.
fn launchGameIfPresent(vm: *Vm, args: bridge.ArgFrame) i16 {
    const id = gamePropertyId(vm, args.handle(1)) orelse {
        args.setReturn(0);
        return 1;
    };
    if (core.catalogState().find(id) == null) {
        args.setReturn(0);
        return 1;
    }
    const host = core.catalogHost() orelse {
        args.setReturn(0);
        return 1;
    };
    args.setReturn(@intFromBool(host.launchGame(id)));
    return 1;
}

// ── [180] isUserRegistred() → bool — sub_424178 ────────────────────────────
// Canonical sub_423B7F: OR of the 4 registration-token bytes
// (dword_45FE8C+30..33; boot default {0,0,0,1} = registered).
fn isUserRegistred(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturn(@intFromBool(core.catalogState().isRegistered()));
    return 1;
}

// ── [181] downloadGame(gp) — sub_424194 ────────────────────────────────────
// Canonical copies the URL + id into the launcher request and enters
// the server download flow (state 6) — or the error dialog when the
// device/registration gate fails. With no server, our download is an
// instant success: register the id as downloaded and persist. Pushes
// nothing.
fn downloadGame(vm: *Vm, args: bridge.ArgFrame) i16 {
    const id = gamePropertyId(vm, args.handle(1)) orelse return 0;
    core.catalogState().put(id, true);
    core.catalogPersist();
    return 0;
}

// ── [182] doEditBox(prompt) — sub_4242B2 ───────────────────────────────────
// Canonical: truncates the prompt to 14 chars, sets dialog type 11 and
// opens the host text-input (sub_403D8A, max input 6); the result
// lands in dialog+16 (see exen.catalogEditBoxResult). Pushes nothing.
fn doEditBox(vm: *Vm, args: bridge.ArgFrame) i16 {
    const host = core.catalogHost() orelse return 0;
    var prompt: []const u8 = &.{};
    if (vm.heap.get(args.handle(1))) |inst| {
        if (inst.bytes) |b| prompt = b[0..@min(b.len, 14)];
    }
    host.editBox(prompt, 6);
    return 0;
}

// ── [183] atoi(str) → int — sub_424375 ─────────────────────────────────────
// Canonical sub_422AD2: skip leading spaces, optional '-', accumulate
// decimal digits; −1 on empty/invalid input. Pushes 1 int.
fn atoi(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.handle(1)) orelse {
        args.setReturnI32(-1);
        return 1;
    };
    const s = inst.bytes orelse {
        args.setReturnI32(-1);
        return 1;
    };
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') {
        args.setReturnI32(-1);
        return 1;
    }
    var v: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v *% 10 +% (s[i] - '0');
    }
    args.setReturnI32(if (neg) -v else v);
    return 1;
}

pub const entries = .{
    .{ 178, "doesGameExist",       doesGameExist },
    .{ 179, "launchGameIfPresent", launchGameIfPresent },
    .{ 180, "isUserRegistred",     isUserRegistred },
    .{ 181, "downloadGame",        downloadGame },
    .{ 182, "doEditBox",           doEditBox },
    .{ 183, "atoi",                atoi },
};

pub const handle = bridge.canonical(entries);
