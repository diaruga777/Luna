# LuneSafari — Safari Web Extension

Tracks the URL of the active Safari tab and persists it so the SaveLink intent can save "the page I'm looking at" without any UI.

## Flow

```
background.js (tabs.onActivated / tabs.onUpdated)
  → browser.runtime.sendNativeMessage("application.id", {url})
  → SafariWebExtensionHandler (extension process, NSExtensionRequestHandling)
  → App Group UserDefaults (group.com.hpiddy.lune): lastSafariURL, lastSafariURLDate
  → read by SafariURLStore (app) / SaveLinkIntent
```

## Key files

- `LuneSafari/Resources/manifest.json` — MV3; `background.page` (event page — iOS kills MV3 service workers) **with `"persistent": false`** and a numeric-keyed `icons` map — both are REQUIRED by App Store Connect upload validation (ITMS error 90849 otherwise); permissions `nativeMessaging`, `tabs`; `host_permissions: <all_urls>` (needed to read tab URLs; user grants "All Websites").
- `LuneSafari/Resources/background.js` — listens `tabs.onActivated` + `tabs.onUpdated` (active tab, url change or load complete), dedupes, sends native message.
- `LuneSafari/SafariWebExtensionHandler.swift` — principal class (`NSExtensionPointIdentifier = com.apple.Safari.web-extension` in `LuneSafari/Info.plist`); writes via `SharedSafariURL`.
- `LuneSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — no shared framework in this small project).

Target: `LuneSafari`, bundle `com.hpiddy.lune.safari`, app-extension product embedded in Lune.app/PlugIns. Resources flatten into the appex root (Safari requires manifest.json at bundle root on iOS).

## "Read in Lune" button (deep-link into the app)

A second role of the same extension (presented as an **iOS 27+** feature): a "Read in Lune"
button on article pages that opens the page in

`LuneSafari/Resources/content.js` is injected **programmatically** by `background.js`
(`scripting.executeScript` on every `tabs.onUpdated`/`status:complete` http(s) page),
self-guarded with `window.__queueContentScriptRan`. (A declarative `content_scripts` block
also validates fine — programmatic is just a smaller manifest footprint.) **ITMS-90849
gotcha**: the manifest `description` must stay **≤ ~112 chars** — a 127-char description
failed App Store validation with the opaque code 90849 (NOT content_scripts/scripting, which
were red herrings).

Flow:
1. content.js asks background `{type:"buttonMode"}`; background relays to the native handler,
   which returns the app's `SafariSuggestionMode` (`never` / `all` / `onlyLocked`, default
   `all`) from the App Group (`SafariSuggestionSettings`, key `safariSuggestionMode`).
2. If `never`, or the page isn't an article (`looksLikeArticle`: og:type=article / `<article>`
   / a substantial `<p>` body + `<h1>`), or (`onlyLocked`) the page isn't paywalled
   (`looksPaywalled` — a JS mirror of `PaywallDetector`: gate markers + `isAccessibleForFree`
   + `content_tier`), it does nothing.
3. Otherwise it injects a Lune-indigo (`#5856D6`) "Read in Lune" capsule button. Tapping it
   navigates to `lunereader://read?url=<encoded>` — the app's `LuneDeepLink`.

App side: `SceneDelegate.openReader` ingests the URL (`handleSavePress`) then opens it via
`ReadingListViewController.open(_:presenter:)` — so a paywalled article opens straight into
the in-app archive reader, a ready article into the native reader. The "Locked Only" mode and
the in-app paywall handling share one detector (`PaywallDetector`), so a reader logged in via
their browser sees a full article and isn't flagged.

The setting lives in Settings → Shortcut & Safari ("Read in Lune Button" — a 3-segment
control). `background.js` relays `buttonMode` (the only message besides URL tracking);
content scripts can't call `sendNativeMessage` directly.

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Lune → enable + allow all websites. Verify via Lune app Settings screen ("Safari extension status" shows last tracked URL).
