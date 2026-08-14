# site — the Luna web pages (Cloudflare Pages)

A free, static site. Today it carries one thing: `/setup/<app>`, the
Safari-extension setup instructions. Each app's own in-app "Set up in Safari"
button opens `https://luna-site-bm6.pages.dev/setup/<slug>` directly rather
than showing the mock-`luna.app` onboarding lesson in-app — the in-app version
was dropped, so these pages are now the ONLY instructions a user sees, read on
their phone in Safari at the exact moment they're enabling the extension.

```
/                       the four setup pages, listed
/setup/                 same list
/setup/luna             central Luna
/setup/reader           Luna Reader
/setup/video            Luna Video
/setup/price-tracker    Luna Price Tracker
```

`luna-reader`, `lunareader`, `downloader`, `luna-downloader`, `lunadownloader`,
`luna-video`, `lunavideo`,
`luna-price-tracker`, `pricetracker` and `price` 301 to the canonical slug
(`site/dist/_redirects`).

## Building

```sh
python3 scripts/build_site.py          # → site/dist
```

`site/dist` is generated AND committed, so a deploy needs no build step on
Cloudflare's side. **Re-run the generator after touching Safari onboarding copy
or an app icon**, and commit what changes.

The prose and app names are read from the app's strings. The generator also
adds the site-only Safari permission labels and the local-only privacy note.
The generator reads:

| what | from |
| --- | --- |
| every string | `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`, resolved with the same `<base>_<suffix>` → `<base>_Luna` fallback `L10n` uses |
| the app icons | the committed 1024px `AppIcon*` masters in `SharedIconAssets.xcassets`, downscaled to 256px |
| the layout and palette | the pt constants in `OnboardingSafariPageView` / `OnboardingSafariExplainerViews`, and `OnboardingSafariPagePalette` |

So a copy change in the strings file reaches the site by re-running the script;
there is no second copy of the wording to keep in sync. A missing key is a hard
error rather than a raw key on the page.

Two deliberate differences from the app:

- **No “Activate Safari” / “Skip”.** Those are in-app navigation, not
  instructions.
- **Hand-drawn SVG chrome glyphs.** The page-menu chip and the puzzle-piece row
  are stand-ins for `text.justify.leading` and `puzzlepiece.extension.fill` —
  SF Symbols may not be redistributed on the web. The app icon and the switch
  are the real artwork.

One more: the app fits the longest PREFIX of the prose chunks its screen can
hold; a web page has room to print every chunk the strings file gives an
app's own suffix. The one exception is deliberate, not a screen-space limit:
the central Luna app's page prints through chunk5 (a "whole family of Luna
apps" pitch that's true for it), but a facet page (Reader/Downloader/
PriceTracker) stops at chunk4 even though the `_Luna` fallback would
otherwise hand it that same family-marketing line — wrong there, since the
reader is mid-setup on ONE app, not shopping the family. See `Copy.chunks` in
`scripts/build_site.py`.

## Previewing locally

```sh
python3 -m http.server 8899 --directory site/dist
open http://127.0.0.1:8899/setup/reader/
```

Use the directory server rather than opening the file directly — the pages link
`/assets/setup.css` at the root.

## Deploying

One-time account setup is in the repo-level instructions; after that:

```sh
npx wrangler pages deploy          # reads wrangler.toml at the repo root
```

`wrangler.toml` names the project (`luna-site`) and points at `site/dist`.
