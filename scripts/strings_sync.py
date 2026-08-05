#!/usr/bin/env python3
"""Keep Localizable.strings in step with the `L10n` calls in the source.

Luna's user-facing copy lives in ONE hand-editable file,
`LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`.
Every entry reads

    "the original English" = "what Luna actually shows";

The KEY is the literal that sits in the Swift source and never changes; the
VALUE is the copy, and is the only half anyone edits. A key with no entry —
or an entry someone truncated mid-edit — falls back to the key, so the worst
case is the original English rather than a blank or a raw identifier.

This script is the bridge between the two. It parses every `L10n.string(…)` /
`L10n.resource(…)` literal out of the Swift sources and compares that set with
the file's keys.

    strings_sync.py --check    report drift, exit 1 if any     (what CI/tests run)
    strings_sync.py --write    add missing keys, re-group, re-sort
    strings_sync.py --list     print the scanned keys and where they come from

Interpolated copy needs a decision a script cannot make: `"Links (\\(count))"`
could be `%lld` or `%@`. Those are reported for a human to add once, by hand.
`--seed` takes the format-correct keys out of the old .xcstrings catalogs, which
is how the file was first populated.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS_PATH = os.path.join(
    REPO, "LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings")

# Directories holding shipping code. Tests are deliberately absent: a test may
# reference copy, but it never DEFINES any.
SOURCE_ROOTS = [
    "Luna",
    "LunaLibraries/Sources",
    "LunaReaderClip",
    "LunaDownloaderClip",
    "LunaShare",
    "LunaAction",
    "LunaSafari",
    "LunaDownloaderLiveActivity",
    "LunaLiveActivity",
]

# Where a key's section header comes from. First match wins, so the specific
# app-shell paths are listed ahead of the catch-all module names.
SECTIONS = [
    ("Luna/Reader/Onboarding", "Onboarding"),
    ("Luna/UtilCard/WeeklyPromotionMenu.swift", "Save of the Week"),
    ("Luna/UtilCard", "Onboarding"),
    ("Luna/Settings", "Settings"),
    ("Luna/Diagnostics", "Settings · Diagnostics"),
    ("Luna/Mail", "Email & Sending"),
    ("Luna/MiniPlayer", "Reader · Audio"),
    ("Luna/Reader", "Reader"),
    ("Luna/Downloader", "Downloads & Media"),
    ("Luna/PriceTracker", "Price Tracker"),
    ("Luna/CardCarouselHost", "Card Deck"),
    ("Luna/ReadingList", "Card Deck"),
    ("LunaShare", "Share & Action Extensions"),
    ("LunaAction", "Share & Action Extensions"),
    ("LunaReaderClip", "App Clips"),
    ("LunaDownloaderClip", "App Clips"),
    ("LunaDownloaderLiveActivity", "Live Activity"),
    ("LunaLiveActivity", "Live Activity"),
    ("LunaShareSurface", "Share & Action Extensions"),
    ("LunaReaderUI", "Reader"),
    ("LunaArchiveReader", "Reader"),
    ("LunaAudioPlayback", "Reader · Audio"),
    ("LunaSend", "Reader · Export & Send"),
    ("LunaEpub", "Reader · Export & Send"),
    ("LunaMediaDownload", "Downloads & Media"),
    ("LunaPlatforms", "Downloads & Media"),
    ("LunaPriceUI", "Price Tracker"),
    ("LunaPriceIngest", "Price Tracker"),
    ("LunaMailAccount", "Email & Sending"),
    ("LunaMailTransport", "Email & Sending"),
    ("LunaMail", "Email & Sending"),
    ("LunaSocialUI", "Sharing with Friends"),
    ("LunaSocial", "Sharing with Friends"),
    ("LunaWeekly", "Save of the Week"),
    ("LunaDesignSystem", "Shared UI"),
    ("LunaReadingListUI", "Card Deck"),
    ("LunaReadingList", "Card Deck"),
    ("LunaStorage", "Card Deck"),
    ("LunaModels", "Shared UI"),
    ("LunaFetch", "Save Failures"),
    ("LunaHTMLClassification", "Save Failures"),
]
FALLBACK_SECTION = "Other"

SECTION_ORDER = [
    "Onboarding",
    "Card Deck",
    "Reader",
    "Reader · Audio",
    "Reader · Export & Send",
    "Downloads & Media",
    "Price Tracker",
    "Email & Sending",
    "Sharing with Friends",
    "Save of the Week",
    "Share & Action Extensions",
    "App Clips",
    "Live Activity",
    "Save Failures",
    "Settings",
    "Settings · Diagnostics",
    "Shared UI",
    FALLBACK_SECTION,
]

INTERP = "\x00INTERP\x00"  # stands in for `\(…)` while a literal is parsed

CALL_RE = re.compile(r"\bL10n\.(?:string|resource)\(")

# App Intents metadata is the one family of copy that cannot be an L10n call:
# Xcode extracts it at BUILD time and the metadata processor rejects anything
# that isn't a string literal. The literals still resolve against a strings
# table at runtime, so they belong in the same file — they just have to be
# found by shape instead of by call. Only these files are searched this way,
# because `title:` and `description:` are far too common to match globally.
INTENT_SOURCES = ("Luna/Mail/Intents/", "LiveActivityWidget.swift")

INTENT_RES = [
    # static let title: LocalizedStringResource = "…"
    re.compile(r"\bstatic\s+(?:let|var)\s+\w+\s*:\s*LocalizedStringResource\s*=\s*"),
    # static let typeDisplayRepresentation: TypeDisplayRepresentation = "…"
    re.compile(r"\bstatic\s+(?:let|var)\s+\w+\s*:\s*TypeDisplayRepresentation\s*=\s*"),
    # IntentDescription("…") — often a multi-line literal
    re.compile(r"\bIntentDescription\(\s*"),
    # @Parameter(title: "…", description: "…") / @Property(title: "…")
    re.compile(r"(?<=[(,\s])(?:title|description)\s*:\s*(?=\")"),
]


# --------------------------------------------------------------------------
# Swift literal parsing


def parse_swift_literal(text: str, start: int):
    """Read the Swift string literal beginning at `text[start] == '"'`.

    Returns `(resolved, had_interpolation, index_after_literal)`, where escapes
    are resolved to the characters they stand for (so the result compares equal
    to a key read out of the file) and each `\\(…)` becomes one INTERP marker.
    Returns None if this is not a plain single-line literal — a triple-quoted
    block or an unterminated run — which the caller skips rather than guesses at.
    """
    if text.startswith('"""', start):
        return None
    if start >= len(text) or text[start] != '"':
        return None

    out = []
    had_interp = False
    i = start + 1
    simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}

    while i < len(text):
        ch = text[i]
        if ch == '"':
            return "".join(out), had_interp, i + 1
        if ch == "\n":
            return None  # ran off the end of the line: not a plain literal
        if ch != "\\":
            out.append(ch)
            i += 1
            continue

        # An escape sequence.
        if i + 1 >= len(text):
            return None
        nxt = text[i + 1]
        if nxt == "(":
            # Interpolation. Balance parens, ignoring anything inside a nested
            # string literal so that `\(a ?? "b)c")` does not end early.
            had_interp = True
            out.append(INTERP)
            depth = 0
            j = i + 1
            in_str = False
            while j < len(text):
                c = text[j]
                if in_str:
                    if c == "\\":
                        j += 2
                        continue
                    if c == '"':
                        in_str = False
                elif c == '"':
                    in_str = True
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= len(text):
                return None
            i = j + 1
            continue
        if nxt == "u" and i + 2 < len(text) and text[i + 2] == "{":
            close = text.find("}", i + 3)
            if close == -1:
                return None
            out.append(chr(int(text[i + 3:close], 16)))
            i = close + 1
            continue
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        return None

    return None


def parse_swift_multiline(text: str, start: int):
    """Read the `\"\"\"`-delimited literal beginning at `start`.

    Swift strips the indentation of the CLOSING delimiter from every line, and
    a trailing backslash joins a line to the next without a break — which is
    how the long intent descriptions are written. Returns
    `(resolved, had_interpolation, index_after_literal)`.
    """
    body_start = text.find("\n", start + 3)
    if body_start == -1:
        return None
    close = text.find('"""', body_start)
    if close == -1:
        return None

    # The closing delimiter's own indentation is the margin to strip.
    line_start = text.rfind("\n", 0, close) + 1
    margin = text[line_start:close]
    if margin.strip():
        return None  # closing quotes share a line with content: not our shape

    raw_lines = text[body_start + 1:line_start].split("\n")
    # The newline before the closing delimiter is Swift's, not the string's.
    if raw_lines and raw_lines[-1] == "":
        raw_lines.pop()
    out, had_interp = [], False
    for raw in raw_lines:
        line = raw[len(margin):] if raw.startswith(margin) else raw.lstrip()
        joins = line.endswith("\\")
        if joins:
            line = line[:-1]
        if "\\(" in line:
            had_interp = True
            line = re.sub(r"\\\([^)]*\)", INTERP, line)
        out.append(line + ("" if joins else "\n"))

    resolved = "".join(out)
    if resolved.endswith("\n"):
        resolved = resolved[:-1]  # the final newline belongs to the delimiter
    return resolved, had_interp, close + 3


def _literal_at(text: str, i: int):
    """Parse whichever literal shape starts at `i`, skipping leading space."""
    while i < len(text) and text[i] in " \t\n":
        i += 1
    if text.startswith('"""', i):
        return parse_swift_multiline(text, i)
    return parse_swift_literal(text, i)


def scan_source(path: str, rel: str):
    """Yield (pattern, had_interpolation, line_number) for each literal."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    matchers = list(CALL_RE.finditer(text))
    if any(marker in rel for marker in INTENT_SOURCES):
        for regex in INTENT_RES:
            matchers.extend(regex.finditer(text))

    for match in sorted(matchers, key=lambda m: m.start()):
        # The literal may sit on a following line, as it does when a call is
        # wrapped for line length.
        parsed = _literal_at(text, match.end())
        if parsed is None:
            continue
        pattern, had_interp, _ = parsed
        line = text.count("\n", 0, match.start()) + 1
        yield pattern, had_interp, line


def scan_sources(repo: str):
    """Map pattern -> {"interp": bool, "sites": [(relpath, line), …]}."""
    found = {}
    for root in SOURCE_ROOTS:
        base = os.path.join(repo, root)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in {".build", "build"}]
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, repo)
                for pattern, interp, line in scan_source(full, rel):
                    entry = found.setdefault(pattern, {"interp": interp, "sites": []})
                    entry["sites"].append((rel, line))
    return found


# --------------------------------------------------------------------------
# .strings reading and writing


STRINGS_ENTRY_RE = re.compile(
    r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.DOTALL)


def unescape(value: str) -> str:
    out = []
    i = 0
    simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            out.append(simple.get(value[i + 1], value[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def escape(value: str) -> str:
    return (value.replace("\\", "\\\\")
                 .replace('"', '\\"')
                 .replace("\n", "\\n")
                 .replace("\t", "\\t"))


def read_strings(path: str):
    """Return an ordered dict of key -> value, tolerating comments."""
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    # Strip block comments so a commented-out example is never read as an entry.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    entries = {}
    for match in STRINGS_ENTRY_RE.finditer(text):
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries


def section_for(sites) -> str:
    for rel, _ in sites:
        for needle, section in SECTIONS:
            if needle in rel:
                return section
    return FALLBACK_SECTION


def write_strings(path: str, entries: dict, sites_by_key: dict):
    grouped = defaultdict(list)
    for key, value in entries.items():
        grouped[section_for(sites_by_key.get(key, []))].append((key, value))

    order = [s for s in SECTION_ORDER if s in grouped]
    order += sorted(s for s in grouped if s not in SECTION_ORDER)

    out = [
        "/*",
        " * Luna — every user-visible string, in one file.",
        " *",
        " * Each line is:   \"original English\" = \"what Luna shows\";",
        " *",
        " * EDIT ONLY THE RIGHT-HAND SIDE. The left-hand side is the key the code",
        " * looks up; changing it just detaches the line and the app falls back to",
        " * showing the key. Keep every  %@  %lld  %1$@  marker present and in the",
        " * same order — they are where names, counts and dates get substituted.",
        " *",
        " * Keep the surrounding  \"  =  \"  ;  punctuation intact. A line that loses",
        " * its trailing  ;  takes the rest of its section down with it.",
        " *",
        " * Regenerate the grouping with:  scripts/strings_sync.py --write",
        " */",
        "",
    ]
    for section in order:
        out.append(f"/* ===================== {section} ===================== */")
        for key, value in sorted(grouped[section], key=lambda kv: kv[0].lower()):
            out.append(f'"{escape(key)}" = "{escape(value)}";')
        out.append("")

    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))


# --------------------------------------------------------------------------
# Matching interpolated call sites to keys


def pattern_to_regex(pattern: str) -> re.Pattern:
    # A percent sign written literally in the source is doubled in the format
    # string the compiler derives, so accept either spelling.
    parts = [re.escape(p).replace("%", "%%?") for p in pattern.split(INTERP)]
    # A substituted value is a format specifier: %@, %lld, %1$@, %.2f…
    return re.compile("^" + r"%[0-9]*\$?[0-9.]*(?:ll)?[@dfsu]".join(parts) + "$")


def resolve(found: dict, keys) -> tuple[dict, list]:
    """Map each scanned pattern to a concrete key, where one exists."""
    keys = list(keys)
    literal = {k: k for k in keys}
    resolved, unresolved = {}, []
    for pattern, meta in found.items():
        if not meta["interp"]:
            if pattern in literal:
                resolved[pattern] = pattern
            else:
                unresolved.append((pattern, meta, None))
            continue
        rx = pattern_to_regex(pattern)
        hits = [k for k in keys if rx.match(k)]
        if len(hits) == 1:
            resolved[pattern] = hits[0]
        else:
            unresolved.append((pattern, meta, hits))
    return resolved, unresolved


def placeholder_key(pattern: str) -> str:
    """A best-guess key for an interpolated string, for the report only."""
    return pattern.replace(INTERP, "%@")


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report drift; exit 1 if any")
    mode.add_argument("--write", action="store_true", help="add missing keys and re-sort")
    mode.add_argument("--list", action="store_true", help="print scanned keys and sites")
    ap.add_argument("--seed", nargs="*", metavar="XCSTRINGS",
                    help="seed keys/values from .xcstrings catalogs (migration only)")
    ap.add_argument("--repo", default=REPO)
    args = ap.parse_args()

    found = scan_sources(args.repo)
    entries = read_strings(STRINGS_PATH)

    seeded = {}
    if args.seed:
        for path in args.seed:
            with open(path, encoding="utf-8") as handle:
                catalog = json.load(handle)
            for key, body in catalog.get("strings", {}).items():
                unit = body.get("localizations", {}).get("en", {}).get("stringUnit", {})
                seeded[key] = unit.get("value") or key

    known = set(entries) | set(seeded)
    resolved, unresolved = resolve(found, known)

    if args.list:
        for pattern, meta in sorted(found.items()):
            rel, line = meta["sites"][0]
            key = resolved.get(pattern, placeholder_key(pattern))
            print(f"{rel}:{line}\t{key!r}")
        print(f"\n{len(found)} literals, {len(resolved)} resolved to a key")
        return 0

    used_keys = set(resolved.values())
    sites_by_key = {resolved[p]: found[p]["sites"] for p in resolved}

    orphans = sorted(k for k in entries if k not in used_keys)
    missing = [(p, m) for p, m, _ in unresolved]

    if args.write:
        merged = {}
        for key in used_keys:
            merged[key] = entries.get(key, seeded.get(key, key))
        # Literal (non-interpolated) call sites with no entry yet: adopt them,
        # with the source literal as both key and value.
        for pattern, meta in missing:
            if not meta["interp"]:
                merged[pattern] = seeded.get(pattern, pattern)
                sites_by_key[pattern] = meta["sites"]
        write_strings(STRINGS_PATH, merged, sites_by_key)
        print(f"wrote {len(merged)} entries to "
              f"{os.path.relpath(STRINGS_PATH, args.repo)}")
        left = [(p, m) for p, m in missing if m["interp"]]
        if left:
            print(f"\n{len(left)} interpolated literal(s) still need a key by hand:")
            for pattern, meta in sorted(left, key=lambda x: x[1]["sites"][0]):
                rel, line = meta["sites"][0]
                print(f"  {rel}:{line}\n    suggested: \"{placeholder_key(pattern)}\"")
        if orphans:
            print(f"\n{len(orphans)} entry(ies) no longer referenced by any code:")
            for key in orphans[:20]:
                print(f"  {key!r}")
        return 0

    # --check
    problems = 0
    if missing:
        problems += len(missing)
        print(f"{len(missing)} string(s) in code with no entry in "
              f"{os.path.relpath(STRINGS_PATH, args.repo)}:")
        for pattern, meta in sorted(missing, key=lambda x: x[1]["sites"][0]):
            rel, line = meta["sites"][0]
            print(f"  {rel}:{line}  \"{placeholder_key(pattern)}\"")
    if orphans:
        problems += len(orphans)
        print(f"\n{len(orphans)} entry(ies) with no code referencing them:")
        for key in orphans:
            print(f"  {key!r}")
    if problems:
        print("\nRun  scripts/strings_sync.py --write  to reconcile.")
        return 1
    print(f"in sync — {len(entries)} entries, {len(found)} call sites")
    return 0


if __name__ == "__main__":
    sys.exit(main())
