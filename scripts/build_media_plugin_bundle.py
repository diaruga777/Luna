#!/usr/bin/env python3
"""Create the optional media bundle, outside every app resource directory."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
root = Path(__file__).resolve().parents[1]
output = root / 'docs/plugins/bundles/Luna-Media.lunabundle'
output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(output, 'w') as archive:
    for path in sorted((root / 'docs/plugins/media').glob('*.js')):
        info = ZipInfo(path.name, (2026, 1, 1, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, path.read_bytes())
print(output.relative_to(root))
