#!/usr/bin/env python3
"""Builds the static luna.app site (Cloudflare Pages) from the app's own sources.

The only page it renders today is `/setup/<app>`, a static reproduction of the
mock `luna.app` page the in-app Safari lesson shows — the same headline, byline,
prose and four enable steps, drawn with the same chrome pictures and the app's
own icon.

Everything it prints comes from the shipping app rather than a copy:

  * copy   — `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`,
             resolved through the same `<base>_<suffix>` → `<base>_Luna` fallback
             `L10n.string(key, for:)` uses (see CLAUDE.md's strings rule).
  * icons  — the committed 1024px `AppIcon*` masters in `SharedIconAssets.xcassets`.
  * layout — the constants in `OnboardingSafariPageView` /
             `OnboardingSafariExplainerViews` (pt taken as px), and the palette in
             `OnboardingSafariPagePalette`.

The two things the page deliberately does NOT reproduce are the app's own
actions (“Activate Safari” / “Skip” are in-app navigation, not instructions) and
the SF Symbols in the step chips: SF Symbols may not be redistributed on the
web, so the page-menu and puzzle-piece glyphs are hand-drawn SVG stand-ins.

Unlike the app, the page has room to show every prose chunk the app's own
suffix earns rather than truncating to fit a screen — see `Copy.chunks` for
the one exception: a facet app (Reader/Downloader/PriceTracker) still stops
short of the family-marketing chunk that only makes sense on the central
app's own page.

Usage: python3 scripts/build_site.py [--out site/dist]
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STRINGS = (
    REPO
    / "LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings"
)
ICONS = REPO / "SharedIconAssets.xcassets"

# The universal fallback every base key defines.
FALLBACK_SUFFIX = "Luna"

# slug, L10n suffix, 1024px icon master. The slug is the URL: /setup/<slug>.
APPS = [
    ("luna", "Core", "AppIconLuna.appiconset/AppIconLuna1024.png"),
    ("reader", "Reader", "AppIconReader.appiconset/AppIconReader-1024.png"),
    (
        "downloader",
        "Downloader",
        "AppIconDownloader.appiconset/AppIconDownloader-1024.png",
    ),
    (
        "price-tracker",
        "PriceTracker",
        "AppIconPriceTracker.appiconset/AppIconPriceTracker-1024.png",
    ),
]

# Alternative spellings that should land on the canonical slug rather than a 404.
ALIASES = {
    "luna-reader": "reader",
    "lunareader": "reader",
    "luna-downloader": "downloader",
    "lunadownloader": "downloader",
    "luna-price-tracker": "price-tracker",
    "pricetracker": "price-tracker",
    "price": "price-tracker",
}

# What the icon is downscaled to. One file serves both the 60pt header icon and
# the 28pt step icon, at better than 3x for either.
ICON_PX = 256

# `OnboardingSafariPagePalette.background`, matched by <meta name="theme-color">
# so a phone's Safari chrome doesn't flash white around the page it's opening.
THEME_COLOR = "#4f5257"


# MARK: - Strings


def load_strings() -> dict[str, str]:
    """The flat `"key" = "value";` table, verbatim."""
    entry = re.compile(r'^"([^"]+)"\s*=\s*"(.*)"\s*;\s*$')
    table: dict[str, str] = {}
    for line in STRINGS.read_text(encoding="utf-8").splitlines():
        match = entry.match(line.strip())
        if not match:
            continue
        key, value = match.groups()
        table[key] = (
            value.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        )
    return table


class Copy:
    """`L10n.string(key, for: app)` — the app's suffix, then the `_Luna` one."""

    def __init__(self, table: dict[str, str], suffix: str):
        self.table = table
        self.suffix = suffix

    def optional(self, base: str) -> str | None:
        for suffix in (self.suffix, FALLBACK_SUFFIX):
            value = self.table.get(f"{base}_{suffix}")
            if value is not None:
                return value
        return None

    def string(self, base: str) -> str:
        value = self.optional(base)
        if value is None:
            raise SystemExit(f"missing string for key {base!r} ({self.suffix})")
        return value

    def chunks(self, prefix: str) -> list[str]:
        """A `ChunkedDefinition`: `<prefix>1`, `<prefix>2`, … until one is absent.

        The central Luna app (`_Core`) walks the whole chain, same as `L10n`
        does in Swift. A FACET app (Reader/Downloader/PriceTracker) stops one
        chunk earlier than that: it only keeps walking past a chunk that has
        no override in ITS OWN suffix if that chunk is exactly chunk4 — the
        universal privacy line (`_Luna`-only, and true of every app, so it's
        the one inherited chunk a facet still prints). Chunk5 exists only as
        `_Luna`/`_Core` family-marketing copy ("...whole family of Luna
        apps...") that would otherwise leak onto a facet's own setup page
        through the same fallback — wrong there, because the user is mid-task
        on ONE app, not shopping the family. Central Luna keeps chunk5 (and
        anything added after it) because that pitch is true for it.
        """
        collected: list[str] = []
        index = 1
        while (chunk := self.optional(f"{prefix}{index}")) is not None:
            if self.suffix != "Core":
                has_own = f"{prefix}{index}_{self.suffix}" in self.table
                if not has_own and index != 4:
                    break
            collected.append(chunk)
            index += 1
        return collected


# MARK: - Page


def step_visual(kind: str, icon_href: str, app_name: str) -> str:
    """The picture of Safari chrome a step points at, at chrome scale.

    `pageMenu` and `manageExtensions` are light plates carrying a glyph — a
    capsule for Safari's address field, a rounded rect for the menu row it
    opens. `switch` is the setting's already-on switch, `tap` the tapping
    hand beside the permission button, while the app icon is rendered inline
    in its step's text.
    """
    if kind == "pageMenu":
        # SF `text.justify.leading`: justified lines with a short leading last one.
        glyph = (
            '<svg class="glyph" viewBox="0 0 16 14" aria-hidden="true">'
            '<rect x="0" y="0.6" width="16" height="1.8" rx="0.9"/>'
            '<rect x="0" y="4.6" width="16" height="1.8" rx="0.9"/>'
            '<rect x="0" y="8.6" width="16" height="1.8" rx="0.9"/>'
            '<rect x="0" y="12.6" width="9.6" height="1.8" rx="0.9"/>'
            "</svg>"
        )
        return f'<span class="chip chip-capsule">{glyph}</span>'

    if kind == "manageExtensions":
        # SF `puzzlepiece.extension.fill`: the real piece has a female socket on
        # the left and a male tab sticking out on the right. Explicit curves
        # make the socket/tab orientation unambiguous at 19px.
        glyph = (
            '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">'
            '<path d="M7 4h10a2 2 0 0 1 2 2v3'
            'c2 0 3 1.3 3 3s-1 3-3 3v3a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-3'
            'c2 0 3-1.3 3-3s-1-3-3-3V6a2 2 0 0 1 2-2Z"/>'
            "</svg>"
        )
        return f'<span class="chip chip-rounded">{glyph}</span>'

    if kind == "switch":
        return '<span class="switch" aria-hidden="true"><span class="knob"></span></span>'

    if kind == "tap":
        # SF `hand.tap` stand-in: an outline tapping hand — index finger up,
        # two curled knuckles, a thumb tucked against the palm — with three
        # motion ticks radiating off the fingertip's upper left.
        return (
            '<svg class="tap-glyph" viewBox="0 0 26 26" fill="none" '
            'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" '
            'stroke-linejoin="round" aria-hidden="true">'
            '<path d="M7.2 2 8.1 3.7 M3.6 4.8 5.3 5.9 M2 9.2 3.9 9.5"/>'
            '<path d="M11 15.5 V5 a1.7 1.7 0 0 1 3.4 0 V11 a1.7 1.7 0 0 1 3.4 0 '
            "v0.8 a1.7 1.7 0 0 1 3.4 0 v2.7 c0 2.2 -0.6 3.5 -1.5 4.8 "
            "c-0.5 0.8 -0.8 1.7 -0.8 2.7 h-6.8 c0 -1 -0.3 -1.9 -0.9 -2.7 "
            "c-0.9 -1.2 -2.2 -2.3 -3 -4 c-0.4 -0.85 0.25 -1.8 1.2 -1.8 "
            'c0.55 0 1.1 0.25 1.45 0.7 l1.15 1.35 Z"/>'
            "</svg>"
        )

    return (
        f'<img class="step-icon" src="{icon_href}" alt="{html.escape(app_name)}">'
    )


def render_page(slug: str, copy: Copy, icon_href: str) -> str:
    app_name = copy.string("LunaApp_displayName")
    title = copy.string("Onboarding_Safari_title")
    byline = copy.string("Onboarding_Safari_bylineTemplate").replace("%@", app_name)
    prose = " ".join(copy.chunks("Onboarding_Safari_explainerChunk"))
    steps_heading = copy.string("Onboarding_Safari_stepsHeading")

    inline_app = (
        f'<span class="inline-app"><img class="inline-step-icon" src="{icon_href}" '
        f'alt="" aria-hidden="true">{html.escape(app_name)}</span>'
    )
    steps = [
        ("pageMenu", copy.string("Onboarding_Safari_pageMenuStep")),
        (
            "manageExtensions",
            copy.string("Onboarding_Safari_manageExtensionsStepTemplate").replace(
                "%@", copy.string("Onboarding_Safari_manageExtensionsTitle")
            ),
        ),
        (
            "switch",
            copy.string("Onboarding_Safari_appStepTemplate").replace("%@", inline_app),
        ),
        ("tap", '<span class="system-button">Allow on all websites</span>'),
    ]

    def render_row(kind: str, text: str) -> str:
        rendered_text = text if kind in ("switch", "tap") else html.escape(text)
        return (
            '        <li class="step">\n'
            f'          <span class="visual">{step_visual(kind, icon_href, app_name)}</span>\n'
            f'          <span class="step-text">{rendered_text}</span>\n'
            '        </li>'
        )

    rows = "\n".join(
        render_row(kind, text)
        for kind, text in steps
    )

    page_title = f"{title} — {app_name}"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(page_title)}</title>
<meta name="description" content="{html.escape(prose)}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="{THEME_COLOR}">
<meta property="og:title" content="{html.escape(page_title)}">
<meta property="og:description" content="{html.escape(prose)}">
<meta property="og:image" content="{icon_href}">
<link rel="icon" href="{icon_href}">
<link rel="apple-touch-icon" href="{icon_href}">
<link rel="stylesheet" href="/assets/setup.css">
</head>
<body>
<main class="page">
  <header class="masthead">
    <img class="app-icon" src="{icon_href}" alt="{html.escape(app_name)}">
    <h1>{html.escape(title)}</h1>
  </header>
  <p class="byline">{html.escape(byline)}</p>
  <p class="prose">{html.escape(prose)}</p>

  <section class="steps" aria-labelledby="steps-heading">
    <h2 class="steps-heading" id="steps-heading">{html.escape(steps_heading)}</h2>
    <ol class="step-list">
{rows}
    </ol>
  </section>
  <p class="privacy-explainer">Your browsing history and data is kept entirely on device. Luna works on your phone to improve your browsing experience and let you retrieve your own history locally.</p>
</main>
</body>
</html>
"""


def render_index(entries: list[tuple[str, str, str]]) -> str:
    """The bare directory of setup pages: name, icon, link."""
    items = "\n".join(
        '      <li><a class="app-link" href="/setup/{slug}/">'
        '<img src="{icon}" alt=""><span>{name}</span></a></li>'.format(
            slug=slug, icon=icon, name=html.escape(name)
        )
        for slug, name, icon in entries
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Luna — Safari extension setup</title>
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="{THEME_COLOR}">
<link rel="icon" href="/assets/icon-luna.png">
<link rel="stylesheet" href="/assets/setup.css">
</head>
<body>
<main class="page index">
  <p class="eyebrow">Safari extension setup</p>
  <h1>Turn on the Luna extension in Safari</h1>
  <p class="prose">Pick the app you installed.</p>
  <ul class="app-list">
{items}
  </ul>
</main>
</body>
</html>
"""


# Every number here is the app's own: the pt constants in
# `OnboardingSafariPageView` and `OnboardingSafariExplainerViews`, and the
# colours in `OnboardingSafariPagePalette` / `OnboardingMockSwitchView.onColor`.
CSS = """:root {
  /* OnboardingSafariPagePalette */
  --page: #4f5257;          /* background  (0.31, 0.32, 0.34) */
  --paper: #fafafa;         /* paper       (white 0.98)       */
  --ink: #1a1a1a;           /* ink         (white 0.10)       */
  --quiet: rgba(255, 255, 255, 0.62);  /* quietCopy           */
  --switch-on: #33c759;     /* OnboardingMockSwitchView.onColor */
  --column: 680px;          /* LunaLayout.readableWidth */
}

* { box-sizing: border-box; }

html { -webkit-text-size-adjust: 100%; }

body {
  margin: 0;
  background: var(--page);
  color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI",
    system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}

.page {
  max-width: var(--column);
  margin: 0 auto;
  /* OnboardingSafariPageView.minimumTopInset, and the phone's 24pt column. */
  padding: 40px 24px 64px;
  padding-left: max(24px, env(safe-area-inset-left));
  padding-right: max(24px, env(safe-area-inset-right));
}

/* The header row: 60pt icon, 14pt gap, the headline beside it. Top-aligned
   rather than centred, because the central app's own title ("Read, watch,
   and track — not the popups") is long enough to wrap on a 390px phone —
   centring a wrapped multi-line h1 against a single fixed-height icon reads
   as misaligned, top-aligned never does. */
.masthead {
  display: flex;
  align-items: flex-start;
  gap: 14px;
}

.app-icon {
  width: 60px;
  height: 60px;
  flex: 0 0 auto;
  margin-top: 2px;      /* optical alignment with the h1's first cap-line */
  border-radius: 17px;   /* the app's own corner on a 60pt icon */
  display: block;
}

h1 {
  margin: 0;
  min-width: 0;          /* let the flex item shrink instead of overflowing */
  font-size: clamp(21px, 6.2vw, 26px);  /* scales down before it wraps badly */
  font-weight: 700;
  line-height: 1.2;
  letter-spacing: -0.01em;
  overflow-wrap: break-word;
}

.byline {
  margin: 10px 0 0;
  font-size: 13px;
  font-weight: 600;
  color: var(--quiet);
}

.prose {
  margin: 10px 0 0;
  font-size: 17px;
  line-height: 1.42;      /* 17pt copy, 5pt lineSpacing */
  max-width: 34em;
}

/* These four steps are the whole point of the page — the physical actions
   the reader is mid-way through doing right now — so they get their own
   panel, a number per step, and copy sized above the surrounding prose. */
.steps { margin-top: 36px; }

.steps-heading {
  margin: 0 0 10px;
  font-size: 13px;
  font-weight: 600;
  color: var(--quiet);
}

.step-list {
  counter-reset: step;
  margin: 0;
  padding: 4px 18px;
  border-radius: 18px;
  background: rgba(255, 255, 255, 0.06);
  list-style: none;
}

/* A numeral column (::before, a counter), a 70pt visual column, a 14pt gap,
   then the copy — so all three lines of text start on one vertical. A
   border between rows stands in for margin so touching rows still read as
   distinct steps without extra vertical space. */
.step {
  counter-increment: step;
  display: flex;
  align-items: center;
  gap: 14px;
  min-height: 44px;
  padding: 16px 0;
}

.step + .step {
  border-top: 1px solid rgba(255, 255, 255, 0.09);
}

.step::before {
  content: counter(step);
  flex: 0 0 20px;
  font-size: 15px;
  font-weight: 700;
  color: var(--quiet);
  text-align: center;
}

.visual {
  flex: 0 0 70px;
  display: flex;
  align-items: center;
  min-height: 30px;
}

.step-text {
  font-size: 17px;       /* up from 15px — level with .prose, not under it */
  font-weight: 500;
  line-height: 1.3;
}

/* A picture of Safari's chrome: a light plate carrying a dark glyph. */
.chip {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 46px;
  height: 30px;
  background: var(--paper);
  color: var(--ink);
}

.chip-capsule { border-radius: 15px; }  /* Safari's address field is a capsule */
.chip-rounded { border-radius: 9px; }   /* the menu row it opens is not */

.chip .glyph {
  width: 16px;
  height: 16px;
  fill: currentColor;
}

.chip-rounded .glyph { width: 19px; height: 19px; }

.step-icon {
  width: 28px;
  height: 28px;
  border-radius: 7px;
  display: block;
}

/* Plain inline, NOT inline-flex: a flex span takes its baseline from the
   icon's bottom edge, which floats the icon and name a few px above the
   "Switch on" text beside them. Inline, the name shares the surrounding
   baseline exactly and the icon is nudged down to sit centred on it. */
.inline-app {
  white-space: nowrap;
}

.inline-step-icon {
  width: 24px;
  height: 24px;
  border-radius: 6px;
  display: inline-block;
  vertical-align: -6px;   /* centres the 24px icon on 17px text */
  margin-right: 6px;
}

/* Already on: the step is what the setting looks like once you've done it. */
.switch {
  position: relative;
  width: 34px;
  height: 20px;
  border-radius: 10px;
  background: var(--switch-on);
  flex: 0 0 auto;
}

.knob {
  position: absolute;
  top: 2px;
  right: 2px;
  width: 16px;
  height: 16px;
  border-radius: 8px;
  background: #fff;
}

/* The tapping hand is an outline drawn straight on the page background —
   no plate, since it's a gesture rather than a piece of Safari chrome. */
.tap-glyph {
  width: 30px;
  height: 30px;
}

.system-button {
  display: inline-block;
  padding: 0.18em 0.55em 0.2em;
  border-radius: 0.62em;
  background: #0a84ff;
  color: #fff;
  font-size: 0.92em;
  font-weight: 650;
  line-height: 1.1;
  white-space: nowrap;
  vertical-align: 0.02em;
}

.privacy-explainer {
  margin: 20px 0 0;
  max-width: 36em;
  color: var(--quiet);
  font-size: 14px;
  line-height: 1.45;
}

/* The small label above the index page's own h1 — same visual language as
   .steps-heading / .byline, so the index reads as one more page of this
   site rather than a bare directory listing. */
.eyebrow {
  margin: 0 0 8px;
  font-size: 13px;
  font-weight: 600;
  color: var(--quiet);
}

/* The index of setup pages: same panel-with-dividers treatment as
   .step-list, so picking an app feels like the same kind of decision as
   working through its steps. */
.app-list {
  margin: 24px 0 0;
  padding: 4px 16px;
  border-radius: 18px;
  background: rgba(255, 255, 255, 0.06);
  list-style: none;
}

.app-list li + li {
  border-top: 1px solid rgba(255, 255, 255, 0.09);
}

.app-link {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px 0;
  color: #fff;
  font-size: 17px;
  font-weight: 500;
  text-decoration: none;
}

.app-link img {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  flex: 0 0 auto;
}

.app-link:hover span { text-decoration: underline; }
"""

HEADERS = """/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin

/assets/*
  Cache-Control: public, max-age=3600
"""


# MARK: - Build


def write_icon(source: Path, destination: Path) -> None:
    """The 1024px master, downscaled. `sips` is macOS-only; a copy is the fallback."""
    if shutil.which("sips"):
        destination.write_bytes(source.read_bytes())
        subprocess.run(
            ["sips", "-Z", str(ICON_PX), str(destination)],
            check=True,
            capture_output=True,
        )
    else:
        shutil.copyfile(source, destination)


def build(out: Path) -> None:
    table = load_strings()
    if out.exists():
        shutil.rmtree(out)
    (out / "assets").mkdir(parents=True)

    entries: list[tuple[str, str, str]] = []
    for slug, suffix, icon_source in APPS:
        icon_href = f"/assets/icon-{slug}.png"
        write_icon(ICONS / icon_source, out / f"assets/icon-{slug}.png")

        copy = Copy(table, suffix)
        page_dir = out / "setup" / slug
        page_dir.mkdir(parents=True)
        (page_dir / "index.html").write_text(
            render_page(slug, copy, icon_href), encoding="utf-8"
        )
        entries.append((slug, copy.string("LunaApp_displayName"), icon_href))

    (out / "assets/setup.css").write_text(CSS, encoding="utf-8")
    (out / "index.html").write_text(render_index(entries), encoding="utf-8")
    (out / "setup/index.html").write_text(render_index(entries), encoding="utf-8")
    (out / "_headers").write_text(HEADERS, encoding="utf-8")

    redirects = "".join(
        f"/setup/{alias} /setup/{slug}/ 301\n" for alias, slug in sorted(ALIASES.items())
    )
    (out / "_redirects").write_text(redirects, encoding="utf-8")

    print(f"built {len(APPS)} setup pages → {out.relative_to(REPO)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=REPO / "site/dist",
        type=Path,
        help="output directory (default: site/dist)",
    )
    build(Path(parser.parse_args().out).resolve())


if __name__ == "__main__":
    main()
