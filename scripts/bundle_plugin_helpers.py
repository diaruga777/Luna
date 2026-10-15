#!/usr/bin/env python3
"""Embed explicitly requested plugin-owned helpers; no native runtime fallbacks."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
for path in (root / 'LunaLibraries/Sources/LunaBundledPlugins/Plugins').glob('*.js'):
    source = path.read_text()
    for name in ['web', 'newyorker', 'retail-data', 'shop', 'access-data', 'access']:
        tag = name.upper().replace('-', '_')
        start, end = f'// BEGIN BUNDLED {tag} HELPER', f'// END BUNDLED {tag} HELPER'
        if start not in source: continue
        before, rest = source.split(start, 1)
        _, after = rest.split(end, 1)
        helper = (root / f'docs/plugins/lib/{name}.js').read_text()
        source = before + start + '\n' + helper + end + after
    path.write_text(source)
