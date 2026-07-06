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
import urllib.error
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


NET_RETRIES = 5  # transient errors (reset/timeout/5xx) are expected on a long,
NET_BACKOFF = 8  # rate-limited batch — retry with linear backoff before giving up.


def _with_retries(fn):
    """Run a network call, retrying transient failures (connection reset, timeout,
    5xx / 429) with linear backoff. Re-raises the last error if all attempts fail."""
    import socket
    last = None
    for attempt in range(NET_RETRIES):
        try:
            return fn()
        except urllib.error.HTTPError as e:
            last = e
            if e.code not in (429, 500, 502, 503, 504):
                raise  # a real client error (404/400/…) won't fix itself
        except (urllib.error.URLError, ConnectionError, socket.timeout, OSError) as e:
            last = e
        wait = NET_BACKOFF * (attempt + 1)
        print(f"  net error ({last}); retry {attempt + 1}/{NET_RETRIES} in {wait}s")
        time.sleep(wait)
    raise last if last else RuntimeError("network call failed")


def http_get(url):
    def do():
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
            enc = r.headers.get("Content-Encoding")
        # dogbolt serves the decompiled .c gzip-compressed; urllib (unlike requests)
        # doesn't auto-decompress, so handle it here.
        if enc == "gzip" or body[:2] == b"\x1f\x8b":
            body = gzip.decompress(body)
        return body
    return _with_retries(do)


def http_post(url, data=None, headers=None):
    def do():
        req = urllib.request.Request(url, data=data or b"", method="POST",
                                     headers={"User-Agent": UA, **(headers or {})})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()
    return _with_retries(do)


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
ELF_CACHE = os.path.join(OUT, ".elf_cache")


def ensure_vxp2elf():
    """Build the vxp2elf loader tool if it isn't built yet."""
    if os.path.exists(VXP2ELF):
        return True
    import subprocess
    print("  building vxp2elf (zig build)…")
    subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True)
    return os.path.exists(VXP2ELF)


def preprocess(path):
    """PREPROCESS a game into its ready, decompressed, relocated image (bytes).

    Priority:
      1. already an ELF -> as-is
      2. the emulator's own loader (vxp2elf) — handles every packing/compression
         variant the emulator can run, emits a relocated ARM ELF
      3. quick ADS zlib unpack (ads_image) wrapped in a minimal ELF
      4. raw file bytes (last resort; compressed vxps yield few/no name strings)
    Results are cached in game_sources/.elf_cache keyed by content hash.
    """
    raw = open(path, "rb").read()
    if len(raw) >= 4 and raw[1:4] == b"ELF":
        return raw, "elf"

    os.makedirs(ELF_CACHE, exist_ok=True)
    cached = os.path.join(ELF_CACHE, hashlib.sha256(raw).hexdigest()[:16] + ".elf")
    if os.path.exists(cached):
        return open(cached, "rb").read(), "loader (cached)"

    if ensure_vxp2elf():
        import subprocess
        r = subprocess.run([VXP2ELF, path, cached], capture_output=True)
        if r.returncode == 0 and os.path.exists(cached):
            return open(cached, "rb").read(), "loader (vxp2elf)"
        print(f"  vxp2elf failed: {r.stderr.decode(errors='ignore').strip()[:120]}")

    img = ads_image(raw)
    if img:
        data = wrap_elf(img)
        open(cached, "wb").write(data)
        return data, "ads_image"
    return raw, "raw (COMPRESSED — name scan will be incomplete)"


def upload(path):
    """Multipart upload; return (binary id, reason). id is None on failure and
    reason is a short string explaining why (None on success). Cached by sha256."""
    data, how = preprocess(path)
    if how.startswith("raw"):
        print(f"  upload: preprocessing failed, sending raw bytes")
    sha = hashlib.sha256(data).hexdigest()
    if len(data) > 2 * 1024 * 1024:
        print(f"  SKIP (>2MB): {os.path.basename(path)}")
        return None, "oversize (>2MB)"

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    if os.path.exists(CACHE):
        for line in open(CACHE):
            if line.startswith(f"sha256:{sha} "):
                cached_bid = line.strip().split(" ")[1]
                return (cached_bid, None) if cached_bid != "None" \
                    else (None, "upload failed (cached)")

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
    return (bid, None) if bid else (None, "upload failed (no id from dogbolt)")


MREMU_BRIDGE = os.path.join(ROOT, "MREmu", "MREmu", "Bridge.cpp")


def registered_natives():
    """(implemented, stubbed) name sets from core/natives.zig.

    r.r("name", fn)  -> real implementation      (implemented)
    r.rs("name", fn) -> placeholder/constant-stub (stubbed)
    Anything absent from both is unimplemented ("MISSING")."""
    implemented = {"vm_get_sym_entry"}
    stubbed = set()
    try:
        src = open(NATIVES_ZIG).read()
        # r\.r\(  matches r.r( only — r.rs( has an 's' before the paren.
        implemented |= set(re.findall(r'r\.r\("([a-z0-9_]+)"', src))
        stubbed |= set(re.findall(r'r\.rs\("([a-z0-9_]+)"', src))
    except OSError:
        pass
    return implemented, stubbed


def sdk_known_natives(registered):
    """Names of REAL MRE SDK natives we know of (ours + the reference emulator's).
    Used to spot junk matches (game-internal vm_* identifiers) in image scans."""
    names = set(registered)
    try:
        names |= set(re.findall(r"FUNCN(?:_FIX)?\(((?:vm|mremu)_[a-z0-9_]+)\)",
                                open(MREMU_BRIDGE).read()))
    except OSError:
        pass
    return names


# NOTE: an offline "referenced" set via string xrefs was tried and does NOT
# work: these games embed native names inline in fixed-stride resolver records
# and compute their addresses with ADR — no stored pointer to match. The
# decompiler service (dogbolt/Binary Ninja) remains the only source for the
# precise referenced-in-code tier; the image scan is the offline superset.


def extract_natives(vxp_path, slug, registered, stubbed=None):
    stubbed = stubbed or frozenset()
    # Two complementary sets:
    #   referenced — quoted names in the decompiled C (precise: actually called)
    #   image      — every native name string in the PREPROCESSED (decompressed,
    #                loaded) image. Complete even without a decompile; a game can
    #                only resolve a native whose name string exists in its image,
    #                so this is the exhaustive upper bound ("fetch all natives").
    c_path = os.path.join(OUT, slug + ".c")
    src = ""
    if os.path.exists(c_path):
        src = open(c_path, "rb").read().decode("latin-1")
    sample = src[:4000]
    printable = sum(c.isprintable() or c in "\n\r\t" for c in sample)
    readable = bool(sample) and printable > 0.9 * len(sample)
    referenced_c = sorted(set(re.findall(r'"((?:vm|mremu)_[a-z0-9_]{2,})"', src)) - NOT_NATIVES) \
        if readable else []

    image, how = preprocess(vxp_path)
    sdk = sdk_known_natives(registered)
    in_image = sorted({m.decode() for m in NAME_RE.findall(image)} - NOT_NATIVES)

    # Engine-built games (soyou etc.) embed the ENTIRE SDK API name table, so
    # image presence is not usage evidence there. Detect via SDK coverage.
    api_table = len(set(in_image) & sdk) >= 0.6 * len(sdk) and len(in_image) >= 250

    referenced = referenced_c
    extra = [n for n in in_image if n not in referenced]

    found = sorted(set(referenced) | set(in_image))
    # Tiered MISSING: referenced-in-C gaps are real work; image-only gaps are
    # advisory — and suppressed entirely for embedded-API-table games.
    missing_ref = [n for n in referenced if n not in registered]

    # ELF vxps carry symbol/debug strings, so the image scan also matches SDK
    # TYPE names (vm_*_struct/_enum/_prop, vm_color_565…) and game-internal
    # symbol families (e.g. vm_ex_rn_*: many same-prefix names, none SDK-known).
    # Those are not callable natives — demote them out of the advisory list.
    typeish = re.compile(r"_(struct|enum|type|prop|cb|t|565|888)$")
    from collections import Counter
    fam = lambda n: "_".join(n.split("_")[:3])
    fams = Counter(fam(n) for n in in_image if n not in sdk)
    def looks_internal(n):
        return bool(typeish.search(n)) or (n not in sdk and fams[fam(n)] >= 6)

    missing_img = [] if api_table else \
        [n for n in extra if n not in registered and not looks_internal(n)]
    # Informational: unknown to both our natives and the reference emulator.
    unknown = [n for n in in_image if n not in sdk]
    missing = missing_ref + [n for n in missing_img if n not in missing_ref]
    # STUBBED: registered but a placeholder/constant-return (r.rs in natives.zig).
    # Referenced-in-C gaps are the real signal; image-only stubs are advisory.
    stubbed_ref = [n for n in referenced if n in stubbed]
    stubbed_img = [] if api_table else \
        [n for n in extra if n in stubbed and not looks_internal(n)]
    # Names we actually flag as STUBBED (same tiering as `missing`: referenced +
    # non-suppressed image-only). Keeps inline tags consistent with the header count.
    stubbed_shown = set(stubbed_ref) | set(stubbed_img)

    def tag(n):
        if n in missing:
            return "  MISSING"
        if n in stubbed_shown:
            return "  STUBBED"
        return ""

    out = os.path.join(OUT, slug + ".natives.txt")
    with open(out, "w") as f:
        f.write(f"# sources: decompiled C (referenced) + image strings [{how}]\n")
        f.write(f"# {len(found)} natives ({len(referenced)} referenced, "
                f"{len(extra)} image-only), {len(missing)} MISSING, "
                f"{len(stubbed_shown)} STUBBED\n")
        if api_table:
            f.write("# NOTE: embedded full-SDK API table detected — image names are\n"
                    "#       not usage evidence; MISSING counts referenced-in-C only.\n")
        f.write("\n")
        if missing_ref:
            f.write("## MISSING and referenced in decompiled C (real gaps)\n")
            f.writelines(f"  {n}\n" for n in missing_ref)
            f.write("\n")
        if missing_img:
            f.write("## MISSING, image-only (advisory — possibly unused)\n")
            f.writelines(f"  {n}\n" for n in missing_img)
            f.write("\n")
        if stubbed_ref:
            f.write("## STUBBED and referenced in decompiled C "
                    "(placeholder/constant-return — real natives to flesh out)\n")
            f.writelines(f"  {n}\n" for n in stubbed_ref)
            f.write("\n")
        if stubbed_img:
            f.write("## STUBBED, image-only (advisory — possibly unused)\n")
            f.writelines(f"  {n}\n" for n in stubbed_img)
            f.write("\n")
        if referenced:
            f.write("## referenced in decompiled C\n")
            f.writelines(f"  {n}{tag(n)}\n" for n in referenced)
            f.write("\n")
        f.write("## present in image (superset; includes possibly-unused names)\n")
        f.writelines(f"  {n}{tag(n)}\n" for n in in_image)
        if unknown:
            f.write("\n## unknown to core/natives.zig AND MREmu (newer SDK or game-internal)\n")
            f.writelines(f"  {n}\n" for n in unknown)
    return found, missing


def decompile_game(path, slug, force):
    """Return (out_c_path_or_None, reason). reason is None on success (or when the
    .c already exists), else a short string explaining why no .c was produced."""
    out_c = os.path.join(OUT, slug + ".c")
    if os.path.exists(out_c) and not force:
        print(f"  have {slug}.c — skip decompile")
        return out_c, None
    bid, reason = upload(path)
    if not bid:
        return None, reason
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
                return None, f"BinaryNinja error: {err}"
            open(out_c, "wb").write(http_get(res["download_url"]))
            print(f"  wrote {slug}.c")
            return out_c, None
        time.sleep(RETRY_SLEEP)
    print(f"  no BinaryNinja result after {RETRY_COUNT} polls")
    return None, f"no result after {RETRY_COUNT} polls"


def main():
    global GAMES, OUT, ELF_CACHE
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="substring filter on game filename")
    ap.add_argument("--force", action="store_true", help="re-decompile even if .c exists")
    ap.add_argument("--natives-only", action="store_true",
                    help="skip dogbolt entirely; regenerate natives.txt from the "
                         "preprocessed images (offline, uses existing .c if present)")
    ap.add_argument("--games-dir", default="games",
                    help="folder of .vxp games to process (default: games)")
    ap.add_argument("--out-dir", default="game_sources",
                    help="folder for .c / .natives.txt output (default: game_sources)")
    args = ap.parse_args()

    # Repoint the module globals so every helper (preprocess, extract_natives,
    # decompile_game) picks up the chosen dirs. Defaults preserve the original
    # games/ -> game_sources/ behavior.
    GAMES = args.games_dir if os.path.isabs(args.games_dir) else os.path.join(ROOT, args.games_dir)
    OUT = args.out_dir if os.path.isabs(args.out_dir) else os.path.join(ROOT, args.out_dir)
    ELF_CACHE = os.path.join(OUT, ".elf_cache")

    os.makedirs(OUT, exist_ok=True)
    implemented, stubbed = registered_natives()
    registered = implemented | stubbed
    games = sorted(f for f in os.listdir(GAMES) if f.lower().endswith(".vxp"))
    if args.only:
        games = [g for g in games if args.only.lower() in g.lower()]

    undecompiled = []  # (game, reason) for games with no .c from dogbolt
    for game in games:
        path = os.path.join(GAMES, game)
        slug = os.path.splitext(game)[0].replace(" ", "_").lower()
        print(f"[{game}] -> {slug}")
        if not args.natives_only:
            try:
                _, reason = decompile_game(path, slug, args.force)
            except Exception as e:  # exhausted retries / unexpected — don't kill the batch
                reason = f"network/error: {e}"
                print(f"  decompile aborted: {e}")
            if reason:
                undecompiled.append((game, reason))
        found, missing = extract_natives(os.path.join(GAMES, game), slug,
                                         registered, stubbed)
        print(f"  {len(found)} natives, {len(missing)} missing")

    if not args.natives_only:
        summary = os.path.join(OUT, "_undecompiled.txt")
        with open(summary, "w") as f:
            f.write(f"# {len(undecompiled)} game(s) had no decompiled .c "
                    f"(natives lists still generated from the image scan)\n\n")
            for game, reason in undecompiled:
                f.write(f"  {game}\t{reason}\n")
        if undecompiled:
            print(f"\n=== {len(undecompiled)} game(s) NOT decompiled "
                  f"(see {os.path.relpath(summary, ROOT)}) ===")
            for game, reason in undecompiled:
                print(f"  {game}: {reason}")


if __name__ == "__main__":
    main()
