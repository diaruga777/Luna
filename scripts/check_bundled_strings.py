#!/usr/bin/env python3
"""Fail the build when a built copy of the strings table isn't the source table.

Luna keeps every user-visible string in ONE file,

    LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings

and that one file reaches a built app through several INDEPENDENT copy tasks:

  * SwiftPM's `.process("Resources")` on LunaModels produces
    `LunaLibraries_LunaModels.bundle/en.lproj/Localizable.strings`, and every
    app, extension, clip, widget and test bundle that links LunaModels embeds
    its own copy of that bundle — a nested app extension therefore carries a
    second, third, … copy inside the app that embeds it.
  * `scripts/add_strings_to_app_bundles.rb` puts the same source file in each
    app's and widget's own Resources phase (App Intents metadata resolves
    against the HOST bundle), so a `CopyStringsFile` task writes yet another
    copy at `<Bundle>.app/en.lproj/Localizable.strings` — this one converted to
    a binary plist rather than copied verbatim.

Every one of those is an up-to-date decision the build system makes on its own,
and none of them is observable from inside the app: a stale copy shows as
"my copy edit didn't take", which invites re-editing copy that was already
right, and at worst ships a table nobody wrote. This script is the one place
that checks the actual bytes on disk against the actual source, unconditionally,
on every build — it distrusts precisely the incremental logic that could skip a
copy.

Usage:

    check_bundled_strings.py <source.strings> <bundle-root> [<bundle-root>…]

Every `Localizable.strings` anywhere under each bundle root must carry the same
key/value table as the source. Comments, ordering and storage format are not
compared (a `.strings` file is an old-style plist; the app-root copies are
binary plists), so this compares what the app can actually READ.

Exits 0 when every copy agrees, 1 with `error:` lines Xcode surfaces otherwise.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys

TABLE_NAME = "Localizable.strings"


def read_table(path: str) -> dict[str, str]:
    """Parse a .strings file in any of its three on-disk formats.

    A source `.strings` is an old-style (OpenStep) plist, which `plistlib`
    cannot read, so everything goes through `plutil` first; that also means a
    binary-plist copy and a text copy of the same table parse to the same dict.
    """
    xml = subprocess.run(
        ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", path],
        capture_output=True,
        check=True,
    ).stdout
    table = plistlib.loads(xml)
    if not isinstance(table, dict):
        raise ValueError(f"{path}: not a key/value table")
    return table


def describe(source: dict[str, str], built: dict[str, str], limit: int = 3) -> str:
    """A short, concrete reason the two tables differ."""
    missing = sorted(set(source) - set(built))
    extra = sorted(set(built) - set(source))
    changed = sorted(k for k in set(source) & set(built) if source[k] != built[k])
    parts = []
    if changed:
        sample = ", ".join(
            f"{k!r} is {built[k]!r} but the source says {source[k]!r}"
            for k in changed[:limit]
        )
        parts.append(f"{len(changed)} value(s) differ ({sample})")
    if missing:
        parts.append(f"{len(missing)} key(s) missing (e.g. {', '.join(missing[:limit])})")
    if extra:
        parts.append(f"{len(extra)} stale key(s) (e.g. {', '.join(extra[:limit])})")
    return "; ".join(parts) or "the tables differ"


#: Nested bundles that are deliberately NOT checked.
#:
#: `.xctest` is the unit-test bundle, which a plain `xcodebuild build` does not
#: rebuild — in a derived-data path that has also run the suite it legitimately
#: lags behind, and it is never installed or shipped. The test build checks its
#: own copies from the inside (`LocalizableStringsTests`).
SKIPPED_SUFFIXES = (".dSYM", ".xctest")


def copies_under(root: str) -> list[str]:
    found = []
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = [d for d in subdirs if not d.endswith(SKIPPED_SUFFIXES)]
        if TABLE_NAME in files:
            found.append(os.path.join(directory, TABLE_NAME))
    return sorted(found)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(f"usage: {os.path.basename(argv[0])} <source.strings> <bundle-root>…",
              file=sys.stderr)
        return 2

    source_path, roots = argv[1], argv[2:]
    if not os.path.isfile(source_path):
        print(f"error: {source_path}: no such strings file", file=sys.stderr)
        return 1

    with open(source_path, "rb") as handle:
        source_bytes = handle.read()
    source = read_table(source_path)

    failures: list[str] = []
    checked = 0
    for root in roots:
        if not os.path.isdir(root):
            # Nothing built yet for this root — not this script's failure to
            # report; the build would already have failed.
            continue
        for path in copies_under(root):
            checked += 1
            with open(path, "rb") as handle:
                if handle.read() == source_bytes:
                    continue  # verbatim copy — no need to parse either side
            try:
                built = read_table(path)
            except (subprocess.CalledProcessError, ValueError, plistlib.InvalidFileException):
                failures.append(f"{path}: does not parse as a strings table")
                continue
            if built != source:
                failures.append(f"{path}: {describe(source, built)}")

    if not failures:
        return 0

    print(
        "error: a built copy of the strings table does not match "
        f"{source_path}. The build system reused a stale copy — the app would "
        "show wording nobody wrote. Delete the stale product and build again "
        "(for one app: rm -rf the .app in $BUILT_PRODUCTS_DIR; for all of "
        "them: use a clean -derivedDataPath).",
        file=sys.stderr,
    )
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
