#!/usr/bin/env python3
"""Builds the static luna.app site (Cloudflare Pages) from the app's own sources.

The only page it renders today is `/setup/<app>`, a static reproduction of the
mock `luna.app` page the in-app Safari lesson shows — the same headline, byline,
prose and three enable steps, drawn with the same chrome pictures and the app's
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
    opens. `app` is the app's own icon beside the switch, already on: the step
    shows what the setting looks like once it is done.
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
        # SF `puzzlepiece.extension.fill`: knob on top, socket on the right. Both
        # are MAJOR arcs (large-arc-flag 1) — a minor arc over the same chord is
        # a shallow bump, and the piece stops reading as a puzzle piece at 19px.
        # The translate re-centres the body under the knob's extra height.
        glyph = (
            '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">'
            '<path transform="translate(0 1.6)" d="M7 5h2.4a2.9 2.9 0 1 1 5.2 0H17'
            "a2 2 0 0 1 2 2v2.4a2.9 2.9 0 1 0 0 5.2V17a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2"
            'V7a2 2 0 0 1 2-2Z"/>'
            "</svg>"
        )
        return f'<span class="chip chip-rounded">{glyph}</span>'

    return (
        '<span class="app-visual">'
        f'<img class="step-icon" src="{icon_href}" alt="{html.escape(app_name)}">'
        '<span class="switch"><span class="knob"></span></span>'
        "</span>"
    )


def render_page(slug: str, copy: Copy, icon_href: str) -> str:
    app_name = copy.string("LunaApp_displayName")
    title = copy.string("Onboarding_Safari_title")
    byline = copy.string("Onboarding_Safari_bylineTemplate").replace("%@", app_name)
    prose = " ".join(copy.chunks("Onboarding_Safari_explainerChunk"))
    steps_heading = copy.string("Onboarding_Safari_stepsHeading")

    steps = [
        ("pageMenu", copy.string("Onboarding_Safari_pageMenuStep")),
        (
            "manageExtensions",
            copy.string("Onboarding_Safari_manageExtensionsStepTemplate").replace(
                "%@", copy.string("Onboarding_Safari_manageExtensionsTitle")
            ),
        ),
        (
            "app",
            copy.string("Onboarding_Safari_appStepTemplate").replace("%@", app_name),
        ),
    ]

    rows = "\n".join(
        "        <li class=\"step\">\n"
        f"          <span class=\"visual\">{step_visual(kind, icon_href, app_name)}</span>\n"
        f"          <span class=\"step-text\">{html.escape(text)}</span>\n"
        "        </li>"
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
<link rel="icon" href="/assets/icon-luna.png">
<link rel="stylesheet" href="/assets/setup.css">
</head>
<body>
<main class="page index">
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

/* The header row: 60pt icon, 14pt gap, the two-line headline beside it. */
.masthead {
  display: flex;
  align-items: center;
  gap: 14px;
}

.app-icon {
  width: 60px;
  height: 60px;
  flex: 0 0 auto;
  border-radius: 17px;   /* the app's own corner on a 60pt icon */
  display: block;
}

h1 {
  margin: 0;
  font-size: 26px;
  font-weight: 700;
  line-height: 1.2;
  letter-spacing: -0.01em;
}

.byline {
  margin: 8px 0 0;
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

.steps { margin-top: 32px; }

.steps-heading {
  margin: 0;
  font-size: 13px;
  font-weight: 600;
  color: var(--quiet);
}

.step-list {
  margin: 8px 0 0;
  padding: 0;
  list-style: none;
}

/* OnboardingSafariEnableStepRowView: a 70pt visual column, a 14pt gap, then
   the copy — so all three lines of text start on one vertical. */
.step {
  display: flex;
  align-items: center;
  gap: 14px;
  min-height: 38px;
  margin-top: 8px;
}

.step:first-child { margin-top: 0; }

.visual {
  flex: 0 0 70px;
  display: flex;
  align-items: center;
  min-height: 30px;
}

.step-text {
  font-size: 15px;
  line-height: 1.25;
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

.app-visual {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}

.step-icon {
  width: 28px;
  height: 28px;
  border-radius: 7px;
  display: block;
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

/* The index of setup pages. */
.app-list {
  margin: 24px 0 0;
  padding: 0;
  list-style: none;
}

.app-link {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 10px 0;
  color: #fff;
  font-size: 17px;
  font-weight: 500;
  text-decoration: none;
}

.app-link img {
  width: 44px;
  height: 44px;
  border-radius: 12px;
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
