#!/usr/bin/env python3
"""Extract canonical method names from the reference simulator + pair to runtime hashes.

Strategy: anchor on KNOWN (class, name, hash) triples from prior body
inspection. For each anchor: find the name-table entry with that name +
matching argc, declare that entry's surrounding run as belonging to the
anchor's class. Within each anchored run, pair remaining entries with
method-info entries from that class in declaration order, filtered by
matching argc.

This requires us to seed the algorithm with verified anchors but it
gives high-confidence output for the rest of the class's methods.
"""
import struct, re, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENSIM = (ROOT / 'reference' / 'the reference simulator').read_bytes()
BUILTINS = (ROOT / 'assets' / 'unk_4494F0.bin').read_bytes()
NAME_RX = re.compile(rb'^[a-zA-Z_<][a-zA-Z0-9_<>$]{1,40}$')

def try_parse(buf, i):
    if i + 4 > len(buf): return None
    nlen = struct.unpack_from('<H', buf, i)[0]
    if not (1 <= nlen <= 40): return None
    end = i + 2 + nlen
    if end + 8 > len(buf): return None
    name = buf[i+2:end]
    if not NAME_RX.match(name): return None
    body  = struct.unpack_from('<I', buf, end)[0]
    rtag  = struct.unpack_from('<H', buf, end+4)[0]
    argc  = struct.unpack_from('<H', buf, end+6)[0]
    if argc > 20: return None
    if argc and end + 8 + 2*argc > len(buf): return None
    return {'off': i, 'name': name.decode(), 'body': body,
            'rtag': rtag, 'argc': argc,
            'tags': tuple(struct.unpack_from('<H', buf, end+8+2*k)[0] for k in range(argc)),
            'next': end + 8 + 2*argc}

# Greedy chain
runs = []
i = 0
while i < len(GENSIM):
    e = try_parse(GENSIM, i)
    if not e: i += 1; continue
    run = [e]
    j = e['next']
    while True:
        e2 = try_parse(GENSIM, j)
        if not e2: break
        run.append(e2); j = e2['next']
    if len(run) >= 2:
        runs.append(run); i = j
    else:
        i += 1

# Parse 4CVP
classes = []
off = 0
while off + 16 <= len(BUILTINS):
    if BUILTINS[off:off+4] != b'4CVP': break
    sz = struct.unpack_from('<H', BUILTINS, off+4)[0]
    h  = struct.unpack_from('<I', BUILTINS, off+12)[0]
    mt = struct.unpack_from('<H', BUILTINS, off+32)[0]
    methods = []
    if mt and mt + 2 <= sz:
        count = struct.unpack_from('<H', BUILTINS, off+mt)[0]
        p = (mt + 5) & ~3
        for i in range(count):
            if p + 12 > sz: break
            methods.append({
                'order': i,
                'hash': struct.unpack_from('<I', BUILTINS, off+p)[0],
                'flags': struct.unpack_from('<H', BUILTINS, off+p+4)[0],
                'args': struct.unpack_from('<H', BUILTINS, off+p+6)[0],
                'body': struct.unpack_from('<H', BUILTINS, off+p+8)[0],
            })
            m = methods[-1]
            m['native'] = bool(m['flags'] & 0x100)
            m['nidx'] = struct.unpack_from('<I', BUILTINS, off+m['body'])[0] if m['native'] and m['body']+4 <= sz else None
            p = (p + 15) & ~3
    classes.append({'hash': h, 'methods': methods})
    off = (off + sz + 3) & ~3

CLASSES_BY_HASH = {c['hash']: c for c in classes}

KNOWN_CLASS_NAMES = {
    0x4161c4a6: 'java.lang.Object', 0x7772dde3: 'java.lang.String',
    0x42816699: 'java.lang.Class',  0x47cb31c2: 'java.lang.StringBuffer',
    0x6551f7dc: 'vm.sys.Bootstrap', 0xb4f0ccbf: 'vm.sys.Runtime',
    0xc6ed8e2a: 'exen.Graphics',    0x23c5e7e8: 'exen.Image',
    0xbab5c664: 'exen.Resource',    0xe127b0e1: 'exen.Gamelet',
    0xe7167d52: 'exen.AnimBitmap',  0x7219d0b4: 'exen.PlayField',
    0xd414954a: 'exen.AnimFlash',   0x02255f70: 'exen.Displayable',
    0x6bddc5b7: 'exen.Sms',         0xb6ee3b2a: 'exen.DialogBox',
    0xd8f81132: 'exen.FX',          0xdf774e57: 'exen.List',
    0x3298b202: 'exen.Math',        0x8f9e8280: 'exen.Matrix3D',
    0xe36f9667: 'exen.Vector3D',    0xd0b8e4ac: 'exen.RayCast',
    0x11749d8a: 'exen.util.Debug',  0x1c4d8791: 'exen.Command',
    0x5562ca3b: 'exen.Palette',     0xf7f39575: 'exen.Component',
    0xbbd967f9: 'catalog.Catalog',  0xdd22a4ed: 'catalog.GameProperty',
}

# ── Anchor table: (class_hash, name, argc) → expected method-hash ──────────
ANCHORS = [
    (0xc6ed8e2a, 'clearRect',     4, 0xcf201fef),
    (0xc6ed8e2a, 'drawImage',     11, 0x43d2c07b),
    (0xc6ed8e2a, 'setColor',      3, 0x8a2a1ebb),
    (0xc6ed8e2a, 'drawChars',     6, 0x81ff7c1a),
    (0xe127b0e1, 'screenUpdate',  2, 0xbc1d842c),
    (0x7772dde3, 'length',        0, 0xd724ffd6),
    (0x7772dde3, 'getBytes',      0, 0xb14f9686),
    (0x7772dde3, 'compareTo',     1, 0x1b487e6f),
]

# For each anchor: find the run that contains a matching entry; that
# run belongs to the anchor's class.
anchored = {}  # class_hash → run
for cls_h, name, argc, _ in ANCHORS:
    if cls_h in anchored: continue
    for run in runs:
        if any(e['name'] == name and e['argc'] == argc for e in run):
            anchored[cls_h] = run
            break

print(f'anchored {len(anchored)} classes via known (name, argc) pairs:')
for cls_h, run in anchored.items():
    cls_name = KNOWN_CLASS_NAMES.get(cls_h, hex(cls_h))
    print(f'  {cls_name}: run @ 0x{run[0]["off"]:06x}, {len(run)} entries')

# Within each anchored class run: pair name entries with method-info entries
# of the same class by argc. Strategy: walk name entries in run order; for
# each, find unclaimed method-info entries with matching argc. If exactly
# one matches use it; otherwise use the FIRST matching one (declaration
# order within argc group — best-effort).
all_pairs = []
for cls_h, run in anchored.items():
    cls = CLASSES_BY_HASH.get(cls_h)
    if not cls: continue
    methods = list(cls['methods'])
    for n in run:
        candidates = [m for m in methods if m['args'] == n['argc']]
        if not candidates: continue
        m = candidates[0]
        all_pairs.append({
            'class_hash': cls_h,
            'class': KNOWN_CLASS_NAMES.get(cls_h, hex(cls_h)),
            'method_hash': m['hash'],
            'method': n['name'],
            'native': m['native'],
            'nidx': m['nidx'],
            'argc': n['argc'],
        })
        methods.remove(m)

print(f'\npaired {len(all_pairs)} name → hash entries')

# Verify against anchors
print('\nverification against known anchors:')
ok_count = 0
for cls_h, name, argc, exp in ANCHORS:
    p = next((x for x in all_pairs
              if x['class_hash'] == cls_h and x['method'] == name), None)
    if p and p['method_hash'] == exp:
        print(f'  ✓ {KNOWN_CLASS_NAMES[cls_h]}.{name}: 0x{exp:08x}')
        ok_count += 1
    elif p:
        print(f'  ✗ {KNOWN_CLASS_NAMES[cls_h]}.{name}: expected 0x{exp:08x}, got 0x{p["method_hash"]:08x}')
    else:
        print(f'  ? {KNOWN_CLASS_NAMES[cls_h]}.{name}: not paired')
print(f'\n{ok_count}/{len(ANCHORS)} anchors verified')

# Dump
out = {}
for p in all_pairs:
    out.setdefault(p['class'], []).append({
        'method': p['method'],
        'hash': f"0x{p['method_hash']:08x}",
        'native_idx': p['nidx'],
        'argc': p['argc'],
    })
Path('.claude/skills/research-native-call/method_names.json').write_text(json.dumps(out, indent=2))
print(f'wrote .claude/skills/research-native-call/method_names.json — {len(all_pairs)} entries')
