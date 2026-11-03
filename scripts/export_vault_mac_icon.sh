#!/usr/bin/env bash
# Render the same editable Vault artwork for the Mac asset catalog.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
ICTOOL="$DEVELOPER/../Applications/Icon Composer.app/Contents/Executables/ictool"
ICONS="$ROOT/LunaVaultMac/Assets.xcassets/AppIconVaultMac.appiconset"
mkdir -p "$ICONS"
"$ICTOOL" "$ROOT/Design/IconComposer/Luna Vault.icon" --export-image \
  --output-file "$ICONS/icon_512x512@2x.png" --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1
python3 - "$ICONS" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
folder = Path(sys.argv[1])
images = []
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        if size * scale != 1024:
            subprocess.run(['sips', '-z', str(size*scale), str(size*scale), str(folder/'icon_512x512@2x.png'), '--out', str(folder/name)], check=True, stdout=subprocess.DEVNULL)
        images.append(dict(idiom='mac', size=f'{size}x{size}', scale=f'{scale}x', filename=name))
(folder/'Contents.json').write_text(json.dumps(dict(images=images, info=dict(author='xcode', version=1)), indent=2)+'\n')
PY
