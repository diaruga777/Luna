#!/usr/bin/env python3
"""Locate the user's Luna Code checkout; plugin caches never become app state."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ.get('LUNA_CODE_HOME', str(Path.home()/'Library/Application Support/Luna Vault/Code/Catalog')))
checkout = os.environ.get('LUNA_CODE_CHECKOUT')
if not checkout:
    try:
        checkout = json.loads((root/'installation.json').read_text())['checkout']
    except (OSError, ValueError, KeyError):
        print('Run the Luna Code setup skill, clone Luna Code, and run scripts/bootstrap_code_refresh.py first.', file=sys.stderr)
        sys.exit(1)
cli = Path(checkout).expanduser().resolve()/'bin/luna-code'
if not cli.is_file():
    print('Luna Code checkout moved. Run scripts/bootstrap_code_refresh.py in its new location.', file=sys.stderr)
    sys.exit(1)
os.execv(sys.executable, [sys.executable, str(cli), 'mcp'])
