//! exen.Image — native funcs_407AA2[] indices 15..29
//!
//! Hash 0x23c5e7e8. Pixel buffer + palette + bitmap decode.
//! Spec: docs/native_index_map.md. Each handler ports the corresponding
//! `sub_*` body from `reference/ref`.

const std = @import("std");
const core = @import("core");
const _h = @import("../_helpers.zig");
const interp = core.interp;
const bridge = core.bridge;

const Vm = interp.Vm;
const Handle = bridge.Handle;

pub const class_name: []const u8 = "Image";
pub const first_index: u32 = 15;
pub const last_index: u32 = 29;

// Image instance field hashes — verified against docs/extracted/exen_Image.md
// field_table (raw), slot → hash mapping:
//   slot 0  0xd0426be6   int      width
//   slot 1  0xd0425e87   int      height
//   slot 2  0xd042b3aa   int      depth
//   slot 3  0xa6f15ba5   byte[]   image_Data         (pixel buffer)
//   slot 4  0xa6f1230d   byte[]   image_imgT         (palette bytes OR 1bpp B&W buffer — dual use)
//   slot 5  0xfd9580df   ref      palette            (Palette object ref)
const FIELD_WIDTH: u32 = 0xd0426be6;
const FIELD_HEIGHT: u32 = 0xd0425e87;
const FIELD_DEPTH: u32 = 0xd042b3aa;
const FIELD_PIXEL_BUFFER: u32 = 0xa6f15ba5;
const FIELD_BW_BUFFER: u32 = 0xa6f1230d;       // alias: palette byte[] (image_imgT)
const FIELD_IMG_PALETTE_REF: u32 = 0xfd9580df; // Palette object reference (slot 5)

// ── [15] Image.updateNativePaletteFromJavaPalette — sub_426235 ──────────────
// Canonical body (reference/ref:25787):
//
//   __int16 __cdecl sub_426235(int a1, int a2) {     // a2 = `this`
//     if (!a2) return 0;
//     v5 = *(_DWORD *)(a2 + 40);                     // this.palette ref (slot ~10)
//     if (!v5) return 0;
//     v4 = v5 + 20;                                  // palette obj data area
//     v3 = *(_DWORD *)(a2 + 44);                     // image internal descriptor
//     v6 = *(_DWORD *)(v3 + 28);                     // palette bytes byte[]
//     if (v6) {
//       v7 = *(unsigned __int16 *)(v6 + 18);         // byte[] length
//       *(_DWORD *)(v4 + 68) = v6 + 20;              // device.palette_ptr = byte[] payload
//       *(_DWORD *)(v4 + 72) = v7;                   // device.palette_count
//       *(_DWORD *)(v4 + 76) = v3 + 24;              // device.palette_marker
//       (*(void (__cdecl **)(int, int))(v4 + 48))(v4, 64); // vtable[12](dev, 64) — palette-changed
//     } else {
//       *(_DWORD *)(v4 + 68) = 0;                    // clear device palette
//       *(_DWORD *)(v4 + 72) = 0;
//       *(_DWORD *)(v4 + 76) = 0;
//       if (*(_DWORD *)(v4 + 44) != 32)
//         (*(void (__cdecl **)(int, int))(v4 + 48))(v4, 16); // vtable[12](dev, 16) — palette-cleared
//     }
//     return 0;
//   }
//
// The canonical caches the palette ptr/count/marker into a device buffer and
// fires a vtable callback. In our architecture the renderer reads the palette
// lazily on each pixel via `paletteByteAtIndex` walking the same field chain
// (Image.image_imgT byte[] or Image.palette → Palette.bytes), so the device-
// side cache is unnecessary — every draw sees the freshest palette by
// construction.
//
// Our port therefore:
//   1. Mirrors the canonical's null-checks (this == 0 / palette source == 0)
//   2. Validates the palette chain exists (cheap heap lookups)
//   3. Returns 0 — matches canonical contract regardless of branch
//
// Side effects (palette synced to renderer) are implicit. Performance
// trade-off: per-pixel chain walk vs canonical's cached pointer — accepted
// for simplicity until profiling shows it's hot.
fn updateNativePaletteFromJavaPalette(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    if (this == 0) return 0;
    const inst = vm.heap.get(this) orelse return 0;

    // Two paths exist on the Image for palette storage. Either being
    // non-null counts as "palette source present" for canonical's branch.
    const palette_obj_h = inst.field_map.get(FIELD_IMG_PALETTE_REF) orelse 0;
    const palette_bytes_h = inst.field_map.get(FIELD_BW_BUFFER) orelse 0;

    if (palette_obj_h == 0 and palette_bytes_h == 0) {
        // Canonical's else-branch: clear device palette + maybe fire
        // palette-cleared callback. Our renderer's paletteByteAtIndex
        // falls back to "0" for any out-of-range read, so the "cleared"
        // state is already represented.
        return 0;
    }

    // Canonical's if-branch: device gets a palette-changed callback.
    // We don't have a device callback to fire, but we touch the heap
    // entries to surface any stale-handle bugs at trace time.
    if (palette_obj_h != 0) _ = vm.heap.get(palette_obj_h);
    if (palette_bytes_h != 0) _ = vm.heap.get(palette_bytes_h);
    return 0;
}

// ── [16] Image.getNativePaletteSize — sub_426302 ────────────────────────────
// Canonical body (reference/ref:25823):
//   __int16 __cdecl sub_426302(_DWORD *a1, int a2) {  // a2 = this
//     if (a2) {
//       v3 = *(_DWORD *)(a2 + 40);          // this.palette_obj
//       if (v3) *a1 = *(_DWORD *)(v3 + 92); // return palette_obj.size (slot at +92)
//       else    *a1 = 0;
//       return 1;
//     }
//     *a1 = 0; return 1;
//   }
//
// Returns the number of entries in the native palette table. For our
// 8-bpp Manuf.* devices that's always 256. The canonical reads the
// count from a slot on the Palette object (offset +92, presumably
// populated by `updateNativePaletteFromJavaPalette` from the byte[]
// length); we just return 256 directly since the depth is fixed.
//
// Was previously bound to `height` due to positional-pairing drift.
// The real Image.getHeight() is a bytecode method on method_table
// row 23 (no native_idx); the gamelet uses INVOKEVIRTUAL on that.
fn getNativePaletteSize(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    args.setReturn(0);
    if (this == 0) return 1;
    const inst = vm.heap.get(this) orelse return 1;
    if ((inst.field_map.get(FIELD_IMG_PALETTE_REF) orelse 0) == 0 and
        (inst.field_map.get(FIELD_BW_BUFFER) orelse 0) == 0) return 1;
    args.setReturn(256);
    return 1;
}

// ── [17] Image.updateJavaPaletteFromNativePalette — sub_426357 ──────────────
// Canonical body (reference/ref:25844): the INVERSE of idx 15.
//   if (!this) return 0;
//   v6 = this.palette_obj;          if (!v6) return 0;
//   v5 = palette_obj.data_area;
//   v4 = this.descriptor;            v7 = descriptor.palette_bytes;
//   for (i = 0; i < length; ++i)
//     palette_bytes[i] = palette_obj.cached_palette[i];   // copy native → Java
//   free(palette_obj.cached_buf);
//   palette_obj.cached_buf  = new_buf;
//   palette_obj.cached_size = length;
//   palette_obj.cached_mark = marker;
//   return 0;
//
// Pulls the device's native palette back into the Java-side byte[].
// Canonical does this when the gamelet wants to read its own palette
// (e.g. for save-state serialization). In our model the Java byte[]
// IS the source of truth — the renderer reads from it lazily. The
// canonical's native-side cache doesn't exist for us, so there's
// nothing to copy back: the byte[] is already up-to-date. No-op
// return 0, matching canonical contract.
//
// Was previously bound to `depth` due to positional-pairing drift.
// The real Image.depth getter is a bytecode method (method_table
// row outside the native range).
fn updateJavaPaletteFromNativePalette(_: *Vm, _: bridge.ArgFrame) i16 {
    return 0;
}

// ── [22] sub_426210 — canonical-exact, name not yet verified ────────────────
// Canonical body (reference/ref:25773):
//     __int16 __cdecl sub_426210(_DWORD *a1) { *a1 = 88; return 1; }
// Returns 88 in the native return slot, no state mutation.
//
// Strings region has multiple argc=0→int candidates that could match
// ── [22] Image.getSizeOfEXimgStruct() → int — sub_426210 ───────────────────
// Canonical body (reference/ref near 26200):
//     __int16 __cdecl sub_426210(_DWORD *a1) { *a1 = 88; return 1; }
// Returns the literal constant 88 = `sizeof(EXimg)`, the canonical
// 22-dword the platform image descriptor struct: 4-byte pixel ptr + 4-byte
// w + 4-byte h + 4-byte depth + 4-byte buffer + 4-byte vtable + ...
// totaling 88 bytes. Used by the gamelet as a pre-allocation query
// before laying out raw byte buffers that mirror an EXimg.
//
// Triple-verified: method_table row 9 (native_idx 22, argc=0,
// static-instance) → strings region row 15 `getSizeOfEXimgStruct: () → int`
// positionally, and the literal 88 fits the EXimg struct size.
fn getSizeOfEXimgStruct(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(88);
    return 1;
}

// ── [23] Image.getManufDisplayHeaderSize() → int — sub_426222 ──────────────
// Canonical body (reference/ref near 26210):
//     __int16 __cdecl sub_426222(int *a1) { *a1 = sub_4022C4(); return 1; }
//     int sub_4022C4() { return 0; }
// Returns the manufacturer-display-header size, hardwired to 0 on this
// device (no per-manufacturer header prefix on image resources). For
// devices that DO carry a manuf header, sub_4022C4 would return its size
// so the image loader knows how many bytes to skip before the raw EXimg.
//
// Triple-verified: method_table row 10 (native_idx 23, argc=0,
// static-instance) → strings region row 16 `getManufDisplayHeaderSize:
// () → int` positionally, and `sub_4022C4` returns 0 on this device.
fn getManufDisplayHeaderSize(_: *Vm, args: bridge.ArgFrame) i16 {
    args.setReturnI32(0);
    return 1;
}

// ── [24] init(image, w, h, d) — sub_4267F6 ──────────────────────────────────
// Stash dimensions on the Image. No pixel buffer here:
// sprite Images get pixels via image.TransformBitmapFromResExed (PNG
// decode); offscreen target Images get them lazily on first
// Graphics-target use. We DO resize the gamelet-allocated pixel buffer
// here because the gamelet allocates it before knowing the depth.
fn init(vm: *Vm, args: bridge.ArgFrame) i16 {
    const image_handle = args.this();
    const w = args.getU32(1);
    const h = args.getU32(2);
    const d_raw = args.getU32(3);
    const d: u32 = if (d_raw == 0) 8 else d_raw; // 0 == device default
    const inst = vm.heap.get(image_handle) orelse return 0;
    inst.field_map.put(FIELD_WIDTH, w) catch {};
    inst.field_map.put(FIELD_HEIGHT, h) catch {};
    inst.field_map.put(FIELD_DEPTH, d) catch {};
    inst.pix_w = w;
    inst.pix_h = h;

    const bytes_per_px: u32 = (d + 7) / 8;
    const need: usize = @as(usize, w) * @as(usize, h) * @as(usize, bytes_per_px);
    if (need == 0) return 0;
    const buf_handle = inst.field_map.get(FIELD_PIXEL_BUFFER) orelse return 0;
    const buf_inst = vm.heap.get(buf_handle) orelse return 0;
    const have = if (buf_inst.bytes) |b| b.len else 0;
    if (have >= need) return 0;
    // The backing buffer is Instance-owned storage: NEWARRAY allocates it from
    // the object heap, and freeInstance frees it there — so the resize must use
    // vm.heap.allocator (NOT vm.allocator, the FBA VM arena, whose `free`
    // asserts on pointers it doesn't own).
    const new_buf = vm.heap.allocator.alloc(u8, need) catch return 0;
    @memset(new_buf, 0);
    const old = buf_inst.bytes;
    buf_inst.bytes = new_buf;
    buf_inst.fields[0] = @intCast(new_buf.len);
    if (old) |o| if (vm.heap.freeable(@intFromPtr(o.ptr), o.len)) vm.heap.allocator.free(o);
    return 0;
}

// ── [26] TransformBitmapFromResExed(image, resource) — sub_4265CA ───────────
// Decode PNG bytes from the resource into the Image's pixel buffer.
// Canonical signature: argc=2 = (Resource res, byte mode). The `mode`
// byte is canonical's codec/depth selector consumed by sub_418D0A's
// dispatch — our `decodeImageFromResource` auto-detects PNG via signature
// scan, so the byte is accepted but unused here. Match canonical arity
// for trace clarity + future-proofing.
// Empirical mode/payload observations across our 3 corpus gamelets:
//   Terminator: mode=0x01 always, payload first-4 = 89 50 4E 47 (PNG sig) always
//   Crash:      mode=0x01 always, payload PNG-signature always
//   Pikubi:     mode=0x01 always, payload PNG-signature always
// Canonical `sub_418D0A` detects PNG by signature via `sub_41D836` and
// routes to `sub_41E504 → sub_41E45F` regardless of mode value, so for
// these payloads the mode byte is effectively unused by canonical's PNG
// path. Dropping it is safe for the current corpus.
fn transformBitmapFromResExed(vm: *Vm, args: bridge.ArgFrame) i16 {
    const image_handle = args.this();
    const res_handle = args.handle(1);
    // args[2] = mode — canonical auto-detects via PNG signature, unused
    const raw = vm.exn_raw orelse return 0;
    const res = _h.loadResource(vm, res_handle) orelse return 0;
    const image_inst = vm.heap.get(image_handle) orelse return 0;

    // Free any old decoded raster / index buffers owned by this Image.
    // Both are vm.allocator-owned (like pixels_owned) — free them the same
    // way so per-frame re-decodes don't leak within the VM arena.
    if (image_inst.pixels_owned) |p| vm.allocator.free(p);
    if (image_inst.pixel_indices) |p| vm.allocator.free(p);
    image_inst.pixels = null;
    image_inst.pixels_owned = null;
    image_inst.pixel_indices = null;

    var img_state = core.exn.imageInit(image_inst.pix_w, image_inst.pix_h, 0);
    const ok = core.exn.decodeImageFromResource(&img_state, res, raw, vm.allocator) catch false;
    if (ok and img_state.pixels != null) {
        image_inst.pixels = img_state.pixels.?;
        image_inst.pixels_owned = img_state.pixels.?;
        img_state.pixels = null;
        // Retain the source palette-index buffer so index-based transparency
        // (setTransparentColor / setPaletteAlpha) can skip the transparent
        // index on this PNG-decoded image — see Graphics.drawImage /
        // AnimBitmap.draw.
        if (img_state.indices) |ix| {
            image_inst.pixel_indices = ix;
            img_state.indices = null;
        }
    }
    img_state.deinit(vm.allocator);
    return 0;
}

// ── Image transparency quartet (idx 18..21) — canonical port ───────────────
//
// Canonical Palette descriptor (Image+40 in canonical, Image instance in our
// model) has these slots:
//   desc+84  (sub_418EB8/EC3's a1+64)  — byte at palette-alpha/transparent slot
//   desc+88  (canonical sub_426419)    — bool: alt-mode discriminator
//   desc+100 (canonical sub_426419)    — int:  transparent-color value
//   desc+68  (canonical sub_418E8A)    — function pointer: mode-setter (vtable)
//
// Mode byte (last value passed to vtable[mode-setter]):
//   16 = transparency disabled, base path
//   32 = palette-alpha set, base path
//   48 = transparency enabled, color = desc+100
//   64 = transparency disabled, alt path  (when desc+88 truthy)
//   80 = palette-alpha set,    alt path  (when desc+88 truthy)
//
// Synthetic field hashes (mirror the canonical descriptor slots — we don't
// have a separate Palette descriptor at Image+40, so we store on the Image
// instance's field_map directly):
const FIELD_IMG_TR_COLOR: u32 = 0xC0FFEE01; // canonical desc+100
const FIELD_IMG_PAL_ALPHA: u32 = 0xC0FFEE02; // canonical desc+84
const FIELD_IMG_TR_MODE: u32 = 0xC0FFEE03; // last mode byte passed to vtable
const FIELD_IMG_TR_ALT: u32 = 0xC0FFEE04; // canonical desc+88 alt-mode flag

// ── [18] Image.setTransparentColor(int color) — sub_426419 ─────────────────
// Canonical body (reference/ref:25874):
//   if (!this) return 0;
//   v3 = *(this + 40);  if (!v3) return 0;       // palette descriptor
//   *(v3 + 100) = arg;                            // store color
//   if (arg) vtable_modesetter(v3+20, 48);        // mode 48 = transparency on
//   else if (*(v3+88)) vtable_modesetter(v3+20, 64);  // alt-clear
//   else               vtable_modesetter(v3+20, 16);  // base-clear
//   return 0;
fn setTransparentColor(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const color = args.getU32(1);
    const inst = vm.heap.get(this) orelse return 0;
    inst.field_map.put(FIELD_IMG_TR_COLOR, color) catch {};
    const mode: u32 = if (color != 0)
        48
    else if ((inst.field_map.get(FIELD_IMG_TR_ALT) orelse 0) != 0)
        64
    else
        16;
    inst.field_map.put(FIELD_IMG_TR_MODE, mode) catch {};
    return 0;
}

// ── [19] Image.setPaletteAlpha(byte alpha) — sub_4264A3 ────────────────────
// Canonical body (reference/ref:25899):
//   if (!this) return 0;
//   v3 = *(this + 40);  if (!v3) return 0;
//   sub_418EC3(v3+20, (BYTE)arg);                 // write desc+84 + set mode
//   return 0;
//
// sub_418EC3(a1, a2):
//   *(a1+64) = a2;                                // a1=v3+20 → writes v3+84
//   if (*(a1+68)) vtable_modesetter(a1, 80);      // alt-on
//   else          vtable_modesetter(a1, 32);      // base-on
fn setPaletteAlpha(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const alpha = args.getU32(1);
    const inst = vm.heap.get(this) orelse return 0;
    inst.field_map.put(FIELD_IMG_PAL_ALPHA, alpha & 0xFF) catch {};
    const mode: u32 = if ((inst.field_map.get(FIELD_IMG_TR_ALT) orelse 0) != 0)
        80
    else
        32;
    inst.field_map.put(FIELD_IMG_TR_MODE, mode) catch {};
    return 0;
}

// ── [20] Image.getTransparentColor() → int — sub_4264ED ────────────────────
// Canonical body (reference/ref:25913):
//   if (this) {
//     v3 = *(this + 40);
//     if (v3) *a1 = sub_418EB8(v3+20);            // returns *(v3+84) = alpha slot
//     else    *a1 = 0;
//   } else *a1 = 0;
//   return 1;
//
// Canonical quirk: this returns the byte at desc+84 (palette-alpha slot),
// NOT the color stored at desc+100 by setTransparentColor. The two writes
// land in different slots — match canonical bytes, not the name.
fn getTransparentColor(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    args.setReturn(0);
    const inst = vm.heap.get(this) orelse return 1;
    args.setReturn(inst.field_map.get(FIELD_IMG_PAL_ALPHA) orelse 0);
    return 1;
}

// ── [21] Image.removeTransparentColor() → void — sub_426548 ────────────────
// Canonical body (reference/ref:25933):
//   if (!this) return 0;
//   v3 = *(this + 40);  if (!v3) return 0;
//   sub_418E8A(v3+20);
//   return 0;
//
// sub_418E8A(a1):
//   if (*(a1+68)) vtable_modesetter(a1, 64);      // alt-clear
//   else          vtable_modesetter(a1, 16);      // base-clear
//
// Does NOT clear the stored color at desc+100 — only flips the mode flag.
fn removeTransparentColor(vm: *Vm, args: bridge.ArgFrame) i16 {
    const inst = vm.heap.get(args.this()) orelse return 0;
    const mode: u32 = if ((inst.field_map.get(FIELD_IMG_TR_ALT) orelse 0) != 0)
        64
    else
        16;
    inst.field_map.put(FIELD_IMG_TR_MODE, mode) catch {};
    return 0;
}

// ── [25] Image.transformToSystemPalette() — sub_426589 ─────────────────────
// Canonical: `sub_418DF7(palette+20)` — decode indexed pixel bytes through
// the palette into the device's ABGR raster. In our model we lazy-decode
// in the renderer via paletteByteAtIndex, but Pikubi/Crash do call this
// explicitly to materialize their main offscreen's ABGR right after
// loading a palette. Bound here (was misbound to idx 27 previously).
fn transformToSystemPalette(vm: *Vm, args: bridge.ArgFrame) i16 {
    _h.doTransformToSystemPalette(vm, args.this());
    return 0;
}

// ── PNG IHDR helper — used by idx 27 and 29 ────────────────────────────────
// Mirrors canonical sub_41D987 (reference/ref:20999): walks PNG chunks
// until IHDR, reads bit_depth + color_type, returns the canonical
// bit-depth selector:
//   color_type != 3 (not paletted) → 8
//   palette+bit_depth==4 + mode≠0 → 4
//   otherwise                     → 8
// (Returns 0 if input isn't a recognizable PNG — caller treats as "use 8".)
fn pngBitDepth(bytes: []const u8, mode: u8) u32 {
    if (bytes.len < 8 + 8 + 13) return 0; // 8-byte sig + chunk hdr + IHDR
    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] != 0x89 or bytes[1] != 0x50 or bytes[2] != 0x4E or bytes[3] != 0x47) return 0;
    var pos: usize = 8;
    while (pos + 8 <= bytes.len) {
        const chunk_len: usize =
            (@as(usize, bytes[pos]) << 24) |
            (@as(usize, bytes[pos + 1]) << 16) |
            (@as(usize, bytes[pos + 2]) << 8) |
            @as(usize, bytes[pos + 3]);
        const t0 = bytes[pos + 4];
        const t1 = bytes[pos + 5];
        const t2 = bytes[pos + 6];
        const t3 = bytes[pos + 7];
        if (t0 == 'I' and t1 == 'H' and t2 == 'D' and t3 == 'R') {
            // IHDR payload (13 bytes): width(4) height(4) bit_depth(1)
            // color_type(1) compression(1) filter(1) interlace(1)
            const payload = pos + 8;
            if (payload + 10 > bytes.len) return 0;
            const bit_depth = bytes[payload + 8];
            const color_type = bytes[payload + 9];
            if (color_type != 3) return 8;
            if (bit_depth == 4 and mode != 0) return 4;
            return 8;
        }
        pos += 8 + chunk_len + 4; // header + payload + CRC
    }
    return 0;
}

// ── [27] Image.GetBitmapDepthFromResExed(Resource, byte mode) → int ────────
// Canonical body (reference/ref:25980):
//   v2 = arg[0];                              // Resource handle
//   v3 = { v2.base + v2.pos, 0, v2.length };  // file-data descriptor
//   *arg[0] = sub_418CDF(v3, arg[1] & 0xFF);  // PNG IHDR parse → int
//   return 1;
//
// STATIC method — pre-queries PNG bit depth so the gamelet can allocate
// the indexed buffer at the right size before calling Image.<init> +
// TransformBitmapFromResExed. Returns 4 only for palette+bit_depth==4
// PNGs with mode≠0; else 8 (canonical default).
fn getBitmapDepthFromResExed(vm: *Vm, args: bridge.ArgFrame) i16 {
    const res_handle = args.handle(0);
    const mode = args.getU32(1);
    args.setReturn(0);
    const raw = vm.exn_raw orelse return 1;
    const res = _h.loadResource(vm, res_handle) orelse return 1;
    if (res.length <= res.position) return 1;
    const start: usize = @as(usize, res.base) + @as(usize, res.position);
    const end: usize = @as(usize, res.base) + @as(usize, res.length);
    if (end > raw.len or start >= end) return 1;
    args.setReturn(pngBitDepth(raw[start..end], @truncate(mode)));
    return 1;
}

// ── [28] Image.TransformBitmapFromByteArray(byte[] payload, byte mode) ─────
// Canonical body (reference/ref:25994):
//   v4 = arg[0] + 20;                           // byte[] payload (skip header)
//   v3 = sub_426785(this);                      // descriptor lookup
//   v5 = { 0, v4, 0 };                          // memory-data descriptor
//   sub_418D0A(v3, v5, arg[1] & 0xFF);          // decode INTO descriptor
//
// INSTANCE method — byte[] variant of TransformBitmapFromResExed (idx 26).
// Where idx 26 decodes from a Resource (file-backed offsets), idx 28
// decodes from an in-memory byte[] payload (canonical's `+20` skip is
// the byte[] object header — in our model `inst.bytes` already points
// at the payload, no offset needed). Same PNG-decode endpoint.
fn transformBitmapFromByteArray(vm: *Vm, args: bridge.ArgFrame) i16 {
    const this = args.this();
    const payload_handle = args.handle(1);
    // args[2] = mode — canonical's `mode` discriminates depth/codec — our PNG decoder auto-detects
    const image_inst = vm.heap.get(this) orelse return 0;
    const payload_inst = vm.heap.get(payload_handle) orelse return 0;
    const payload = payload_inst.bytes orelse return 0;
    if (payload.len == 0) return 0;

    if (image_inst.pixels_owned) |p| vm.allocator.free(p);
    image_inst.pixels = null;
    image_inst.pixels_owned = null;

    // Path 1 — PNG payload (auto-detected by signature): decode straight to
    // ABGR pixels, like the sprite/resource path.
    var img_state = core.exn.imageInit(image_inst.pix_w, image_inst.pix_h, 0);
    const ok = core.exn.decodeImageFromBytes(&img_state, payload, vm.allocator) catch false;
    if (ok and img_state.pixels != null) {
        image_inst.pixels = img_state.pixels.?;
        image_inst.pixels_owned = img_state.pixels.?;
        image_inst.pix_w = img_state.width;
        image_inst.pix_h = img_state.height;
        image_inst.field_map.put(FIELD_WIDTH, img_state.width) catch {};
        image_inst.field_map.put(FIELD_HEIGHT, img_state.height) catch {};
        img_state.pixels = null;
        img_state.deinit(vm.allocator);
        return 0;
    }
    img_state.deinit(vm.allocator);

    // Path 2 — raw ExEn codec bitstream (NOT PNG-wrapped). This is how
    // bitmap FONTS are supplied (e.g. Pikubi2's 840×8 glyph atlas, an
    // 8-bit indexed image compressed with codec 1). Canonical sub_4266A1 →
    // sub_418D0A decodes the payload into the image's indexed buffer, then
    // the palette (loaded via updateNativePaletteFromJavaPalette) + the
    // transparent index (setPaletteAlpha) turn it into visible glyphs.
    //
    // The codec is selected by the high nibble of byte 0 — identical to the
    // PNG-IDAT dispatch in png.decodePngToAbgr. We decode to indexed bytes,
    // stash them in the pixel-buffer object, and clear `pixels` so the next
    // drawImage runs doTransformToSystemPalette over them. Without this the
    // atlas stayed all-zero and every glyph drew nothing → no on-screen text.
    const codec_id: u8 = payload[0] >> 4;
    const decoded: []u8 = switch (codec_id) {
        1 => core.codec.decodeCodec1(vm.heap.allocator, payload) catch return 0,
        2 => core.codec.decodeCodec2(vm.heap.allocator, payload) catch return 0,
        3 => core.codec.decodeCodec3(vm.heap.allocator, payload) catch return 0,
        4 => core.codec.decodeCodec4(vm.heap.allocator, payload) catch return 0,
        else => return 0, // codec 5 (LZSS) lives in png.zig; no font uses it
    };
    const total: usize = @as(usize, image_inst.pix_w) * @as(usize, image_inst.pix_h);

    // The codec output is either one index byte per pixel (`decoded.len ==
    // total`), or — for 1-bit monochrome bitmap FONTS — a packed bitmap
    // (`decoded.len * 8 ≈ total`, i.e. codec header `a == width * 1bpp`).
    // The packed stream is row-major, MSB-first: pixel i is bit i of the
    // stream. Expand to one index per pixel (0 = bg/transparent, 1 = glyph)
    // so the palette + setPaletteAlpha path renders real glyphs instead of
    // garbage / an all-zero atlas.
    var indexed: []u8 = decoded;
    if (total > 0 and decoded.len < total and decoded.len * 8 >= total) {
        const exp = vm.heap.allocator.alloc(u8, total) catch {
            vm.heap.allocator.free(decoded);
            return 0;
        };
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const byte = decoded[i >> 3];
            exp[i] = (byte >> @intCast(7 - (i & 7))) & 1;
        }
        vm.heap.allocator.free(decoded);
        indexed = exp;
    }
    const pbuf_h = image_inst.field_map.get(FIELD_PIXEL_BUFFER) orelse {
        vm.heap.allocator.free(indexed);
        return 0;
    };
    const pbuf = vm.heap.get(pbuf_h) orelse {
        vm.heap.allocator.free(indexed);
        return 0;
    };
    if (pbuf.bytes) |old| if (vm.heap.freeable(@intFromPtr(old.ptr), old.len)) vm.heap.allocator.free(old);
    pbuf.bytes = indexed;
    pbuf.fields[0] = @intCast(indexed.len);
    // Not a composited render target — let the palette decode run.
    image_inst.is_render_target = false;
    if (image_inst.pixel_indices) |pi| if (vm.heap.freeable(@intFromPtr(pi.ptr), pi.len)) vm.heap.allocator.free(pi);
    image_inst.pixel_indices = null;
    image_inst.pixels = null;
    return 0;
}

// ── [29] Image.GetBitmapDepthFromByteArray(byte[] payload, byte mode) → int ─
// Canonical body (reference/ref:26016):
//   v2 = { 0, arg[0] + 20, 0 };               // byte[] payload (skip header)
//   *arg[0] = sub_418CDF(v2, arg[1] & 0xFF);  // PNG IHDR parse → int
//   return 1;
//
// STATIC method — byte[] variant of GetBitmapDepthFromResExed (idx 27).
// Walks PNG chunks in `payload.bytes` until IHDR, returns the canonical
// bit depth (4 or 8) for downstream allocation sizing.
fn getBitmapDepthFromByteArray(vm: *Vm, args: bridge.ArgFrame) i16 {
    const payload_handle = args.handle(0);
    const mode = args.getU32(1);
    args.setReturn(0);
    const payload_inst = vm.heap.get(payload_handle) orelse return 1;
    const bytes = payload_inst.bytes orelse return 1;
    args.setReturn(pngBitDepth(bytes, @truncate(mode)));
    return 1;
}

pub const entries = .{
    // Palette-sync trio (push / query / pull)
    .{ 15, "updateNativePaletteFromJavaPalette", updateNativePaletteFromJavaPalette },
    .{ 16, "getNativePaletteSize",               getNativePaletteSize },
    .{ 17, "updateJavaPaletteFromNativePalette", updateJavaPaletteFromNativePalette },
    // Transparency / palette-alpha (newly bound canonical mapping)
    .{ 18, "setTransparentColor",                setTransparentColor },
    .{ 19, "setPaletteAlpha",                    setPaletteAlpha },
    .{ 20, "getTransparentColor",                getTransparentColor },
    .{ 21, "removeTransparentColor",             removeTransparentColor },
    // Constants (canonical body proven, name ambiguous)
    .{ 22, "getSizeOfEXimgStruct",               getSizeOfEXimgStruct },
    .{ 23, "getManufDisplayHeaderSize",          getManufDisplayHeaderSize },
    // Allocation + transformation
    .{ 24, "<init>",                             init },
    .{ 25, "transformToSystemPalette",           transformToSystemPalette },
    // Bitmap decode family (idx 26 verified; 27/28/29 are canonical-body-faithful but names unverified)
    .{ 26, "TransformBitmapFromResExed",         transformBitmapFromResExed },
    .{ 27, "GetBitmapDepthFromResExed",          getBitmapDepthFromResExed },
    .{ 28, "TransformBitmapFromByteArray",       transformBitmapFromByteArray },
    .{ 29, "GetBitmapDepthFromByteArray",        getBitmapDepthFromByteArray },
};

pub const handle = bridge.canonical(entries);
