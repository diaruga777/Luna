# LunaSafari — Safari Web Extension

Tracks the URL of the active Safari tab and persists it so the SaveLink intent can save "the page I'm looking at" without any UI.

## Flow

```
background.js (tabs.onActivated / tabs.onUpdated)
  → browser.runtime.sendNativeMessage("application.id", {url})
  → SafariWebExtensionHandler (extension process, NSExtensionRequestHandling)
  → App Group UserDefaults (group.com.hsanabria.luna): lastSafariURL, lastSafariURLDate
  → read by SafariURLStore (app) / SaveLinkIntent
```

## Key files

- `LunaSafari/Resources/manifest.json` — MV3; `background.page` (event page — iOS kills MV3 service workers) **with `"persistent": false`** and a numeric-keyed `icons` map — both are REQUIRED by App Store Connect upload validation (ITMS error 90849 otherwise); permissions `nativeMessaging`, `tabs`; `host_permissions: <all_urls>` (needed to read tab URLs; user grants "All Websites").
- `LunaSafari/Resources/background.js` — listens `tabs.onActivated` + `tabs.onUpdated` (active tab, url change or load complete), dedupes, sends native message.
- `LunaSafari/SafariWebExtensionHandler.swift` — principal class (`NSExtensionPointIdentifier = com.apple.Safari.web-extension` in `LunaSafari/Info.plist`); writes via `SharedSafariURL`.
- `LunaSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — no shared framework in this small project).

Target: `LunaSafari`, bundle `com.hsanabria.luna.safari`, app-extension product embedded in Luna.app/PlugIns. Resources flatten into the appex root (Safari requires manifest.json at bundle root on iOS).

## "Read in Luna" / "Download in Luna" button

The same extension also presents a page button: "Read in Luna" on article pages, or
"Download in Luna" on recognized Downloader-platform pages. This is independent from
the iOS 27+ Action Button shortcut setup; keep it available on earlier iOS versions
as long as the Safari web extension and deep-link/App Clip path work there.

`LunaSafari/Resources/content.js` is injected **programmatically** by `background.js`
(`scripting.executeScript` on every `tabs.onUpdated`/`status:complete` http(s) page),
self-guarded with `window.__queueContentScriptRan`. (A declarative `content_scripts` block
also validates fine — programmatic is just a smaller manifest footprint.) **ITMS-90849
gotcha**: the manifest `description` must stay **≤ ~112 chars** — a 127-char description
failed App Store validation with the opaque code 90849 (NOT content_scripts/scripting, which
were red herrings).

Article flow:
1. content.js asks background `{type:"buttonContext"}`; background relays to the native handler,
   which returns the app's `SafariSuggestionMode` (`never` / `all` / `onlyLocked`, default
   `all`) from the App Group (`SafariSuggestionSettings`, key `safariSuggestionMode`).
2. If `never`, or the page isn't an article (`looksLikeArticle`: og:type=article / `<article>`
   / a substantial `<p>` body + `<h1>`), or (`onlyLocked`) the page isn't paywalled
   (`looksPaywalled` — a JS mirror of `PaywallDetector`: gate markers + `isAccessibleForFree`
   + `content_tier`), it does nothing.
3. Otherwise it injects a Luna-indigo (`#5856D6`) "Read in Luna" capsule button. Tapping it
   prefers `LunaReaderAppClipURL?url=<source>` from `LunaSafari/Info.plist`; that URL is
   filled in after App Store Connect has the Reader App Clip experience and should open the
   full Reader app when installed or the Reader App Clip otherwise. Until that value exists,
   it falls back to `lunareader://read?url=<encoded>` — the app's `LunaDeepLink`.

App side: `SceneDelegate.openReader` ingests the URL (`handleSavePress`) then opens it via
`ReadingListViewController.open(_:presenter:)` — so a paywalled article opens straight into
the in-app archive reader, a ready article into the native reader. The "Locked Only" mode and
the in-app paywall handling share one detector (`PaywallDetector`), so a reader logged in via
their browser sees a full article and isn't flagged.

Downloader-platform flow:
1. content.js asks background `{type:"buttonContext"}`; background relays to the native
   handler, which returns the same suggestion mode plus:
   - `isDownloaderHost` — true only for the `*.downloader.safari` extension bundle.
   - `readerAppClipURL` — `LunaReaderAppClipURL` from `LunaSafari/Info.plist`.
   - `downloaderAppClipURL` — `LunaDownloaderAppClipURL` from `LunaSafari/Info.plist`.
2. Before article heuristics run, content.js recognizes Downloader-platform hosts mirrored
   from `PlatformRecognizer` (YouTube, X/Twitter, Bluesky, Reddit, TikTok, Instagram,
   Facebook, Spotify, Apple Music, Apple Podcasts). These pages are never classified as
   articles by text length, even when a caption/comment body is long.
3. On a recognized platform URL, the button says "Download in Luna". If this is the
   Downloader app's own Safari extension, it opens the installed app through the existing
   `lunareader://read?url=...` route. If this is Reader/PriceTracker's Safari extension, it
   routes to `LunaDownloaderAppClipURL?url=<source>`. If `LunaDownloaderAppClipURL` is empty
   (the default until the production App Clip invocation URL exists), Reader/PriceTracker
   extensions do not show the button for platform pages.

The setting lives in Settings → Shortcut & Safari ("Read in Luna Button" — a 3-segment
control). On pre-iOS 27 builds this screen shows only the Safari-button setting; the
Action Button shortcut setup section is hidden. `background.js` relays
`buttonContext`/`buttonMode`; content scripts can't call `sendNativeMessage` directly.

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Luna → enable + allow all websites. Verify via Luna app Settings screen ("Safari extension status" shows last tracked URL).
