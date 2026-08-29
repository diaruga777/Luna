#!/usr/bin/env python3
"""Pick the LunaTests classes worth running for a working-tree diff.

Every test in the project lives in the ONE `LunaTests` bundle hosted on the
central Luna app, so a partial run is a list of `-only-testing:` flags and
nothing else. This script produces that list, and — just as importantly —
refuses to produce a short one when it cannot explain its own choice.

How a changed file reaches a test class, in the order the rules are tried:

  1. The file IS a test file        -> its own classes.
  2. Name convention                -> `Foo.swift` selects `FooTests`,
                                       `FooViewController.swift` also tries
                                       `FooTests`/`FooViewControllerTests`.
  3. Symbol reference               -> every top-level type the file declares
                                       is grepped for across LunaTests; a test
                                       file that names one is selected.
  4. A hand-kept table (`PATH_RULES`) for the non-Swift inputs and the few
     whole-area files whose blast radius is wider than their symbols.

Anything a rule does not recognize is a FAILURE, not a silence: the script
prints what it could not place and exits 3, which `run_tests.sh --changed`
turns into a full-suite run with a warning. Under-selecting quietly is the one
failure mode a tool like this must not have.

Usage:
    scripts/select_changed_tests.py [<base-ref>]        # default: HEAD

Prints one `-only-testing:LunaTests/<Class>` per line on stdout and the
reasoning on stderr. Exit 0 = a selection, 3 = fall back to the full suite,
4 = nothing to test at all.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS_DIR = os.path.join(REPO, "LunaTests")

# Always run these, whatever changed: they are the invariants a change in any
# corner of the project can break, and together they cost a couple of seconds.
CORE_CLASSES = ["KindCompositionRootTests"]

# Non-Swift inputs, and the few files whose reach is wider than their symbols.
# A pattern is a regex matched against the repo-relative path. `None` as the
# class list means "this file cannot affect the tests" (docs, scripts).
# `FULL` means "run everything".
FULL = "\0FULL\0"

PATH_RULES: list[tuple[str, object]] = [
    # Anything that redefines the build graph itself.
    (r"^Luna\.xcodeproj/", FULL),
    (r"^LunaLibraries/Package\.swift$", FULL),
    (r"^Config/.*\.xcconfig$", FULL),
    # The one strings file, and the scripts that police it. Onboarding is in
    # here because its Safari page FITS its prose to the screen — a longer
    # chunk one is a layout change, not just a copy change.
    (r"Resources/en\.lproj/Localizable\.strings$", ["LocalizableStringsTests",
                                                    "ReaderOnboardingTests"]),
    (r"^scripts/strings_sync\.py$", ["LocalizableStringsTests"]),
    (r"^scripts/add_strings_to_app_bundles\.rb$", ["LocalizableStringsTests"]),
    # Layout geometry is pinned from two directions at once.
    (r"LaunchScreen\.storyboard$", ["LaunchScreenGeometryTests", "CardDeckGeometryTests"]),
    (r"^Luna/CardCarouselHost/", ["CardDeckGeometryTests", "LaunchScreenGeometryTests",
                                  "CardCarouselHostViewControllerTests",
                                  "CardCarouselMetricsTests"]),
    # The Safari extension's JavaScript and its generated rule tables. Every
    # suite that EVALUATES content.js belongs here: the three parity/label ones
    # alone let a change to the in-page UI (the pill, the player, the product
    # pills) through a green partial run.
    (r"^LunaSafari/Resources/.*\.(js|json)$", ["SafariPillLabelTests",
                                               "SafariMediaPillTests", "SafariVideoOverlayTests",
                                               "SafariRedditGatingTests",
                                               "SafariArticleHeuristicTests",
                                               "SafariSubscribeInterstitialTests",
                                               "SafariIndexVetoParityTests",
                                               "ProductHistoryPillRenderTests",
                                               "PlatformHostsJSFixtureParityTests",
                                               "ProductPageJSFixtureParityTests",
                                               "ProductSnapshotJSFixtureParityTests",
                                               "SafariAnnoyanceSuppressionTests",
                                               "SafariAnnoyanceGateContractTests"]),
    # The annoyance stylesheet is not decoration: it IS the pre-paint consent
    # hide, and the cookie off switch works by making its one gating attribute
    # stop matching — which the suppression suite asserts against this file.
    (r"^LunaSafari/Resources/.*\.css$", ["SafariAnnoyanceSuppressionTests",
                                         "SafariAnnoyanceGateContractTests"]),
    (r"^LunaLibraries/Sources/LunaPaywallBypass/Resources/", ["SiteUnlockTests"]),
    # The bundled seller directory: validated as SHIPPED, and it is the seller
    # universe the candidate ranking draws from.
    (r"^LunaLibraries/Sources/LunaPriceCompare/Resources/", ["SellerDirectoryTests",
                                                             "SellerCandidateSelectorTests"]),
    # Entitlements/Info.plists change what a surface may do, not what it computes.
    (r"\.entitlements$", ["KindCompositionRootTests"]),
    (r"Info\.plist$", ["KindCompositionRootTests"]),
    # Bundled resources. The mock pages and guide videos are onboarding's
    # furniture; the .shortcut files' NAMES are asserted against BundledShortcut,
    # but that assertion has no dedicated test class today (BundledShortcutTests /
    # ShortcutSettingsTests were folded away) — nothing currently maps a
    # `.shortcut` rename to a test, so this is an explicit no-op rather than a
    # stale class name silently selecting zero tests.
    (r"^Luna/Resources/.*\.shortcut$", None),
    (r"^Luna/Resources/", ["ReaderOnboardingTests", "OnboardingSaveDemoTests"]),
    # Test inputs: whichever test names the fixture is the one that reads it.
    (r"^LunaTests/Fixtures/", "SYMBOL"),
    (r"^Fixtures/Vault/manifest\.json$", ["VaultScaffoldTests"]),
    (r"^LunaLibraries/Sources/LunaVault", ["VaultScaffoldTests", "VaultCryptoStorageTests", "VaultSearchTests"]),
    (r"^LunaTests/VaultSearchTests\.swift$", ["VaultSearchTests"]),
    (r"^LunaTests/ReferenceImages/", "SYMBOL"),
    # Inputs that cannot move a test result.
    (r"^claudedocs/", None),
    (r"^refactor-plans/", None),
    (r"\.md$", None),
    (r"^scripts/", None),
    (r"^\.gitignore$", None),
    (r"^SharedIconAssets\.xcassets/", None),
    (r"\.xcassets/", None),
    # The Cloudflare Pages site: generated from the strings file and the icons,
    # shipped to a web host, linked by no target.
    (r"^site/", None),
    (r"^wrangler\.toml$", None),
]

DECL_RE = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|@\w+\s+)*"
    r"(?:class|struct|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)",
    re.MULTILINE,
)
TEST_CLASS_RE = re.compile(r"^(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase", re.MULTILINE)


def run(*args: str) -> str:
    return subprocess.run(
        args, cwd=REPO, capture_output=True, text=True, check=False
    ).stdout


def changed_files(base: str) -> list[str]:
    """Everything that differs from `base`, including uncommitted work."""
    names = set()
    for cmd in (("git", "diff", "--name-only", base),
                ("git", "diff", "--name-only", "--cached"),
                ("git", "diff", "--name-only")):
        names.update(line for line in run(*cmd).splitlines() if line)
    names.update(
        line[3:] for line in run("git", "status", "--porcelain").splitlines()
        if line.startswith("?? ")
    )
    return sorted(names)


def test_files() -> dict[str, list[str]]:
    """LunaTests file -> the XCTestCase classes it declares."""
    out: dict[str, list[str]] = {}
    for name in sorted(os.listdir(TESTS_DIR)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(TESTS_DIR, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            classes = TEST_CLASS_RE.findall(handle.read())
        out[name] = classes
    return out


def declared_types(rel_path: str) -> list[str]:
    path = os.path.join(REPO, rel_path)
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as handle:
        return sorted(set(DECL_RE.findall(handle.read())))


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    files = changed_files(base)
    if not files:
        print(f"no changes against {base}", file=sys.stderr)
        return 4

    by_file = test_files()
    all_classes = {c for cs in by_file.values() for c in cs}
    classes_of_file = {f: cs for f, cs in by_file.items() if cs}

    selected: dict[str, set[str]] = defaultdict(set)   # class -> reasons
    unplaced: list[str] = []

    for rel in files:
        # --- rule 4 (checked first: it is the explicit override) -----------
        matched_rule = False
        for pattern, target in PATH_RULES:
            if not re.search(pattern, rel):
                continue
            matched_rule = True
            if target is None:
                break
            if target is FULL:
                print(f"{rel}: changes the build graph — full suite", file=sys.stderr)
                return 3
            if target == "SYMBOL":
                # A data file: whoever names it (with or without extension).
                stem = os.path.splitext(os.path.basename(rel))[0]
                hits = grep_tests(stem, by_file) or grep_tests(os.path.basename(rel), by_file)
                if hits:
                    for cls in hits:
                        selected[cls].add(f"{rel} (named by the test)")
                else:
                    unplaced.append(rel)
                break
            for cls in target:            # type: ignore[union-attr]
                if cls in all_classes:
                    selected[cls].add(f"{rel} (path rule)")
            break
        if matched_rule:
            continue

        if not rel.endswith(".swift"):
            unplaced.append(rel)
            continue

        # --- rule 1: a test file is its own answer -------------------------
        if rel.startswith("LunaTests/"):
            name = os.path.basename(rel)
            if name in classes_of_file:
                for cls in classes_of_file[name]:
                    selected[cls].add(f"{rel} (is a test)")
                continue
            # A helper file with no XCTestCase of its own: whoever names it.
            stem = name[:-6]
            hits = grep_tests(stem, by_file)
            if hits:
                for cls in hits:
                    selected[cls].add(f"{rel} (test helper used here)")
                continue
            unplaced.append(rel)
            continue

        # --- rule 2: name convention ---------------------------------------
        stem = os.path.basename(rel)[:-6]
        found = False
        for candidate in (f"{stem}Tests", re.sub(r"(ViewController|View|Controller|Store|"
                                                 r"Manager|Service|Coordinator)$", "", stem)
                          + "Tests"):
            if candidate in all_classes:
                selected[candidate].add(f"{rel} (name convention)")
                found = True

        # --- rule 3: symbol reference ---------------------------------------
        for symbol in declared_types(rel):
            for cls in grep_tests(symbol, by_file):
                selected[cls].add(f"{rel} (references {symbol})")
                found = True

        if not found:
            unplaced.append(rel)

    if unplaced:
        print("could not map these changed files to any test:", file=sys.stderr)
        for rel in unplaced:
            print(f"  {rel}", file=sys.stderr)
        print("falling back to the full suite", file=sys.stderr)
        return 3

    for cls in CORE_CLASSES:
        if cls in all_classes:
            selected[cls].add("always run")

    if not selected:
        print("nothing to test for these changes", file=sys.stderr)
        return 4

    print(f"selected {len(selected)} test class(es) for {len(files)} changed file(s):",
          file=sys.stderr)
    for cls in sorted(selected):
        why = "; ".join(sorted(selected[cls])[:3])
        print(f"  {cls:<44} <- {why}", file=sys.stderr)

    for cls in sorted(selected):
        print(f"-only-testing:LunaTests/{cls}")
    return 0


_GREP_CACHE: dict[str, list[str]] = {}


def grep_tests(symbol: str, by_file: dict[str, list[str]]) -> list[str]:
    """Test classes whose file mentions `symbol` as a whole word."""
    if symbol in _GREP_CACHE:
        return _GREP_CACHE[symbol]
    out = run("grep", "-rlw", "--include=*.swift", symbol, "LunaTests/")
    classes: list[str] = []
    for path in out.splitlines():
        classes.extend(by_file.get(os.path.basename(path), []))
    _GREP_CACHE[symbol] = classes
    return classes


if __name__ == "__main__":
    sys.exit(main())
