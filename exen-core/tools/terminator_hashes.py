"""Resolve every Terminator hash to (native sub OR canonical class.method OR
gamelet-local class+method_idx). The .exn's gamelet classes have no
strings region — they only carry hashes — so unresolved hashes get
identified by their declaring class + method-table index."""
import re
import struct
import pathlib
import collections

base = pathlib.Path('/Users/narekh/Projects/notconsole/packages/exen-player2')

# 1) Captured hashes
hashes = []
log = pathlib.Path('/tmp/terminator_invokes.log')
if not log.exists():
    import subprocess
    out = subprocess.run(
        ['timeout', '6', 'zig-out/bin/exen-player', 'samples/TheTerminator.exn'],
        capture_output=True, cwd=str(base))
    log.write_bytes(out.stderr)
counts = collections.Counter()
arg_per_hash = {}
for line in log.read_text(errors='ignore').splitlines():
    m = re.search(r'INVOKE.*?(0x[0-9a-f]{8})\s+args=(\d+)', line)
    if m:
        h = int(m.group(1), 16)
        argc = int(m.group(2))
        counts[h] += 1
        arg_per_hash[h] = argc

# 2) Native lookup
native_lookup = {}
htos = (base / 'docs/hash_to_sub.md').read_text()
for line in htos.splitlines():
    m = re.match(r'\| (\d+) \| `([^`]+)` \| `(0x[0-9a-f]+)` \| `(sub_[0-9A-Fa-f]+)`', line)
    if m:
        native_lookup[int(m.group(3), 16)] = (int(m.group(1)), m.group(2), m.group(4))

# 3) Built-in bytecode method lookup (names.zig)
method_lookup = collections.defaultdict(list)
names_src = (base / 'core/debug/names.zig').read_text()
for m in re.finditer(r'0x([0-9a-f]{16}) => "([^"]+)"', names_src, re.IGNORECASE):
    key = int(m.group(1), 16)
    label = m.group(2)
    h = key & 0xFFFFFFFF
    method_lookup[h].append(label)

# 4) Gamelet class scan (Terminator.exn) — hash → (class_hash, method_idx, argc, body_off)
gamelet = {}
exn = (base / 'samples/TheTerminator.exn').read_bytes()
off = 0
class_hashes = []
while off + 16 <= len(exn):
    if exn[off:off+4] != b'4CVP':
        off += 1; continue
    sz = struct.unpack_from('<H', exn, off + 4)[0]
    if sz < 16 or off + sz > len(exn):
        off += 1; continue
    rec = exn[off:off+sz]
    cls = struct.unpack_from('<I', rec, 12)[0]
    class_hashes.append(cls)
    mt = struct.unpack_from('<H', rec, 32)[0]
    if mt != 0 and mt + 2 <= len(rec):
        mcount = struct.unpack_from('<H', rec, mt)[0]
        p = (mt + 5) & ~3
        for k in range(mcount):
            if p + 12 > len(rec):
                break
            h = struct.unpack_from('<I', rec, p)[0]
            argc = struct.unpack_from('<H', rec, p + 6)[0]
            body = struct.unpack_from('<H', rec, p + 8)[0]
            if h not in gamelet:
                gamelet[h] = (cls, k, argc, body)
            p += 12
    off = (off + sz + 3) & ~3

print(f"Terminator.exn: {len(class_hashes)} classes, {len(gamelet)} unique method hashes\n")

# 5) Resolve
print("| calls | hash | argc | resolution |")
print("|-------|------|------|------------|")
for h, count in counts.most_common():
    argc = arg_per_hash[h]
    if h in native_lookup:
        idx, name, sub = native_lookup[h]
        print(f"| {count} | `0x{h:08x}` | {argc} | **NATIVE[{idx}]** `{name}` → `{sub}` |")
    elif h in method_lookup:
        labels = sorted(set(method_lookup[h]))
        s = labels[0] if len(labels) == 1 else ' / '.join(labels[:3]) + (' (ambiguous)' if len(labels) > 1 else '')
        print(f"| {count} | `0x{h:08x}` | {argc} | builtin bytecode `{s}` |")
    elif h in gamelet:
        cls, mi, gargc, body = gamelet[h]
        print(f"| {count} | `0x{h:08x}` | {argc} | **gamelet-local** class `0x{cls:08x}` method[{mi}] (argc={gargc}, body=0x{body:04x}) |")
    else:
        print(f"| {count} | `0x{h:08x}` | {argc} | _no match anywhere_ |")
