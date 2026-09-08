#!/bin/zsh
# Subsets the five bundled reader fonts (Design/Fonts/Full/*.ttf) down to
# Latin, Greek, and Cyrillic coverage and writes the result under the SAME
# filenames to both places that ship them: Luna/Resources/Fonts (the four
# content apps read them from their own bundle root, and so do their
# extensions) and LunaWriter/Fonts (Writer's own copy).
#
# Coverage rule: a reader font renders Latin, Greek, and Cyrillic script
# text; any other character falls back to the system font
# (ReaderFont.resolved(size:weight:italic:) already falls back when a family
# lookup fails, and CoreText falls back per-glyph within a run otherwise).
#
# Family names, the fvar axis, and every OpenType layout feature stay intact
# (--layout-features='*'), so the variable-font weight axis and italic faces
# keep working through ReaderFont's descriptor matching. --name-IDs='*' keeps
# every 'name' table entry (pyftsubset drops IDs above 6 by default), so the
# typographic family name (16) and the OFL license entries (13, 14) survive
# alongside the family/subfamily names (1, 2) ReaderFont matches on.
#
# Requires fonttools' pyftsubset. Install with:
#   python3 -m pip install --user fonttools
# or point PYFTSUBSET at an existing install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/Design/Fonts/Full"
DEST_DIR="$REPO_ROOT/Luna/Resources/Fonts"
WRITER_DIR="$REPO_ROOT/LunaWriter/Fonts"

PYFTSUBSET="${PYFTSUBSET:-/Users/hsp/Library/Python/3.9/bin/pyftsubset}"
command -v "$PYFTSUBSET" >/dev/null 2>&1 || {
    echo "error: pyftsubset not found at '$PYFTSUBSET'." >&2
    echo "Install fonttools (python3 -m pip install --user fonttools) or set PYFTSUBSET." >&2
    exit 1
}

# Latin (incl. Latin Extended-A/B pieces, punctuation, currency, symbols used
# by reader chrome), then Greek and Cyrillic.
UNICODES="U+0000-024F,U+02B0-036F,U+1E00-1EFF,U+2000-206F,U+2070-209F,U+20A0-20CF,U+2100-214F,U+2150-218F,U+2190-2199,U+2200-2212,U+2215-2216,U+2260-2265,U+25A0-25FF,U+FB00-FB06,U+FEFF,U+FFFD,U+0370-03FF,U+1F00-1FFF,U+0400-052F,U+2DE0-2DFF,U+A640-A69F"

FONTS=(Lexend Literata Literata-Italic NotoSans NotoSans-Italic)

for name in "${FONTS[@]}"; do
    src="$SRC_DIR/$name.ttf"
    dest="$DEST_DIR/$name.ttf"
    [[ -f "$src" ]] || { echo "error: missing source font '$src'." >&2; exit 1; }
    "$PYFTSUBSET" "$src" \
        --output-file="$dest" \
        --unicodes="$UNICODES" \
        --layout-features='*' \
        --notdef-outline \
        --name-IDs='*'
    cp "$dest" "$WRITER_DIR/$name.ttf"
    before=$(du -h "$src" | cut -f1)
    after=$(du -h "$dest" | cut -f1)
    echo "$name.ttf: $before -> $after"
done
