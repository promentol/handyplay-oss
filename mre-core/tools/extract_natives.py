#!/usr/bin/env python3
"""Extract the `vm_*` / `mremu_*` native symbols each .vxp game uses.

These names are string literals inside the binary (passed to vm_get_sym_entry),
so no decompiler is needed — we just decompress the image and scan for the strings.
For each game we write game_sources/<name>.natives.txt listing the natives, marking
which are MISSING (not registered in core/natives.zig) so we know what to implement.

Usage: python3 tools/extract_natives.py
"""
import os
import re
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAMES = os.path.join(ROOT, "games")
OUT = os.path.join(ROOT, "game_sources")
NATIVES_ZIG = os.path.join(ROOT, "core", "natives.zig")

NAME_RE = re.compile(rb"\b(?:vm|mremu)_[a-z0-9_]{2,}\b")
# names that are gamelet entry points / decompiler artifacts, not host natives
NOT_NATIVES = {"vm_main", "vm_image_p", "vm_get_sym_entry"}


def vxp_image(data: bytes) -> bytes:
    """Return the bytes to scan: raw ELF as-is, or the decompressed ADS image."""
    if len(data) >= 4 and data[1:4] == b"ELF":
        return data
    if len(data) >= 12 and data[0] == 0x78:  # zlib / ADS
        try:
            tags_offset = struct.unpack_from("<I", data, len(data) - 12)[0]
            info_size = struct.unpack_from("<I", data, tags_offset - 4)[0]
            if info_size == 36:
                info = struct.unpack_from("<9I", data, tags_offset - 4 - 36)
                ro_off, ro_size, _org_ro, rw_off, rw_size, _org_rw, *_ = info
                ro = zlib.decompress(data[ro_off:ro_off + ro_size])
                rw = zlib.decompress(data[rw_off:rw_off + rw_size])
                return ro + rw
        except Exception:
            pass
        # fall back: decompress whatever zlib stream starts at byte 0
        try:
            return zlib.decompressobj().decompress(data)
        except Exception:
            return data
    return data


def registered_natives() -> set:
    names = {"vm_get_sym_entry"}
    try:
        src = open(NATIVES_ZIG).read()
        names |= set(re.findall(r'r\.rs?\("([a-z0-9_]+)"', src))
    except OSError:
        pass
    return names


def main():
    os.makedirs(OUT, exist_ok=True)
    registered = registered_natives()
    all_missing = {}

    games = sorted(f for f in os.listdir(GAMES) if f.lower().endswith(".vxp"))
    for game in games:
        data = open(os.path.join(GAMES, game), "rb").read()
        img = vxp_image(data)
        found = sorted({m.decode() for m in NAME_RE.findall(img)} - NOT_NATIVES)
        missing = [n for n in found if n not in registered]

        stem = os.path.splitext(game)[0]
        out_path = os.path.join(OUT, stem + ".natives.txt")
        with open(out_path, "w") as f:
            f.write(f"# {game}: {len(found)} natives used, "
                    f"{len(missing)} MISSING\n\n")
            if missing:
                f.write("## MISSING (not implemented in core/natives.zig)\n")
                for n in missing:
                    f.write(f"  {n}\n")
                f.write("\n")
            f.write("## all natives used\n")
            for n in found:
                tag = "  MISSING" if n in missing else ""
                f.write(f"  {n}{tag}\n")

        for n in missing:
            all_missing.setdefault(n, []).append(stem)
        print(f"{game:42s} {len(found):3d} used, {len(missing):2d} missing")

    # global summary: which missing natives are wanted by the most games
    print("\n=== MISSING natives across all games (by game count) ===")
    for n, gs in sorted(all_missing.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(gs):2d}x  {n}")


if __name__ == "__main__":
    main()
