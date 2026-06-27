#!/usr/bin/env python3
"""Decompile every .vxp in games/ via dogbolt.org (Binary Ninja only) into
game_sources/<slug>.c, then extract the vm_*/mremu_* natives each game uses into
game_sources/<slug>.natives.txt (marking which are missing from core/natives.zig).

Trimmed from the user's multi-decompiler dogbolt script: one decompiler, a per-game
loop, native extraction. Stdlib only (urllib) — no `requests` dependency.

Usage: python3 tools/decompile_games.py [--only NAME] [--force]
"""
import argparse
import hashlib
import json
import os
import re
import struct
import time
import urllib.request
import uuid
import gzip
import zlib

APP_BASE = 0x100000  # where the loader maps the app (offset_mem)

DECOMPILER = "BinaryNinja"
RETRY_SLEEP = 20
RETRY_COUNT = 30
REQUESTS_PER_DECOMPILER = 3
UA = "mre-player-decompile/1.0"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAMES = os.path.join(ROOT, "games")
OUT = os.path.join(ROOT, "game_sources")
CACHE = os.path.expanduser("~/.cache/dogbolt/binary_id.txt")
NATIVES_ZIG = os.path.join(ROOT, "core", "natives.zig")

NAME_RE = re.compile(rb"\b(?:vm|mremu)_[a-z0-9_]{2,}\b")
NOT_NATIVES = {"vm_main", "vm_image_p", "vm_get_sym_entry"}


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read()
    # dogbolt serves the decompiled .c gzip-compressed; urllib (unlike requests)
    # doesn't auto-decompress, so handle it here.
    if r.headers.get("Content-Encoding") == "gzip" or body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return body


def http_post(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data or b"", method="POST",
                                 headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def ads_image(data):
    """Decompress an ADS (.vxp zlib) into its raw RO+RW code image, or None."""
    if not (len(data) >= 12 and data[0] == 0x78):
        return None
    try:
        tags_off = struct.unpack_from("<I", data, len(data) - 12)[0]
        if struct.unpack_from("<I", data, tags_off - 4)[0] != 36:
            return None
        info = struct.unpack_from("<9I", data, tags_off - 4 - 36)
        ro_off, ro_size, rw_off, rw_size = info[0], info[1], info[3], info[4]
        return (zlib.decompress(data[ro_off:ro_off + ro_size]) +
                zlib.decompress(data[rw_off:rw_off + rw_size]))
    except Exception:
        return None


def wrap_elf(image, base=APP_BASE):
    """Wrap a raw ARM code image in a minimal ELF32-LE so Binary Ninja loads it
    as ARM (ADS games are raw code, not ELF)."""
    data_off = 0x1000
    eh = struct.pack(
        "<16sHHIIIIIHHHHHH",
        b"\x7fELF\x01\x01\x01" + b"\x00" * 9,  # e_ident: ELF32, LSB, v1
        2, 40, 1,            # ET_EXEC, EM_ARM, EV_CURRENT
        base, 52, 0, 0,      # entry, phoff, shoff, flags
        52, 32, 1, 0, 0, 0,  # ehsize, phentsize, phnum, shentsize, shnum, shstrndx
    )
    ph = struct.pack("<IIIIIIII", 1, data_off, base, base,
                     len(image), len(image), 7, 0x1000)  # PT_LOAD, RWX
    out = bytearray(data_off)
    out[0:len(eh)] = eh
    out[52:52 + len(ph)] = ph
    return bytes(out) + image


def upload_bytes(data):
    """ELF as-is; ADS -> decompress + wrap in ARM ELF; else raw."""
    if len(data) >= 4 and data[1:4] == b"ELF":
        return data
    img = ads_image(data)
    return wrap_elf(img) if img else data


VXP2ELF = os.path.join(ROOT, "zig-out", "bin", "vxp2elf")


def upload(path):
    """Multipart upload; return binary id (cached by sha256)."""
    raw = open(path, "rb").read()
    if len(raw) >= 4 and raw[1:4] == b"ELF":
        data = raw  # already an ELF
    else:
        # ADS/zlib: use the Zig loader to emit a properly relocated ELF.
        import subprocess
        tmp = os.path.join("/tmp", "vxp2elf_" + os.path.basename(path) + ".elf")
        r = subprocess.run([VXP2ELF, path, tmp], capture_output=True)
        if r.returncode != 0 or not os.path.exists(tmp):
            print(f"  vxp2elf failed: {r.stderr.decode(errors='ignore').strip()[:120]}")
            return None
        data = open(tmp, "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    if len(data) > 2 * 1024 * 1024:
        print(f"  SKIP (>2MB): {os.path.basename(path)}")
        return None

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    if os.path.exists(CACHE):
        for line in open(CACHE):
            if line.startswith(f"sha256:{sha} "):
                return line.strip().split(" ")[1]

    boundary = "----" + uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{os.path.basename(path)}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    resp = http_post("https://dogbolt.org/api/binaries/", body,
                     {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    bid = json.loads(resp).get("id")
    with open(CACHE, "a") as f:
        f.write(f"sha256:{sha} {bid}\n")
    return bid


def registered_natives():
    names = {"vm_get_sym_entry"}
    try:
        names |= set(re.findall(r'r\.rs?\("([a-z0-9_]+)"', open(NATIVES_ZIG).read()))
    except OSError:
        pass
    return names


def extract_natives(vxp_path, slug, registered):
    # Prefer natives REFERENCED in the decompiled C (accurate). Fall back to scanning
    # the decompressed image's strings — which over-counts for engines (e.g. "soyou")
    # that embed a full API-name table, so it's flagged as approximate.
    c_path = os.path.join(OUT, slug + ".c")
    src = ""
    if os.path.exists(c_path):
        src = open(c_path, "rb").read().decode("latin-1")
    sample = src[:4000]
    printable = sum(c.isprintable() or c in "\n\r\t" for c in sample)
    readable = bool(sample) and printable > 0.9 * len(sample)
    # In the decompiled C, natives appear as quoted string literals passed to the
    # resolver, e.g. (...)("vm_malloc") — that's the precise "referenced" set.
    quoted = sorted(set(re.findall(r'"((?:vm|mremu)_[a-z0-9_]{2,})"', src)) - NOT_NATIVES)

    if readable and quoted:
        found = quoted
        srcdesc = "decompiled C (referenced)"
    else:
        raw = open(vxp_path, "rb").read()
        found = sorted({m.decode() for m in NAME_RE.findall(ads_image(raw) or raw)} - NOT_NATIVES)
        srcdesc = "binary strings (APPROX — may include unused API names)"

    missing = [n for n in found if n not in registered]
    out = os.path.join(OUT, slug + ".natives.txt")
    with open(out, "w") as f:
        f.write(f"# source: {srcdesc}\n")
        f.write(f"# {len(found)} natives, {len(missing)} MISSING\n\n")
        if missing:
            f.write("## MISSING (not in core/natives.zig)\n")
            f.writelines(f"  {n}\n" for n in missing)
            f.write("\n")
        f.write("## all natives used\n")
        f.writelines(f"  {n}{'  MISSING' if n in missing else ''}\n" for n in found)
    return found, missing


def decompile_game(path, slug, force):
    out_c = os.path.join(OUT, slug + ".c")
    if os.path.exists(out_c) and not force:
        print(f"  have {slug}.c — skip decompile")
        return out_c
    bid = upload(path)
    if not bid:
        return None
    reruns = 0
    for _ in range(RETRY_COUNT):
        results = json.loads(http_get(
            f"https://dogbolt.org/api/binaries/{bid}/decompilations/?completed=true"
        ))["results"]
        for res in results:
            if res["decompiler"]["name"] != DECOMPILER:
                continue
            err = res.get("error")
            if err == "Exceeded time limit" and reruns < REQUESTS_PER_DECOMPILER:
                reruns += 1
                print(f"  timeout, rerun {reruns}/{REQUESTS_PER_DECOMPILER}")
                http_post(f"https://dogbolt.org/api/binaries/{bid}/"
                          f"decompilations/{res['id']}/rerun/")
                break
            elif err:
                print(f"  BinaryNinja error: {err}")
                return None
            open(out_c, "wb").write(http_get(res["download_url"]))
            print(f"  wrote {slug}.c")
            return out_c
        time.sleep(RETRY_SLEEP)
    print(f"  no BinaryNinja result after {RETRY_COUNT} polls")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="substring filter on game filename")
    ap.add_argument("--force", action="store_true", help="re-decompile even if .c exists")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    registered = registered_natives()
    games = sorted(f for f in os.listdir(GAMES) if f.lower().endswith(".vxp"))
    if args.only:
        games = [g for g in games if args.only.lower() in g.lower()]

    for game in games:
        path = os.path.join(GAMES, game)
        slug = os.path.splitext(game)[0].replace(" ", "_").lower()
        print(f"[{game}] -> {slug}")
        decompile_game(path, slug, args.force)
        found, missing = extract_natives(os.path.join(GAMES, game), slug, registered)
        print(f"  {len(found)} natives, {len(missing)} missing")


if __name__ == "__main__":
    main()
