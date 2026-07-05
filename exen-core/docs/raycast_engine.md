# exen.RayCast — canonical engine spec (port blueprint)

Reverse-engineered 2026-07-03 from `emulator.c` (packages/exen-player/emulator/).
Line numbers refer to that file. This is the implementation reference for
porting natives idx 137–146 (`natives/exen/RayCast.zig`).

## Architecture

A real Wolfenstein-style raycaster — but the engine **state lives in Java
byte[] arrays owned by the gamelet**, not in host memory. The simulator keeps
only a 4-byte pointer holder (`*(dword_45FF3C+44)`, alloc at :31989); every
native first runs the guard `sub_4282B0` (:27057) which re-binds
`EB := javaStateArray + 20` and refreshes all pointers from the Java object.
**Port consequence: our natives must operate on the gamelet's own array
Instances (`inst.bytes`, little-endian dword access) so the class's 13
bytecode methods stay coherent with native writes.**

## Java RayCast object fields (class 0xd0b8e4ac, 11 slots)

| slot | hash | tag | meaning |
|---|---|---|---|
| 0 | 0x88f81d8f | Image[] | wall textures (→ EB+104+4i via sub_42846C) |
| 1 | 0xa6f17a61 | byte[] | wall shade/index table (→ EB+168) |
| 2 | 0xd0429098 | int | sprite capacity (→ EB+180) |
| 3 | 0x88f81db0 | Image[] | sprite textures A (→ sprite rec +48) |
| 4 | 0x88f8b451 | Image[] | sprite textures B (→ sprite rec +52) |
| 5 | 0xa6f16466 | byte[] | **engine state array** (EB = this+20) |
| 6 | 0xa6f13bf1 | byte[] | sprite table, 84 B/record (→ EB+196) |
| 7 | 0xa6f1a52d | byte[] | column hit buffer, 8 B/ray (→ EB+172) |
| 8 | 0xa6f1240f | byte[] | map data, nibble-packed (→ EB+92) |
| 9 | 0xd042d0fe | int | map width (→ EB+96) |
| 10 | 0xd042c2f5 | int | map height (→ EB+100) |

Native method hashes: 137 draw 0x6b07a6fc (argc 4) · 138 isThereAWall
0x546b12ea · 139 addMonster 0x625c3542 · 140 findFirstSpriteFreeID
0xd724dc6a · 141 removeSprite 0x305a9e99 · 142 moveSprite 0xcf20d2c7 ·
143 setSpritePos 0xc342e202 (argc 7) · 144 setSpriteSize 0x8a2a3357 ·
145 changeInternalValues 0x88e671af (argc 6) · 146 castRay 0x729e78f8.
Push counts: 137/141/142/143/144/145 → 0; 138/139/140/146 → 1.

## EB field map (byte offsets into the state array body)

| off | meaning | | off | meaning |
|---|---|---|---|---|
| +0 | map dim = max DDA steps | | +72 | projection-plane dist = halfW/tan(halfFOV) |
| +4 | saved trig divisor (=+28) | | +76 | camera y-offset (a5) |
| +8 | wall height scale | | +80 | player X (Q16, cell=64 ⇒ cell = coord>>22) |
| +12 | screen width W | | +84 | player Y |
| +16 | screen height H | | +88 | player ANGLE (6·W units/circle; set by draw a4) |
| +20 | detail/column step (1..2) | | +92 | map ptr |
| +24 | ray count = W/detail | | +96/+100 | map w/h |
| +28 | 360° = 6·W | | +104..+164 | wall texture ptrs[16] by nibble id |
| +36 | halfFOV = W/2 (30°) | | +168 | wall shade byte[] ptr |
| +44/48/52 | 90/180/270° | | +172 | column buffer (8B: u32 dist; u8 texId; u8 texX) |
| +68 | horizon = a5 + H/2 | | +180/+196 | sprite capacity / sprite table ptr |
| | | | +184/+188/+192 | scratch descriptors A(+200)/B(+284), list head(+368) |

`changeInternalValues(screenW, screenH, wallScale, detail, yOffset, mapDim)`
(sub_41F0DA :21737) computes the derived fields only — arrays come from the
object. FOV = 60° (full circle 6·W angle units).

## Sprite record (84 bytes, dword indices)

[0] active · [1..3] world x/y/z · [4..5] w/h · [6..7] srcA x/y ·
[8..9] src w/h · [10..11] srcB x/y · [12..13] texture descr A/B ·
[14..15] screen x/y · [16] depth (sort key) · [17..18] projected w/h ·
[19..20] list prev/next. Ops: addMonster sets [0]=1,[4]=[8]=w,[5]=[9]=h;
removeSprite [0]=0; moveSprite [1..3]; setSpriteSize [4..5];
setSpritePos validates src rects against both images then writes [6..11].

## Renderer (`draw` → sub_41F4DB :21819)

1. `EB+80/84/88 = x,y,angle` (angle is Java-supplied per frame); clamp pos to map.
2. Cast W/detail rays from `angle − halfFOV`, step `detail` per ray
   (sub_41F7F2 :21907): two separated-axis DDA marches — horizontal grid
   lines test the **high nibble** (N/S wall id), vertical the **low nibble**
   (E/W id); nibble 0 = open. Nearest hit wins; fisheye correction
   `dist·cos(rayAngle−playerAngle)>>16`; record `{dist, texId, texX=hit&0x3F}`
   per column (textures 64 wide).
3. Wall strips (sub_41FEE7 :22152): height = `projDist·wallScale/dist`,
   centered on horizon; texture by id from EB+104[16]; per-wall shade byte
   from EB+168; scaled vertical-strip blit via target vtable slot +68.
   No floor/ceiling texturing (background shows through).
4. Sprites (sub_42055C :22446): view-space rotate by −angle (Q8 pre-shift),
   depth = forward component; scale = projDist/depth; screen pos from
   horizon + z; frustum cull; insert into depth-sorted linked list; draw
   far→near (sub_42080D :22515) with **per-column occlusion test** against
   the wall column buffer (`sprite.depth >= wallDist[col]` → skip column).

## isThereAWall / castRay

- `isThereAWall(x, y)` (sub_41F5B9 :21848): cell = `(coord>>16)/64`; true if
  any of the 4 surrounding half-edges has nibble 0 (tests *walkability*).
- `castRay(x, y, angle, int[≥6] out)` (sub_428962 :27265): one DDA ray at an
  explicit angle (does NOT touch EB+88); writes
  `{hitX, hitY, rawDist, correctedDist, wallTexId, texX}`; pushes 1 (success).

## Fixed-point/trig conventions

World Q16, cell 64 units (cell index = `coord>>22`). Angle unit: full circle
= 6·W; convert to the 2048-step cos table by `(angle<<11)/(6W)` (canonical
rescales via sub_41CB68). cos = sub_41C972, sin(a) = cos(a−512), Q16
amplitude. Textures are 8-bit palette-index, 64 px wide — our port samples
the decoded ABGR (`inst.pixels`) like the FX kernels.

## MutantAlert usage (direct call sites)

moveSprite ×14, setSpritePos ×7, setSpriteSize ×6, draw ×2, removeSprite ×2,
isThereAWall ×1; init path (changeInternalValues/addMonster/castRay) goes
through the class's bytecode wrappers.
