#!/usr/bin/env python3
"""Embed explicitly requested source helpers in standalone installable plugins."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
start, end = '// BEGIN BUNDLED WEB HELPER', '// END BUNDLED WEB HELPER'
helper = (root / 'docs/plugins/lib/web.js').read_text()
for path in list((root / 'LunaLibraries/Sources/LunaBundledPlugins/Plugins').glob('*.js')):
    source = path.read_text()
    if start not in source: continue
    before, rest = source.split(start, 1)
    _, after = rest.split(end, 1)
    path.write_text(before + start + '\n' + helper + end + after)
