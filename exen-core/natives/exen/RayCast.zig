//! exen.RayCast — native funcs_407AA2[] indices 137..146
//!
//! Hash 0xd0b8e4ac. A real Wolfenstein-style raycaster. Full engine spec
//! (canonical sub bodies, EB field map, sprite-record layout, renderer
//! algorithm): `docs/raycast_engine.md`.
//!
//! Canonical keeps ALL engine state inside Java byte[] arrays owned by
//! the gamelet (the natives re-bind `EB = stateArray+20` on every call —
//! sub_4282B0). We mirror that: every config/derived/player field is
//! read from and written to the gamelet's own state array (`inst.bytes`,
//! little-endian dwords at the canonical EB offsets) so the class's 13
//! bytecode methods stay coherent with native writes. Pointer-valued EB
//! fields (+92/+104../+168/+172/+184..+196) are host pointers in
//! canonical and are NOT mirrored — we resolve those from the object's
//! fields each call instead.
//!
//! Java object fields (slot → hash), see docs/raycast_engine.md:
//!   0 0x88f81d8f Image[] wall textures      1 0xa6f17a61 byte[] wall shade
//!   2 0xd0429098 int sprite capacity        3 0x88f81db0 Image[] sprite tex A
//!   4 0x88f8b451 Image[] sprite tex B       5 0xa6f16466 byte[] ENGINE STATE
//!   6 0xa6f13bf1 byte[] sprite table (84B)  7 0xa6f1a52d byte[] column buffer
//!   8 0xa6f1240f byte[] map (nibble-packed) 9/10 0xd042d0fe/0xd042c2f5 map w/h

const std = @import("std");
const core = @import("core");
const interp = core.interp;
const bridge = core.bridge;
const _h = @import("../_helpers.zig");

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "RayCast";
pub const first_index: u32 = 137;
pub const last_index: u32 = 146;

const FIELD_WALL_TEX: u32 = 0x88f81d8f;
const FIELD_WALL_SHADE: u32 = 0xa6f17a61;
const FIELD_SPRITE_CAP: u32 = 0xd0429098;
const FIELD_SPR_TEX_A: u32 = 0x88f81db0;
const FIELD_SPR_TEX_B: u32 = 0x88f8b451;
const FIELD_STATE: u32 = 0xa6f16466;
const FIELD_SPRITES: u32 = 0xa6f13bf1;
const FIELD_COLBUF: u32 = 0xa6f1a52d;
const FIELD_MAP: u32 = 0xa6f1240f;
const FIELD_MAP_W: u32 = 0xd042d0fe;
const FIELD_MAP_H: u32 = 0xd042c2f5;

const SPRITE_REC = 84; // bytes per sprite record
const COL_REC = 8; // bytes per column-buffer record

// ── EB accessors (canonical byte offsets into the state array body) ────────

fn ebGet(state: []const u8, off: usize) i32 {
    if (off + 4 > state.len) return 0;
    return @bitCast(std.mem.readInt(u32, state[off..][0..4], .little));
}

fn ebSet(state: []u8, off: usize, v: i32) void {
    if (off + 4 > state.len) return;
    std.mem.writeInt(u32, state[off..][0..4], @bitCast(v), .little);
}

/// Bound engine context — the port's equivalent of the sub_4282B0 guard.
/// Null when the state array is missing (canonical logs + aborts the op).
const Ctx = struct {
    this: Handle,
    state: []u8,
    sprites: ?[]u8,
    colbuf: ?[]u8,
    map: ?[]const u8,
    map_w: i32,
    map_h: i32,
    sprite_cap: i32,
};

fn bytesOf(vm: *Vm, handle_v: u32) ?[]u8 {
    const inst = vm.heap.get(handle_v) orelse return null;
    return inst.bytes;
}

fn bind(vm: *Vm, this: Handle) ?Ctx {
    const inst = vm.heap.get(this) orelse return null;
    const state_h = inst.field_map.get(FIELD_STATE) orelse 0;
    const state = bytesOf(vm, state_h) orelse return null;
    const map_w: i32 = @bitCast(inst.field_map.get(FIELD_MAP_W) orelse 0);
    const map_h: i32 = @bitCast(inst.field_map.get(FIELD_MAP_H) orelse 0);
    // Mirror the guard's EB writes the bytecode side may read.
    ebSet(state, 96, map_w);
    ebSet(state, 100, map_h);
    const cap: i32 = @bitCast(inst.field_map.get(FIELD_SPRITE_CAP) orelse 0);
    ebSet(state, 180, cap);
    return .{
        .this = this,
        .state = state,
        .sprites = if (inst.field_map.get(FIELD_SPRITES)) |sh| bytesOf(vm, sh) else null,
        .colbuf = if (inst.field_map.get(FIELD_COLBUF)) |ch| bytesOf(vm, ch) else null,
        .map = if (inst.field_map.get(FIELD_MAP)) |mh| bytesOf(vm, mh) else null,
        .map_w = map_w,
        .map_h = map_h,
        .sprite_cap = cap,
    };
}

/// Element `i` of a Java Image[] field on `this` — an Image handle
/// (canonical sub_42846C resolves to a pixel descriptor; we return the
/// handle and decode pixels on use).
fn imageAt(vm: *Vm, this: Handle, field: u32, i: i32) u32 {
    if (i < 0) return 0;
    const inst = vm.heap.get(this) orelse return 0;
    const arr_h = inst.field_map.get(field) orelse return 0;
    const arr = vm.heap.get(arr_h) orelse return 0;
    const ix = arr.ints orelse return 0;
    const idx: usize = @intCast(i);
    if (idx >= ix.len) return 0;
    return ix[idx];
}

/// Decoded ABGR pixels of an Image handle (decode-on-demand, same as FX).
const Tex = struct { px: []const u32, w: i32, h: i32 };

fn texOf(vm: *Vm, image: u32) ?Tex {
    if (image == 0) return null;
    const inst = vm.heap.get(image) orelse return null;
    if (inst.pixels == null) _h.doTransformToSystemPalette(vm, image);
    const px = inst.pixels orelse return null;
    const w: i32 = @intCast(inst.pix_w);
    const h: i32 = @intCast(inst.pix_h);
    if (w <= 0 or h <= 0) return null;
    return .{ .px = px, .w = w, .h = h };
}

// ── Sprite-record accessors (dword index per docs/raycast_engine.md) ───────

fn recGet(sprites: []const u8, id: i32, word: usize) i32 {
    const off = @as(usize, @intCast(id)) * SPRITE_REC + word * 4;
    if (off + 4 > sprites.len) return 0;
    return @bitCast(std.mem.readInt(u32, sprites[off..][0..4], .little));
}

fn recSet(sprites: []u8, id: i32, word: usize, v: i32) void {
    const off = @as(usize, @intCast(id)) * SPRITE_REC + word * 4;
    if (off + 4 > sprites.len) return;
    std.mem.writeInt(u32, sprites[off..][0..4], @bitCast(v), .little);
}

fn validId(ctx: *const Ctx, id: i32) bool {
    return id >= 0 and id < ctx.sprite_cap and ctx.sprites != null;
}

// ── Trig: canonical angle domain [0, 6·W) per revolution, Q16 results ──────
// (sub_41C972 cos / sub_41C956 sin via the 2048-step table; we float-
// approximate at the same scale, like exen.Math and Matrix3D.)

fn cosA(circle: i32, a: i32) i32 {
    if (circle <= 0) return 0x10000;
    const norm = @mod(a, circle);
    const rad = @as(f64, @floatFromInt(norm)) * (std.math.tau / @as(f64, @floatFromInt(circle)));
    return @intFromFloat(@cos(rad) * 65536.0);
}

fn sinA(circle: i32, a: i32) i32 {
    if (circle <= 0) return 0;
    const norm = @mod(a, circle);
    const rad = @as(f64, @floatFromInt(norm)) * (std.math.tau / @as(f64, @floatFromInt(circle)));
    return @intFromFloat(@sin(rad) * 65536.0);
}

// ── The DDA ray (canonical sub_41F7F2) ─────────────────────────────────────
// World Q16, cell = 64 units ⇒ cell index = coord>>22. Map bytes pack two
// nibbles: HIGH = wall crossed on a horizontal grid line (marching in y),
// LOW = wall crossed on a vertical grid line (marching in x); nibble 0 =
// open. Returns the fisheye-corrected perpendicular distance plus hit
// metadata. ⚠ re-derived from the spec as a standard two-axis DDA; sign
// conventions verified visually (MutantAlert), not byte-stepped.

const RayHit = struct {
    dist: i32, // fisheye-corrected perpendicular distance (Q16)
    raw: i32, // uncorrected distance to the hit side
    hit_x: i32,
    hit_y: i32,
    tex_id: u8,
    tex_x: u8,
};

fn castOneRay(ctx: *const Ctx, angle: i32, player_angle: i32) RayHit {
    const circle = ebGet(ctx.state, 28);
    const max_steps = ebGet(ctx.state, 0);
    const px = ebGet(ctx.state, 80);
    const py = ebGet(ctx.state, 84);
    var out: RayHit = .{ .dist = 0, .raw = 0, .hit_x = px, .hit_y = py, .tex_id = 0, .tex_x = 0 };
    const map = ctx.map orelse return out;
    if (ctx.map_w <= 0 or ctx.map_h <= 0 or max_steps <= 0) return out;

    const c = cosA(circle, angle);
    const s = sinA(circle, angle);

    const INF: i64 = 0x7FFFFFFF;
    var best: i64 = INF;
    var best_id: u8 = 0;
    var best_tx: u8 = 0;
    var best_hx: i32 = px;
    var best_hy: i32 = py;

    // March 1 — horizontal grid lines (stepping world-y), HIGH nibble.
    if (s != 0) {
        const step_y: i32 = if (s > 0) 1 else -1;
        // First horizontal boundary above/below the player.
        var gy: i32 = if (s > 0) ((py >> 22) + 1) << 22 else (py >> 22) << 22;
        var i: i32 = 0;
        while (i < max_steps) : (i += 1) {
            const dy: i64 = gy - py;
            const dx: i64 = @divTrunc(dy * c, s);
            const wx: i32 = px + @as(i32, @intCast(std.math.clamp(dx, -(1 << 30), 1 << 30)));
            const cell_x = wx >> 22;
            const cell_y = (if (s > 0) gy else gy - 1) >> 22;
            if (cell_x < 0 or cell_y < 0 or cell_x >= ctx.map_w or cell_y >= ctx.map_h) break;
            const b = map[@intCast(cell_y * ctx.map_w + cell_x)];
            if ((b & 0xF0) != 0) {
                // distance along the ray to this boundary
                const d: i64 = @divTrunc((@as(i64, dy) << 16), if (s == 0) 1 else s);
                const ad: i64 = if (d < 0) -d else d;
                if (ad < best) {
                    best = ad;
                    best_id = b >> 4;
                    best_tx = @intCast((wx >> 16) & 0x3F);
                    best_hx = wx;
                    best_hy = gy;
                }
                break;
            }
            gy += step_y << 22;
        }
    }

    // March 2 — vertical grid lines (stepping world-x), LOW nibble.
    if (c != 0) {
        const step_x: i32 = if (c > 0) 1 else -1;
        var gx: i32 = if (c > 0) ((px >> 22) + 1) << 22 else (px >> 22) << 22;
        var i: i32 = 0;
        while (i < max_steps) : (i += 1) {
            const dx: i64 = gx - px;
            const dy: i64 = @divTrunc(dx * s, c);
            const wy: i32 = py + @as(i32, @intCast(std.math.clamp(dy, -(1 << 30), 1 << 30)));
            const cell_y = wy >> 22;
            const cell_x = (if (c > 0) gx else gx - 1) >> 22;
            if (cell_x < 0 or cell_y < 0 or cell_x >= ctx.map_w or cell_y >= ctx.map_h) break;
            const b = map[@intCast(cell_y * ctx.map_w + cell_x)];
            if ((b & 0x0F) != 0) {
                const d: i64 = @divTrunc((@as(i64, dx) << 16), if (c == 0) 1 else c);
                const ad: i64 = if (d < 0) -d else d;
                if (ad < best) {
                    best = ad;
                    best_id = b & 0x0F;
                    best_tx = @intCast(63 - ((wy >> 16) & 0x3F));
                    best_hx = gx;
                    best_hy = wy;
                }
                break;
            }
            gx += step_x << 22;
        }
    }

    if (best == INF) return out;
    out.raw = @intCast(@min(best, 0x7FFFFFFF));
    // Fisheye correction: dist * cos(rayAngle − playerAngle) >> 16.
    const rel = angle - player_angle;
    var corrected: i64 = (best * cosA(circle, rel)) >> 16;
    if (corrected <= 0) corrected = 1;
    out.dist = @intCast(@min(corrected, 0x7FFFFFFF));
    out.tex_id = best_id;
    out.tex_x = best_tx;
    out.hit_x = best_hx;
    out.hit_y = best_hy;
    return out;
}

fn clampPos(ctx: *const Ctx) void {
    // canonical sub_41F3FE: clamp player to [0, (dim-1)<<22].
    const max_x = if (ctx.map_w > 0) (ctx.map_w - 1) << 22 else 0;
    const max_y = if (ctx.map_h > 0) (ctx.map_h - 1) << 22 else 0;
    ebSet(ctx.state, 80, std.math.clamp(ebGet(ctx.state, 80), 0, max_x));
    ebSet(ctx.state, 84, std.math.clamp(ebGet(ctx.state, 84), 0, max_y));
}

// ── [145] changeInternalValues(w, h, wallScale, detail, yOff, mapDim) ──────
// Canonical sub_428910 → sub_41F0DA: derived-config computation only
// (arrays come from the object). Pushes nothing.
fn changeInternalValues(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const st = ctx.state;
    var w = args.getI32(1);
    const h = args.getI32(2);
    const wall_scale = args.getI32(3);
    const detail = args.getI32(4);
    const y_off = args.getI32(5);
    const map_dim = args.getI32(6);

    if (wall_scale > 0) ebSet(st, 8, wall_scale);
    if (detail == 1 or detail == 2) ebSet(st, 20, detail);
    if (w > 0) {
        if (ebGet(st, 20) == 2) w &= ~@as(i32, 1);
        const det = @max(ebGet(st, 20), 1);
        ebSet(st, 12, w);
        ebSet(st, 24, @divTrunc(w, det));
        ebSet(st, 176, @divTrunc(w, det));
        ebSet(st, 32, w);
        ebSet(st, 36, @divTrunc(w, 2));
        ebSet(st, 40, @divTrunc(w, 4));
        const quarter = 3 * @divTrunc(w, 2);
        ebSet(st, 44, quarter);
        ebSet(st, 48, 2 * quarter);
        ebSet(st, 52, 3 * quarter);
        ebSet(st, 28, 6 * w);
        ebSet(st, 4, 6 * w);
        ebSet(st, 56, 0);
        ebSet(st, 60, @divTrunc(@divTrunc(w, 2), 6));
        ebSet(st, 64, 2 * @divTrunc(@divTrunc(w, 2), 6));
        // projection-plane distance = halfW / tan(halfFOV)
        const circle = 6 * w;
        const half = @divTrunc(w, 2);
        const sh = sinA(circle, half);
        const ch = cosA(circle, half);
        const proj: i64 = if (sh != 0)
            @divTrunc(@as(i64, ch) * half, sh)
        else
            half;
        ebSet(st, 72, @intCast(@max(if (proj < 0) -proj else proj, 1)));
    }
    if (h > 0) ebSet(st, 16, h);
    ebSet(st, 68, y_off + @divTrunc(ebGet(st, 16), 2));
    if (y_off > 0) ebSet(st, 76, y_off);
    if (map_dim > 0) ebSet(st, 0, map_dim);
    return 0;
}

// ── [138] isThereAWall(x, y) → bool — sub_428683 → sub_41F5B9 ──────────────
// True if any of the cell's 4 surrounding half-edges is OPEN (nibble 0) —
// a walkability test, with canonical's bounds guards.
fn isThereAWall(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    const map = ctx.map orelse {
        args.setReturn(0);
        return 1;
    };
    const col = @divTrunc(args.getI32(1) >> 16, 64);
    const row = @divTrunc(args.getI32(2) >> 16, 64);
    const w = ctx.map_w;
    if (col < 1 or row < 1 or col >= w or w <= 0) {
        args.setReturn(0);
        return 1;
    }
    const idx = col + w * row;
    if (idx < w or idx + w >= map.len) {
        args.setReturn(0);
        return 1;
    }
    const i: usize = @intCast(idx);
    const open = (map[i + @as(usize, @intCast(w))] & 0xF0) == 0 or
        (map[i] & 0xF0) == 0 or
        (map[i + 1] & 0x0F) == 0 or
        (map[i] & 0x0F) == 0;
    args.setReturn(@intFromBool(open));
    return 1;
}

// ── [139] addMonster(id, w, h) → int — sub_4286C9 → sub_42022A ─────────────
// Activates record `id`: [0]=1, [4]=[8]=w, [5]=[9]=h, src rects and
// texture slots cleared. ⚠ canonical return value of sub_42022A not
// byte-verified; we push 1 on success / 0 on invalid id.
fn addMonster(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    const id = args.getI32(1);
    const w = args.getI32(2);
    const h = args.getI32(3);
    if (!validId(&ctx, id)) {
        args.setReturn(0);
        return 1;
    }
    const sp = ctx.sprites.?;
    recSet(sp, id, 0, 1);
    recSet(sp, id, 4, w);
    recSet(sp, id, 8, w);
    recSet(sp, id, 5, h);
    recSet(sp, id, 9, h);
    inline for (.{ 6, 7, 10, 11, 12, 13 }) |word| recSet(sp, id, word, 0);
    args.setReturn(1);
    return 1;
}

// ── [140] findFirstSpriteFreeID() → int — sub_428716 → sub_4201BF ──────────
fn findFirstSpriteFreeID(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    if (ctx.sprites) |sp| {
        var id: i32 = 0;
        while (id < ctx.sprite_cap) : (id += 1) {
            if (recGet(sp, id, 0) == 0) {
                args.setReturnI32(id);
                return 1;
            }
        }
    }
    args.setReturnI32(-1);
    return 1;
}

// ── [141] removeSprite(id) — sub_42874B → sub_4202C9 ───────────────────────
fn removeSprite(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const id = args.getI32(1);
    if (validId(&ctx, id)) recSet(ctx.sprites.?, id, 0, 0);
    return 0;
}

// ── [142] moveSprite(id, x, y, z) — sub_42877A → sub_420511 ────────────────
fn moveSprite(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const id = args.getI32(1);
    if (validId(&ctx, id)) {
        const sp = ctx.sprites.?;
        recSet(sp, id, 1, args.getI32(2));
        recSet(sp, id, 2, args.getI32(3));
        recSet(sp, id, 3, args.getI32(4));
    }
    return 0;
}

// ── [143] setSpritePos(id, ax, ay, w, h, bx, by) — sub_4287BE ──────────────
// Refreshes the record's texture slots from the A/B Image[] fields (we
// store the Image HANDLES where canonical stores descriptors), validates
// both source rects against the image dimensions (sub_420302), then
// writes [6..11].
fn setSpritePos(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const id = args.getI32(1);
    if (!validId(&ctx, id)) return 0;
    const sp = ctx.sprites.?;
    const img_a = imageAt(vm, ctx.this, FIELD_SPR_TEX_A, id);
    const img_b = imageAt(vm, ctx.this, FIELD_SPR_TEX_B, id);
    recSet(sp, id, 12, @bitCast(img_a));
    recSet(sp, id, 13, @bitCast(img_b));
    const ta = texOf(vm, img_a) orelse return 0;
    const tb = texOf(vm, img_b) orelse return 0;
    const ax = args.getI32(2);
    const ay = args.getI32(3);
    const w = args.getI32(4);
    const h = args.getI32(5);
    const bx = args.getI32(6);
    const by = args.getI32(7);
    if (w + ax > ta.w or h + ay > ta.h or w + bx > tb.w or h + by > tb.h) return 0;
    recSet(sp, id, 6, ax);
    recSet(sp, id, 7, ay);
    recSet(sp, id, 8, w);
    recSet(sp, id, 9, h);
    recSet(sp, id, 10, bx);
    recSet(sp, id, 11, by);
    return 0;
}

// ── [144] setSpriteSize(id, w, h) — sub_4288D3 → sub_420412 ────────────────
fn setSpriteSize(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const id = args.getI32(1);
    const w = args.getI32(2);
    const h = args.getI32(3);
    if (validId(&ctx, id) and w > 0 and h > 0) {
        recSet(ctx.sprites.?, id, 4, w);
        recSet(ctx.sprites.?, id, 5, h);
    }
    return 0;
}

// ── [146] castRay(x, y, angle, int[≥6] out) → bool — sub_428962 ────────────
fn castRay(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse {
        args.setReturn(0);
        return 1;
    };
    const out_h = args.handle(4);
    const out_inst = vm.heap.get(out_h) orelse {
        args.setReturn(0);
        return 1;
    };
    const out = out_inst.ints orelse {
        args.setReturn(0);
        return 1;
    };
    if (out.len < 6) {
        args.setReturn(0);
        return 1;
    }
    ebSet(ctx.state, 80, args.getI32(1));
    ebSet(ctx.state, 84, args.getI32(2));
    clampPos(&ctx);
    const angle = args.getI32(3);
    const hit = castOneRay(&ctx, angle, angle); // corrected == raw here (rel=0)
    out[0] = @bitCast(hit.hit_x);
    out[1] = @bitCast(hit.hit_y);
    out[2] = @bitCast(hit.raw);
    out[3] = @bitCast(hit.dist);
    out[4] = hit.tex_id;
    out[5] = hit.tex_x;
    args.setReturn(1);
    return 1;
}

// ── [137] draw(graphics, x, y, angle) — sub_4284C9 → sub_41F4DB ────────────
// Full frame: bind, set player, cast W/detail rays into the column
// buffer, wall strips (height = projDist·wallScale/dist centered on the
// horizon), then depth-sorted sprites with per-column occlusion.
// ⚠ per-wall shade byte (EB+168, palette-bank select in canonical) is
// not applied — we sample decoded ABGR directly; sprite image B (the
// second facing) is used only when image A is missing.
fn draw(vm: *Vm, args: bridge.ArgFrame) i16 {
    const ctx = bind(vm, args.this()) orelse return 0;
    const target = _h.graphicsTarget(vm, args.handle(1)) orelse return 0;
    const st = ctx.state;

    ebSet(st, 80, args.getI32(2));
    ebSet(st, 84, args.getI32(3));
    ebSet(st, 88, args.getI32(4));
    clampPos(&ctx);

    const circle = ebGet(st, 28);
    const screen_w = ebGet(st, 12);
    const screen_h = ebGet(st, 16);
    const detail = @max(ebGet(st, 20), 1);
    const half_fov = ebGet(st, 36);
    const horizon = ebGet(st, 68);
    const proj_dist = ebGet(st, 72);
    const wall_scale = ebGet(st, 8);
    const player_angle = ebGet(st, 88);
    if (circle <= 0 or screen_w <= 0 or screen_h <= 0) return 0;

    const tw: i32 = @intCast(target.width);
    const th: i32 = @intCast(target.height);
    const n_rays = @divTrunc(screen_w, detail);

    // 1. Cast rays → column records (also mirrored into the gamelet's
    //    column buffer so its bytecode can inspect distances).
    var ray_angle = @mod(player_angle - half_fov + circle, circle);
    var col: i32 = 0;
    while (col < n_rays) : (col += 1) {
        const hit = castOneRay(&ctx, ray_angle, player_angle);
        if (ctx.colbuf) |cb| {
            const off = @as(usize, @intCast(col)) * COL_REC;
            if (off + COL_REC <= cb.len) {
                std.mem.writeInt(u32, cb[off..][0..4], @bitCast(hit.dist), .little);
                cb[off + 4] = hit.tex_id;
                cb[off + 5] = hit.tex_x;
            }
        }
        // 2. Wall strip for this column.
        if (hit.dist > 0 and hit.tex_id != 0) {
            const wall_h: i32 = @intCast(std.math.clamp(
                @divTrunc(@as(i64, proj_dist) * wall_scale, hit.dist),
                0,
                4 * @as(i64, screen_h),
            ));
            if (wall_h > 0) blk: {
                const tex_img = imageAt(vm, ctx.this, FIELD_WALL_TEX, hit.tex_id & 0xF);
                const tex = texOf(vm, tex_img) orelse break :blk;
                const y0 = horizon - @divTrunc(wall_h, 2);
                const sx = @min(@as(i32, hit.tex_x), tex.w - 1);
                var d: i32 = 0;
                while (d < detail) : (d += 1) {
                    const dx = col * detail + d;
                    if (dx < 0 or dx >= tw) continue;
                    var y: i32 = @max(y0, 0);
                    const y_end = @min(y0 + wall_h, th);
                    while (y < y_end) : (y += 1) {
                        const ty = @divTrunc((y - y0) * tex.h, wall_h);
                        const sp = tex.px[@as(usize, @intCast(@min(ty, tex.h - 1))) * @as(usize, @intCast(tex.w)) + @as(usize, @intCast(sx))];
                        if ((sp >> 24) == 0) continue;
                        target.pixels[@as(usize, @intCast(y)) * target.width + @as(usize, @intCast(dx))] = sp;
                    }
                }
            }
        }
        ray_angle = @mod(ray_angle + detail, circle);
    }

    // 3. Sprites: project, sort far→near, draw with per-column occlusion.
    const sp = ctx.sprites orelse return 0;
    const px = ebGet(st, 80);
    const py = ebGet(st, 84);
    const cn = cosA(circle, -player_angle) >> 8;
    const sn = sinA(circle, -player_angle) >> 8;

    const Proj = struct { id: i32, depth: i32 };
    var list: [64]Proj = undefined;
    var n: usize = 0;
    var id: i32 = 0;
    while (id < ctx.sprite_cap and n < list.len) : (id += 1) {
        if (recGet(sp, id, 0) == 0) continue;
        const rx = (recGet(sp, id, 1) - px) >> 8;
        const ry = (recGet(sp, id, 2) - py) >> 8;
        const depth = (cn *% rx -% sn *% ry) >> 16;
        if (depth <= 0) continue;
        // projected size + screen pos (canonical sub_42055C)
        const scale: i64 = @divTrunc(@as(i64, proj_dist) << 16, depth);
        const pw: i32 = @intCast(std.math.clamp((scale * recGet(sp, id, 4)) >> 16, 0, 4 * @as(i64, screen_w)));
        const ph: i32 = @intCast(std.math.clamp((scale * recGet(sp, id, 5)) >> 16, 0, 4 * @as(i64, screen_h)));
        const lateral: i32 = @intCast(std.math.clamp((scale * ((cn *% ry +% sn *% rx) >> 16)) >> 16, -(4 * @as(i64, screen_w)), 4 * @as(i64, screen_w)));
        const sx0 = @divTrunc(screen_w - pw, 2) + lateral;
        const sy0 = horizon - (@divTrunc(ph, 2) + @as(i32, @intCast((scale * recGet(sp, id, 3)) >> 16)));
        if (sx0 + pw < 0 or sx0 >= screen_w or pw <= 0 or ph <= 0) continue;
        recSet(sp, id, 14, sx0);
        recSet(sp, id, 15, sy0);
        recSet(sp, id, 16, depth);
        recSet(sp, id, 17, pw);
        recSet(sp, id, 18, ph);
        list[n] = .{ .id = id, .depth = depth };
        n += 1;
    }
    // far → near
    std.mem.sort(Proj, list[0..n], {}, struct {
        fn lt(_: void, a: Proj, b: Proj) bool {
            return a.depth > b.depth;
        }
    }.lt);

    for (list[0..n]) |e| {
        const sid = e.id;
        var img = @as(u32, @bitCast(recGet(sp, sid, 12)));
        var src_x = recGet(sp, sid, 6);
        var src_y = recGet(sp, sid, 7);
        if (img == 0) {
            img = @bitCast(recGet(sp, sid, 13));
            src_x = recGet(sp, sid, 10);
            src_y = recGet(sp, sid, 11);
        }
        const tex = texOf(vm, img) orelse continue;
        const src_w = recGet(sp, sid, 8);
        const src_h = recGet(sp, sid, 9);
        if (src_w <= 0 or src_h <= 0) continue;
        const sx0 = recGet(sp, sid, 14);
        const sy0 = recGet(sp, sid, 15);
        const pw = recGet(sp, sid, 17);
        const ph = recGet(sp, sid, 18);
        const depth = recGet(sp, sid, 16);

        var dx: i32 = @max(sx0, 0);
        const dx_end = @min(sx0 + pw, @min(tw, screen_w));
        while (dx < dx_end) : (dx += 1) {
            // per-column occlusion vs the wall distance buffer
            if (ctx.colbuf) |cb| {
                const rcol = @divTrunc(dx, detail);
                const off = @as(usize, @intCast(rcol)) * COL_REC;
                if (off + 4 <= cb.len) {
                    const wall_d: i32 = @bitCast(std.mem.readInt(u32, cb[off..][0..4], .little));
                    if (wall_d > 0 and depth >= wall_d) continue;
                }
            }
            const u = src_x + @divTrunc((dx - sx0) * src_w, pw);
            if (u < 0 or u >= tex.w) continue;
            var dy: i32 = @max(sy0, 0);
            const dy_end = @min(sy0 + ph, th);
            while (dy < dy_end) : (dy += 1) {
                const v = src_y + @divTrunc((dy - sy0) * src_h, ph);
                if (v < 0 or v >= tex.h) continue;
                const c = tex.px[@as(usize, @intCast(v)) * @as(usize, @intCast(tex.w)) + @as(usize, @intCast(u))];
                if ((c >> 24) == 0) continue;
                target.pixels[@as(usize, @intCast(dy)) * target.width + @as(usize, @intCast(dx))] = c;
            }
        }
    }
    return 0;
}

pub const entries = .{
    .{ 137, "draw",                  draw },
    .{ 138, "isThereAWall",          isThereAWall },
    .{ 139, "addMonster",            addMonster },
    .{ 140, "findFirstSpriteFreeID", findFirstSpriteFreeID },
    .{ 141, "removeSprite",          removeSprite },
    .{ 142, "moveSprite",            moveSprite },
    .{ 143, "setSpritePos",          setSpritePos },
    .{ 144, "setSpriteSize",         setSpriteSize },
    .{ 145, "changeInternalValues",  changeInternalValues },
    .{ 146, "castRay",               castRay },
};

pub const handle = bridge.canonical(entries);
