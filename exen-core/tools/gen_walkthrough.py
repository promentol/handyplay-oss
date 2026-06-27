"""Generate / refresh NATIVE_WALKTHROUGH.md.

Columns:
  idx           — structural (from `funcs_407AA2[]`)
  sub           — structural (from `funcs_407AA2[]`)
  class.method  — manual: what dispatches here (often one; sometimes
                  several gamelet classes share a native)
  zig handler   — manual: `natives/.../File.zig::fn` if ported
  notes         — manual: short description / status / open question

Only `idx` and `sub` are auto-filled. The other three are free-form
slots filled on the fly as natives are walked. Re-running this script
PRESERVES any non-empty manual cells: it parses the existing file
(if present), reuses each row's manual cells by idx, and refreshes
only the structural columns.

Usage:
  python3 tools/gen_walkthrough.py
"""

import re
import pathlib

base = pathlib.Path(__file__).resolve().parent.parent
out_path = base / 'NATIVE_WALKTHROUGH.md'

# Structural: read sub addresses from ref
emc = (base / 'reference/ref').read_text()
m = re.search(r'funcs_407AA2\[185\][^=]*=\s*\{(.*?)\};', emc, re.DOTALL)
assert m, "couldn't find funcs_407AA2"
subs = re.findall(r'&(sub_[0-9A-Fa-f]+)', m.group(1))
assert len(subs) == 185, f"got {len(subs)} subs"

# Merge: pull existing manual cells (class.method / zig handler / notes)
# from the current file if present, keyed by idx.
manual = {}  # idx -> (cm, zh, notes)
if out_path.exists():
    for line in out_path.read_text().splitlines():
        m2 = re.match(
            r'^\|\s*(\d+)\s*\|\s*`[^`]*`\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|$',
            line,
        )
        if m2:
            idx = int(m2.group(1))
            manual[idx] = (m2.group(2), m2.group(3), m2.group(4))

out = [
    '# Native Function Walkthrough',
    '',
    'One row per `funcs_407AA2[]` entry (declared at',
    '`reference/ref:3124`). `idx` and `sub` are structural; the',
    'three remaining columns are filled in on the fly as we encounter',
    'natives during gamelet runs:',
    '',
    '- **class.method** — the `(class_hash, method_hash)` pair(s) that',
    '  dispatch here. Use `python3 tools/hash_to_sub.py sub_NNNNNN`.',
    '- **zig handler** — `file::fn` of the Zig native, or blank for',
    '  `defaultNativeStub`. Use',
    '  `grep -n "{ idx," natives/*/*.zig natives/java/lang/*.zig`.',
    '- **notes** — short canonical-body summary, observations, gotchas,',
    '  or status markers. Anything worth remembering next time we hit',
    "  this row. Read `reference/ref` for the sub body itself.",
    '',
    'Regenerate via `python3 tools/gen_walkthrough.py`. The script',
    "merges with the existing file — manual cells are preserved by idx,",
    "so it's safe to re-run any time.",
    '',
    '| idx | sub | class.method | zig handler | notes |',
    '|-----|-----|--------------|-------------|-------|',
]

for i, sub in enumerate(subs):
    cm, zh, notes = manual.get(i, ('', '', ''))
    out.append(f'| {i} | `{sub}` | {cm} | {zh} | {notes} |')

out_path.write_text('\n'.join(out) + '\n')
filled = sum(1 for v in manual.values() if any(c.strip() for c in v))
print(f"Wrote {out_path.relative_to(base)} — 185 rows ({filled} with manual cells preserved)")
