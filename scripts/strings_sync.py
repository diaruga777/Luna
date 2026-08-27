#!/usr/bin/env python3
"""Keep Localizable.strings in step with the `L10n` calls in the source.

Luna's user-facing copy lives in ONE hand-editable file,
`LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`.
A call site names a bare, descriptive KEY — never the English text —
e.g. `L10n.string("Onboarding_Util_headline")`. Every base key the code
references must have at least one entry

    "<key>_Luna" = "what Luna shows";

which is the universal default `L10n` falls back to. Any app can override it
by adding one more line for its own suffix — `_Core` (the central Luna app),
`_Reader`, `_Downloader`, `_PriceTracker`, or `_Vault` — with NO Swift change at all.

Grouping and the comments above each group are HAND-AUTHORED — that is the
point of the file being organized by screen and reading order — so this
script never re-sorts or re-groups on `--write`. Its only jobs:

    strings_sync.py --check    report drift; exit 1 if any     (what CI runs)
    strings_sync.py --write    append missing keys as placeholders,
                                drop lines for keys no code references
    strings_sync.py --list     print the scanned keys and where they come from

A handful of App Intents literals (`static let title: LocalizedStringResource
= "…"`, `IntentDescription(...)`, `@Parameter`/`@Property` `title:`/
`description:`) can't be `L10n` calls at all — Xcode's metadata processor
extracts them at BUILD time and rejects anything that isn't a literal, so they
carry a concrete, already-suffixed key (usually `..._Luna`) baked directly
into the Swift literal instead of a bare key `L10n` resolves at runtime. This
script still finds them, by shape, so `--check`/`--write` cover them too.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS_PATH = os.path.join(
    REPO, "LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings")

SUFFIXES = ("Luna", "Core", "Reader", "Downloader", "PriceTracker", "Vault")

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
    "LunaVault",
    "LunaVaultShare",
]

# Where a key most likely belongs, for a human fixing up a --check/--write
# report. Purely descriptive now — nothing auto-groups by this anymore.
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
    ("Luna/Saves", "Card Deck"),
    ("LunaShare", "Share & Action Extensions"),
    ("LunaAction", "Share & Action Extensions"),
    ("LunaReaderClip", "App Clips"),
    ("LunaDownloaderClip", "App Clips"),
    ("LunaDownloaderLiveActivity", "Live Activity"),
    ("LunaLiveActivity", "Live Activity"),
    ("LunaVault", "Vault"),
    ("LunaVaultShare", "Vault Share Extension"),
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
    ("LunaSocialUI", "Sharing with Friends"),
    ("LunaSocial", "Sharing with Friends"),
    ("LunaWeekly", "Save of the Week"),
    ("LunaDesignSystem", "Shared UI"),
    ("LunaSavesUI", "Card Deck"),
    ("LunaSaves", "Card Deck"),
    ("LunaStorage", "Card Deck"),
    ("LunaModels", "Shared UI"),
    ("LunaFetch", "Save Failures"),
    ("LunaHTMLClassification", "Save Failures"),
]
FALLBACK_SECTION = "Other"

CALL_RE = re.compile(r"\bL10n\.(?:string|resource)\(")

# App Intents metadata is the one family of copy that cannot be an L10n call:
# Xcode extracts it at BUILD time and the metadata processor rejects anything
# that isn't a string literal. Only these files are searched this way, and
# only for shapes the AppIntents build plugin actually treats as metadata —
# a plain `DisplayRepresentation(title: "\(x)")` VALUE at a normal call site
# is runtime content, not build-time metadata, and must not match here.
INTENT_SOURCES = ("Luna/Mail/Intents/", "LiveActivityWidget.swift")

INTENT_RES = [
    # static let title: LocalizedStringResource = "…"
    re.compile(r"\bstatic\s+(?:let|var)\s+\w+\s*:\s*LocalizedStringResource\s*=\s*"),
    # static let typeDisplayRepresentation: TypeDisplayRepresentation = "…"
    re.compile(r"\bstatic\s+(?:let|var)\s+\w+\s*:\s*TypeDisplayRepresentation\s*=\s*"),
    # IntentDescription("…") — often a multi-line literal
    re.compile(r"\bIntentDescription\(\s*"),
    # @Parameter(title: "…", description: "…") / @Property(title: "…") — matches
    # each `title:`/`description:` independently (not anchored to one
    # `@Parameter(`/`@Property(` match) so a multi-line call with both fields
    # is fully covered, not just its first field. Excludes `title:` right
    # after `DisplayRepresentation(` — that's a per-INSTANCE value built at
    # runtime (e.g. `DisplayRepresentation(title: "\(article.title)")`), not
    # build-time metadata, even though it sits in an intent-source file.
    re.compile(r"(?<!DisplayRepresentation\()(?<=[(,\s])(?:title|description)\s*:\s*(?=\")"),
]

# `OnboardingStrings.Definition`/`ChunkedDefinition` (LunaLibraries/…/Luna/Reader
# /Onboarding/OnboardingStrings.swift) resolve their key at `value(for:)` time via
# a stored variable — `L10n.string(key, for: app)` — so the literal key never
# appears at an `L10n` call site; it only appears at construction:
# `Definition(key: "…")` / `ChunkedDefinition(keyPrefix: "…")`. These need their
# own patterns so the scanner still sees them as referenced. A `ChunkedDefinition`
# only requires its FIRST chunk (`"<prefix>1"`) — later indices are optional and
# read until missing, so `..2`/`..3`/… are never "required".
DEFINITION_RE = re.compile(r"\bDefinition\(\s*key:\s*")
CHUNKED_DEFINITION_RE = re.compile(r"\bChunkedDefinition\(\s*keyPrefix:\s*")


# --------------------------------------------------------------------------
# Swift literal parsing


def parse_swift_literal(text: str, start: int):
    """Read the Swift string literal beginning at `text[start] == '"'`.

    Returns `(resolved, had_interpolation, index_after_literal)`, where escapes
    are resolved to the characters they stand for. Returns None if this is not
    a plain single-line literal — a triple-quoted block or an unterminated
    run — which the caller skips rather than guesses at.
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

        if i + 1 >= len(text):
            return None
        nxt = text[i + 1]
        if nxt == "(":
            had_interp = True
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

    Returns `(resolved, had_interpolation, index_after_literal)`.
    """
    body_start = text.find("\n", start + 3)
    if body_start == -1:
        return None
    close = text.find('"""', body_start)
    if close == -1:
        return None

    line_start = text.rfind("\n", 0, close) + 1
    margin = text[line_start:close]
    if margin.strip():
        return None

    raw_lines = text[body_start + 1:line_start].split("\n")
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
        out.append(line + ("" if joins else "\n"))

    resolved = "".join(out)
    if resolved.endswith("\n"):
        resolved = resolved[:-1]
    return resolved, had_interp, close + 3


def _literal_at(text: str, i: int):
    while i < len(text) and text[i] in " \t\n":
        i += 1
    if text.startswith('"""', i):
        return parse_swift_multiline(text, i)
    return parse_swift_literal(text, i)


def scan_source(path: str, rel: str):
    """Yield (key, had_interpolation, line_number, is_intent_literal, chunk_prefix).

    `chunk_prefix` is the raw `ChunkedDefinition(keyPrefix: …)` literal (before
    `"1"` is appended to make it a required key) when this match is one, else
    `None`.
    """
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    # (end-of-match index, is_intent_literal, is_chunked_prefix)
    matchers = [(m.end(), False, False) for m in CALL_RE.finditer(text)]
    matchers += [(m.end(), False, False) for m in DEFINITION_RE.finditer(text)]
    matchers += [(m.end(), False, True) for m in CHUNKED_DEFINITION_RE.finditer(text)]
    if any(marker in rel for marker in INTENT_SOURCES):
        for regex in INTENT_RES:
            matchers.extend((m.end(), True, False) for m in regex.finditer(text))

    for end, is_intent, is_chunked in sorted(matchers, key=lambda m: m[0]):
        parsed = _literal_at(text, end)
        if parsed is None:
            continue
        key, had_interp, _ = parsed
        chunk_prefix = key if is_chunked else None
        if is_chunked:
            key = key + "1"  # only the first chunk is ever required
        line = text.count("\n", 0, end) + 1
        yield key, had_interp, line, is_intent, chunk_prefix


def scan_sources(repo: str):
    """Map base-key -> {"interp": bool, "intent": bool, "sites": [(rel, line), …]}.

    For a normal `L10n` call the base key is the literal itself (no suffix
    yet — that's resolved at runtime). For an intent-metadata literal the key
    already IS the full, concrete, suffixed key (there is no runtime
    resolution for these), so it is stored and checked the same way a
    `"<key>_Luna"` entry would be, just under its own literal name.

    Also returns the set of `ChunkedDefinition` key prefixes found, so a
    caller can recognize `"<prefix>2"`, `"<prefix>3"`, … as legitimately
    referenced even though only `"<prefix>1"` is ever a REQUIRED entry — a
    later chunk is read at runtime until one is missing, so it's real, just
    not statically countable.
    """
    found = {}
    chunk_prefixes = set()
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
                for key, interp, line, is_intent, chunk_prefix in scan_source(full, rel):
                    entry = found.setdefault(
                        key, {"interp": interp, "intent": is_intent, "sites": []})
                    entry["sites"].append((rel, line))
                    if chunk_prefix is not None:
                        chunk_prefixes.add(chunk_prefix)
    return found, chunk_prefixes


# --------------------------------------------------------------------------
# .strings reading


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
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    entries = {}
    for match in STRINGS_ENTRY_RE.finditer(text):
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries


def base_key_and_suffix(entry_key: str):
    """Split `"Foo_Reader"` into `("Foo", "Reader")`, or `(entry_key, None)`
    if it doesn't end in a known suffix."""
    for suffix in SUFFIXES:
        tail = "_" + suffix
        if entry_key.endswith(tail) and len(entry_key) > len(tail):
            return entry_key[:-len(tail)], suffix
    return entry_key, None


def section_for(sites) -> str:
    for rel, _ in sites:
        for needle, section in SECTIONS:
            if needle in rel:
                return section
    return FALLBACK_SECTION


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report drift; exit 1 if any")
    mode.add_argument("--write", action="store_true",
                       help="append missing keys as placeholders; drop unreferenced lines")
    mode.add_argument("--list", action="store_true", help="print scanned keys and sites")
    ap.add_argument("--repo", default=REPO)
    args = ap.parse_args()

    found, chunk_prefixes = scan_sources(args.repo)
    entries = read_strings(STRINGS_PATH)

    if args.list:
        for key, meta in sorted(found.items()):
            rel, line = meta["sites"][0]
            print(f"{rel}:{line}\t{key!r}"
                  + ("\t[interpolated key — invalid]" if meta["interp"] else "")
                  + ("\t[intent literal]" if meta["intent"] else ""))
        print(f"\n{len(found)} distinct keys scanned")
        return 0

    # A key with `had_interp` means the LITERAL passed to L10n.string/resource
    # (or found by intent shape) itself contains `\(...)` — under the new
    # system that is always wrong: a key must be static text, with any
    # substitution passed as a separate arg.
    interpolated_keys = [(k, m) for k, m in found.items() if m["interp"]]

    # For a normal call, the required entry is "<key>_Luna". For an intent
    # literal, the key IS already the full entry name (no _Luna appended).
    required = {}
    for key, meta in found.items():
        if meta["interp"]:
            continue
        required[key if meta["intent"] else f"{key}_Luna"] = (key, meta)

    missing = [(entry, key, meta) for entry, (key, meta) in required.items()
               if entry not in entries]

    referenced_bases = {key for key, meta in found.items() if not meta["intent"]}

    def is_later_chunk(base: str) -> bool:
        """`"<prefix>2"`, `"<prefix>3"`, … for a known `ChunkedDefinition`
        prefix — real at runtime, never provably "referenced" beyond chunk 1
        (see `scan_sources`), so never an orphan."""
        stripped = base.rstrip("0123456789")
        return stripped != base and stripped in chunk_prefixes

    orphans = []
    for entry_key in entries:
        base, suffix = base_key_and_suffix(entry_key)
        if suffix is None:
            orphans.append((entry_key, "unrecognized suffix"))
        elif base not in referenced_bases and entry_key not in found and not is_later_chunk(base):
            orphans.append((entry_key, "no code references it"))

    if args.write:
        if missing:
            with open(STRINGS_PATH, "a", encoding="utf-8") as handle:
                handle.write("\n/* ===================== NEEDS REVIEW "
                              "(added by --write; write the real copy and move "
                              "this into its proper section) ===================== */\n")
                for entry, key, meta in sorted(missing):
                    handle.write(f'"{escape(entry)}" = "{escape(entry)}";\n')
            print(f"appended {len(missing)} placeholder entry(ies) — "
                  f"fill in real copy and move each into its section:")
            for entry, key, meta in sorted(missing):
                rel, line = meta["sites"][0]
                print(f"  {entry!r}  ({rel}:{line}, section guess: {section_for(meta['sites'])})")
        if orphans:
            text = open(STRINGS_PATH, encoding="utf-8").read()
            for entry_key, _ in orphans:
                pattern = re.compile(
                    r'\n?"' + re.escape(escape(entry_key)) + r'"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\n?')
                text = pattern.sub("\n", text, count=1)
            with open(STRINGS_PATH, "w", encoding="utf-8") as handle:
                handle.write(text)
            print(f"removed {len(orphans)} unreferenced entry(ies)")
        if interpolated_keys:
            print(f"\n{len(interpolated_keys)} call site(s) pass an interpolated literal as "
                  f"the KEY — not written, fix by hand:")
            for key, meta in sorted(interpolated_keys, key=lambda x: x[1]["sites"][0]):
                rel, line = meta["sites"][0]
                print(f"  {rel}:{line}")
        if not missing and not orphans and not interpolated_keys:
            print("nothing to do — already in sync")
        return 0

    # --check
    problems = 0
    if interpolated_keys:
        problems += len(interpolated_keys)
        print(f"{len(interpolated_keys)} call site(s) pass an interpolated literal as the KEY "
              f"(pass a static key and separate args instead):")
        for key, meta in sorted(interpolated_keys, key=lambda x: x[1]["sites"][0]):
            rel, line = meta["sites"][0]
            print(f"  {rel}:{line}")
    if missing:
        problems += len(missing)
        print(f"\n{len(missing)} required entry(ies) missing from "
              f"{os.path.relpath(STRINGS_PATH, args.repo)}:")
        for entry, key, meta in sorted(missing):
            rel, line = meta["sites"][0]
            print(f"  {entry!r}  ({rel}:{line})")
    if orphans:
        problems += len(orphans)
        print(f"\n{len(orphans)} entry(ies) with no code referencing them:")
        for entry_key, why in orphans:
            print(f"  {entry_key!r}  ({why})")
    if problems:
        print("\nRun  scripts/strings_sync.py --write  to reconcile "
              "(missing entries still need real copy written by hand).")
        return 1
    print(f"in sync — {len(entries)} entries, {len(found)} scanned keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
