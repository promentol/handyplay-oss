"""Map every native method's (class, hash) → sub_* via funcs_407AA2[].

Reads docs/extracted/*.md — each per-class file lists its method_table[]
rows under "## method_table (raw — by row position)". Native rows have
native_idx column populated; the script reads native_idx + ref's
funcs_407AA2[] table to resolve sub_*.

Names are no longer in the extracted docs (positional pairing removed —
see commit "remove all pairing in extract_table"). Use the class hash
hex + method hash hex as the runtime identifiers, plus the resolved
sub_* for forensic lookups in ref.

  python3 tools/hash_to_sub.py                 — write docs/hash_to_sub.md
  python3 tools/hash_to_sub.py 0xbc1d842c       — look up one method hash
  python3 tools/hash_to_sub.py sub_424FF2       — reverse — list method hashes that dispatch to this sub
"""

import re
import sys
import pathlib

base = pathlib.Path(__file__).resolve().parent.parent

# 1) Parse funcs_407AA2 — gives native_idx → sub_*
emc = (base / 'reference/ref').read_text()
m = re.search(r'funcs_407AA2\[185\][^=]*=\s*\{(.*?)\};', emc, re.DOTALL)
assert m is not None, "funcs_407AA2[185] not found in reference/ref"
subs = re.findall(r'&(sub_[0-9A-Fa-f]+)', m.group(1))
assert len(subs) == 185, f"expected 185 subs, got {len(subs)}"

# 2) Walk extracted/*.md — read the "## method_table (raw — by row position)"
#    section of each file. Native rows have a numeric native_idx; capture
#    (class_full, class_hash, method_hash, native_idx).
entries = []   # (class_full, class_hash, method_hash, native_idx)
HEADER_RE = re.compile(r'^# (\S+)\s+\(`(0x[0-9a-fA-F]+)`\)')
extracted = base / 'docs/extracted'
for md in sorted(extracted.glob('*.md')):
    text = md.read_text()
    head = text.splitlines()[0]
    hm = HEADER_RE.match(head)
    if not hm:
        continue
    class_full = hm.group(1)
    class_hash = int(hm.group(2), 16)
    # Find the method_table raw section
    section_start = text.find('## method_table (raw')
    if section_start < 0:
        continue
    section_end = text.find('\n## ', section_start + 1)
    if section_end < 0:
        section_end = len(text)
    section = text[section_start:section_end]
    for line in section.splitlines():
        if not line.startswith('| ') or '|---' in line or '| # |' in line:
            continue
        cols = [c.strip() for c in line.strip('|').split('|')]
        # Expect: [#, hash, flags, static, native, argc, body_off, extra, native_idx]
        if len(cols) < 9:
            continue
        hash_cell = cols[1].strip('`')
        native_flag = cols[4]
        idx_cell = cols[8]
        if native_flag != 'yes' or idx_cell == '-' or not hash_cell.startswith('0x'):
            continue
        try:
            idx = int(idx_cell)
        except ValueError:
            continue
        entries.append((class_full, class_hash, int(hash_cell, 16), idx))

# 3) Lookup mode
if len(sys.argv) > 1:
    q = sys.argv[1].lower()
    if q.startswith('0x'):
        h = int(q, 16)
        hits = [e for e in entries if e[2] == h]
        if not hits:
            print(f"No native dispatches with method-hash {q}")
            sys.exit(0)
        print(f"Method hash {q} → {len(hits)} native method(s):")
        for cls, ch, _, idx in hits:
            print(f"  [{idx:>3}] {cls} (class=0x{ch:08x}) → funcs_407AA2[{idx}] = {subs[idx]}")
    elif q.startswith('sub_'):
        target = 'sub_' + q[4:].upper()
        try:
            target_idx = subs.index(target)
        except ValueError:
            print(f"sub {q} not in funcs_407AA2[]")
            sys.exit(1)
        hits = [e for e in entries if e[3] == target_idx]
        print(f"{target} = funcs_407AA2[{target_idx}] dispatched from {len(hits)} method hash(es):")
        for cls, ch, mh, _ in hits:
            print(f"  {cls} (class=0x{ch:08x}) method=0x{mh:08x}")
    else:
        # class-name query
        hits = [e for e in entries if e[0].lower().endswith(q) or q in e[0].lower()]
        for cls, ch, mh, idx in hits:
            print(f"  [{idx:>3}] {cls} (class=0x{ch:08x}) method=0x{mh:08x} → {subs[idx]}")
    sys.exit(0)

# 4) Doc mode — emit docs/hash_to_sub.md sorted by native_idx
out = ['# Native Hash → Sub Mapping',
       '',
       'For every native method declared in any 4CVP class record, the',
       'chain is `(class_hash, method_hash) → native_idx → funcs_407AA2[idx]`',
       '`→ sub_*` in ref. This file flattens the chain so you can',
       'grep a method-hash and find the canonical C function.',
       '',
       'Names are intentionally omitted — positional name-pairing was',
       'unreliable; use the structural (class_hash, method_hash) pair',
       'instead. See `docs/extracted/<class>.md` for the per-class raw',
       'method_table and strings-region dumps.',
       '',
       f'**Native methods catalogued:** {len(entries)} (across {len({e[0] for e in entries})} classes)',
       '',
       '| native_idx | class | class_hash | method_hash | sub_* |',
       '|------------|-------|------------|-------------|--------|']
entries.sort(key=lambda e: e[3])
for cls, ch, mh, idx in entries:
    out.append(f'| {idx} | `{cls}` | `0x{ch:08x}` | `0x{mh:08x}` | `{subs[idx]}` |')
out.append('')
out.append('## Usage')
out.append('')
out.append('```sh')
out.append('# Look up a method hash')
out.append('python3 tools/hash_to_sub.py 0xbc1d842c')
out.append('')
out.append('# Find all hashes dispatching to a sub')
out.append('python3 tools/hash_to_sub.py sub_424FF2')
out.append('')
out.append('# Filter by class')
out.append('python3 tools/hash_to_sub.py image')
out.append('```')

(base / 'docs/hash_to_sub.md').write_text('\n'.join(out) + '\n')
print(f"Wrote docs/hash_to_sub.md — {len(entries)} entries")
