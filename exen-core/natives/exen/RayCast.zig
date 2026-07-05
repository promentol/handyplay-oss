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

// Graphics clip-rect fields — same synthetic slots Graphics.setClip (idx 11)
// writes and drawImage/AnimBitmap read. Canonical RayCast.draw (sub_4284C9)
// propagates the Graphics clip into the render descriptor via sub_425650 and
// clips the 3D view to it; we mirror that so the raycaster stays inside its
// viewport window and never overdraws the HUD above/below it.
const FIELD_CLIP_X: u32 = 0xC1C1_5078;
const FIELD_CLIP_Y: u32 = 0xC1C1_5079;
const FIELD_CLIP_W: u32 = 0xC1C1_507A;
const FIELD_CLIP_H: u32 = 0xC1C1_507B;

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

// ── The DDA ray — faithful port of canonical sub_41F7F2 ────────────────────
// World Q16, cell = 64 units ⇒ cell index = coord>>22 (one cell = 1<<22).
// Two independent marches:
//   • March 1 steps along world-y across horizontal grid lines; a wall there
//     is the HIGH nibble (b>>4) of the cell AT the boundary (boundary>>22).
//   • March 2 steps along world-x across vertical grid lines; a wall there is
//     the LOW nibble (b&0xF).
// The nearer hit (distance-along-ray = axis-delta / trig) wins. Distance is
// returned in Q0 "64-per-cell" units — same scale as sprite depth and the
// wall_h formula. tex_x is the 0..63 intra-cell hit coordinate, flipped per
// march direction. Prior code re-derived this and checked `boundary-1` for
// negative marches (off-by-one), so walls/doors dropped out depending on the
// view angle; this mirrors the canonical cell selection exactly.

const RayHit = struct {
    dist: i32, // fisheye-corrected distance, Q0 units (64 per cell)
    raw: i32, // nearer march distance along the ray, pre-fisheye (Q0)
    hit_x: i32,
    hit_y: i32,
    tex_id: u8,
    tex_x: u8,
};

fn absI64(v: i64) i64 {
    return if (v < 0) -v else v;
}

fn clampI32(v: i64) i32 {
    return @intCast(std.math.clamp(v, -0x7FFFFFFF, 0x7FFFFFFF));
}

fn castOneRay(ctx: *const Ctx, angle: i32, player_angle: i32) RayHit {
    const st = ctx.state;
    const circle = ebGet(st, 28); // 360°
    const a90 = ebGet(st, 44);
    const a180 = ebGet(st, 48);
    const a270 = ebGet(st, 52);
    const max_steps = ebGet(st, 0);
    const px: i64 = ebGet(st, 80);
    const py: i64 = ebGet(st, 84);
    var out: RayHit = .{ .dist = 0, .raw = 0, .hit_x = clampI32(px), .hit_y = clampI32(py), .tex_id = 0, .tex_x = 0 };
    const map = ctx.map orelse return out;
    const mw: i64 = ctx.map_w;
    const mh: i64 = ctx.map_h;
    if (mw <= 0 or mh <= 0 or max_steps <= 0) return out;

    const c: i64 = cosA(circle, angle); // Q16
    const s: i64 = sinA(circle, angle); // Q16
    const CELL: i64 = 1 << 22;

    // ── March 1 — horizontal grid lines (world-y), HIGH nibble ──
    var v14: i64 = 0x7FFFFFFF; // perp x-coord at the boundary
    var v42: i64 = 0x7FFFFFFF; // y-coord of the boundary
    var id1: u8 = 0;
    var v38: i64 = 0; // ±CELL march step (0 when the ray is horizontal)
    if (angle != a180 and angle != circle) {
        if (angle <= a180 or angle >= circle) {
            v42 = ((py >> 22) + 1) << 22;
            v38 = CELL;
        } else {
            v42 = (py >> 22) << 22;
            v38 = -CELL;
        }
        const v24 = v42 - py;
        const v44: i64 = if ((s >> 1) != 0) @divTrunc((c >> 1) << 16, s >> 1) else 3200; // cot Q16
        const v18 = (v38 >> 16) * v44;
        const v15 = px + (v24 >> 16) * v44;
        v14 = if (v18 >= 0) v15 + 0x7FFF else v15 - 0x7FFF;
        var i: i32 = 0;
        while (i < max_steps) : (i += 1) {
            const cx = v14 >> 22;
            const cy = v42 >> 22;
            if (cx < 0 or cy < 0 or cx >= mw or cy >= mh) break;
            const idx: usize = @intCast(cy * mw + cx);
            if (idx >= map.len) break;
            const b = map[idx];
            if ((b & 0xF0) != 0) {
                id1 = b >> 4;
                break;
            }
            v14 += v18;
            v42 += v38;
        }
    }

    // ── March 2 — vertical grid lines (world-x), LOW nibble ──
    var v11: i64 = 0x7FFFFFFF; // perp y-coord at the boundary
    var v28: i64 = 0x7FFFFFFF; // x-coord of the boundary
    var id2: u8 = 0;
    var v46: i64 = 0; // ±CELL march step (0 when the ray is vertical)
    if (angle != a90 and angle != a270) {
        if (angle <= a90 or angle >= a270) {
            v28 = ((px >> 22) + 1) << 22;
            v46 = CELL;
        } else {
            v28 = (px >> 22) << 22;
            v46 = -CELL;
        }
        const v19 = v28 - px;
        const v7: i64 = if (@divTrunc(c, 2) != 0) @divTrunc(@divTrunc(s, 2) << 16, @divTrunc(c, 2)) else 3200; // tan Q16
        const v33 = (v46 >> 16) * v7;
        const v12 = py + (v19 >> 16) * v7;
        v11 = if (v33 >= 0) v12 + 0x7FFF else v12 - 0x7FFF;
        var j: i32 = 0;
        while (j < max_steps) : (j += 1) {
            const cx = v28 >> 22;
            const cy = v11 >> 22;
            if (cx < 0 or cy < 0 or cx >= mw or cy >= mh) break;
            const idx: usize = @intCast(cy * mw + cx);
            if (idx >= map.len) break;
            const b = map[idx];
            if ((b & 0x0F) != 0) {
                id2 = b & 0x0F;
                break;
            }
            v28 += v46;
            v11 += v33;
        }
    }

    // ── Pick the nearer march (distance along ray = axis-delta / trig) ──
    const v32: i64 = if (s == 0) 0x7FFFFFFF else absI64(@divTrunc(v42 - py, s)); // horiz-march dist
    const v45: i64 = if (c == 0) 0x7FFFFFFF else absI64(@divTrunc(v28 - px, c)); // vert-march dist
    var v40: i64 = undefined;
    const use_vertical = v32 >= v45;
    if (use_vertical) {
        v40 = v45;
        out.hit_x = clampI32(v28);
        out.hit_y = clampI32(v11);
    } else {
        v40 = v32;
        out.hit_x = clampI32(v14);
        out.hit_y = clampI32(v42);
    }

    // Fisheye correction: dist = |cos(rayAngle − playerAngle)| · v40 >> 16.
    var v17 = angle - player_angle;
    if (v17 < 0) v17 += circle;
    if (v17 < 0) v17 += circle;
    var v41: i64 = (@as(i64, cosA(circle, v17)) * v40) >> 16;
    if (v41 >= 0) {
        if (v41 == 0) v41 = 1;
    } else v41 = -v41;

    out.dist = clampI32(v41);
    out.raw = clampI32(v40);
    if (use_vertical) {
        out.tex_id = id2;
        const t: i64 = (v11 >> 16) & 0x3F;
        out.tex_x = @intCast(if (v46 >= 0) t else 63 - t);
    } else {
        out.tex_id = id1;
        const t: i64 = (v14 >> 16) & 0x3F;
        out.tex_x = @intCast(if (v38 >= 0) 63 - t else t);
    }
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
    // Canonical sub_4201BF: no sprite table → 0; else first free id; none → -1.
    const sp = ctx.sprites orelse {
        args.setReturnI32(0);
        return 1;
    };
    var id: i32 = 0;
    while (id < ctx.sprite_cap) : (id += 1) {
        if (recGet(sp, id, 0) == 0) {
            args.setReturnI32(id);
            return 1;
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
    // Canonical sub_428962 calls sub_41F7F2 without touching the player angle
    // (+88): the fisheye correction stays relative to the CURRENT view angle.
    const hit = castOneRay(&ctx, angle, ebGet(ctx.state, 88));
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
// ⚠ per-wall shade byte (EB+168) is NOT applied. In canonical (sub_41FEE7 →
// device blit) it is `shadeTable[texId&0xF]` and selects a 16-colour palette
// *bank* (index = nibble + bank*16) in the 4bpp wall texture. Our pipeline
// pre-decodes each wall texture to ABGR at bank 0, so re-banking at draw time
// would need a bank-aware texture decode. In MutantAlert the table is uniform
// ([0,3,3,3,0…]) — every visible wall is bank 3 — so the missing effect is a
// flat brightness shift, not distance/orientation shading.
// sprite image B (the second facing) is used only when image A is missing.
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

    // Clip the 3D view to the Graphics viewport (set via setClip right before
    // this draw). Matches drawImage/AnimBitmap so the raycaster renders only
    // inside its window and leaves the HUD above/below intact. Falls back to
    // the full target when no clip is set.
    var clip_x0: i32 = 0;
    var clip_y0: i32 = 0;
    var clip_x1: i32 = tw;
    var clip_y1: i32 = th;
    if (vm.heap.get(args.handle(1))) |g| {
        const gcw_u: u32 = g.field_map.get(FIELD_CLIP_W) orelse 0;
        const gch_u: u32 = g.field_map.get(FIELD_CLIP_H) orelse 0;
        if (gcw_u != 0 and gch_u != 0) {
            const gcx: i32 = @bitCast(g.field_map.get(FIELD_CLIP_X) orelse 0);
            const gcy: i32 = @bitCast(g.field_map.get(FIELD_CLIP_Y) orelse 0);
            clip_x0 = @max(0, gcx);
            clip_y0 = @max(0, gcy);
            clip_x1 = @min(tw, gcx + @as(i32, @intCast(gcw_u)));
            clip_y1 = @min(th, gcy + @as(i32, @intCast(gch_u)));
            if (clip_x1 <= clip_x0 or clip_y1 <= clip_y0) return 0;
        }
    }

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
                    if (dx < clip_x0 or dx >= clip_x1) continue;
                    var y: i32 = @max(y0, clip_y0);
                    const y_end = @min(y0 + wall_h, clip_y1);
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

        var dx: i32 = @max(sx0, clip_x0);
        const dx_end = @min(sx0 + pw, @min(clip_x1, screen_w));
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
            var dy: i32 = @max(sy0, clip_y0);
            const dy_end = @min(sy0 + ph, clip_y1);
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
