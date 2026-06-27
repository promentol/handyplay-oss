"""For every native handler we've registered in natives/exen/*.zig,
compare its bound index to the canonical native name at that index."""

import re
import pathlib

base = pathlib.Path('/Users/narekh/Projects/notconsole/packages/exen-player2')

# Parse the now-correct native_names from names.zig
src = (base / 'core/debug/names.zig').read_text()
m = re.search(r'pub const native_names: \[185\]\[\]const u8 = \.\{(.*?)\};', src, re.DOTALL)
canonical = []
for line in m.group(1).splitlines():
    sm = re.match(r'\s*"([^"]*)"', line)
    if sm:
        canonical.append(sm.group(1))

# Walk natives/exen/*.zig for .{ N, "name", handler } registrations
rebind_lines = []
for zf in sorted((base / 'natives' / 'exen').glob('*.zig')):
    if zf.name == 'mod.zig':
        continue
    src = zf.read_text()
    for m in re.finditer(r'\.\{\s*(\d+),\s*"([^"]*)"\s*,\s*\w+\s*\}', src):
        idx = int(m.group(1))
        bound = m.group(2)
        canon = canonical[idx] if idx < len(canonical) else "?"
        canon_method = canon.split('.', 1)[-1] if '.' in canon else canon
        if bound != canon_method:
            rebind_lines.append((zf.name, idx, bound, canon))

print(f"{'file':<22} {'idx':>4} {'bound name':<32} canonical (.bin)")
print("-" * 90)
for fn, idx, b, c in rebind_lines:
    print(f"{fn:<22} {idx:>4} {b:<32} {c}")
print(f"\n{len(rebind_lines)} mis-bound handlers")
