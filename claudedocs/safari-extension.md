# ClipSafari — Safari Web Extension

Tracks the URL of the active Safari tab and persists it so the SaveLink intent can save "the page I'm looking at" without any UI.

## Flow

```
background.js (tabs.onActivated / tabs.onUpdated)
  → browser.runtime.sendNativeMessage("application.id", {url})
  → SafariWebExtensionHandler (extension process, NSExtensionRequestHandling)
  → App Group UserDefaults (group.com.hpiddy.clip): lastSafariURL, lastSafariURLDate
  → read by SafariURLStore (app) / SaveLinkIntent
```

## Key files

- `ClipSafari/Resources/manifest.json` — MV3; `background.page` (event page — iOS kills MV3 service workers) **with `"persistent": false`** and a numeric-keyed `icons` map — both are REQUIRED by App Store Connect upload validation (ITMS error 90849 otherwise); permissions `nativeMessaging`, `tabs`; `host_permissions: <all_urls>` (needed to read tab URLs; user grants "All Websites").
- `ClipSafari/Resources/background.js` — listens `tabs.onActivated` + `tabs.onUpdated` (active tab, url change or load complete), dedupes, sends native message.
- `ClipSafari/SafariWebExtensionHandler.swift` — principal class (`NSExtensionPointIdentifier = com.apple.Safari.web-extension` in `ClipSafari/Info.plist`); writes via `SharedSafariURL`.
- `ClipSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — no shared framework in this small project).

Target: `ClipSafari`, bundle `com.hpiddy.clip.safari`, app-extension product embedded in Clip.app/PlugIns. Resources flatten into the appex root (Safari requires manifest.json at bundle root on iOS).

## "Read in Queue" archive harvest (paywalled articles)

A second role of the same extension (presented as an **iOS 27+** feature, matching the
existing Safari-onboarding gating): get hard-paywalled articles (WSJ/FT/…) into Queue via
their archive.today snapshot, harvested from **real Safari** (which clears archive.today's
Cloudflare gate reliably — see `readers.md`).

`ClipSafari/Resources/content.js` (matched on hard-paywall hosts + `archive.*` hosts):
- **On a paywall host**: injects a Queue-indigo (`#5856D6`) "Read in Queue" capsule button.
  Tap → `runtime.sendMessage({type:"queueRedirect", url})` → background redirects the tab to
  `https://archive.is/newest/<url>`.
- **On an archive host**: asks background `{type:"isQueueRedirect"}`. **Only if this tab was
  redirected by our button** (never an arbitrary archive.is visit) does it proceed: polls
  until the real article is loaded (past the CAPTCHA — `isChallengePage()` guards, innerText
  ≥ 1500), then strips the page to compact HTML (`reducedHTML()` drops
  `script/style/svg/iframe/link/form` + every inline `style`/`class` attr — the bulk of
  archive.today's ~1 MB), relays `{type:"archiveContent", url, title, html|text}`, and shows
  a "Saved to Queue" banner with an "Open Queue" button (`clickreader://saved`). Falls back
  to `innerText` if stripped HTML still exceeds ~950 KB (native-message limit).

`background.js`: keeps a `queueRedirects` map (tabId → original URL) so only our redirects
harvest; relays content→native via `sendNativeMessage`. `SafariWebExtensionHandler` routes a
`type:"archiveContent"` message to **`PendingSafariArchive.write`** (ClipSafari), which writes
one JSON hand-off file per capture into the App Group `PendingSafariArchives/`.

App side: **`Clip/ReadingList/PendingSafariArchiveImporter`** (called from
`AppDelegate`/`SceneDelegate` on launch+foreground) reads each hand-off, extracts via the
shared `ArticleExtractor` (HTML; or a plain-text fallback → paragraph blocks), saves a ready
reading-list item, and deletes the file. `clickreader://saved` (handled in `SceneDelegate.route`)
just brings the app forward — the foreground import surfaces the new item. Tests:
`ClipTests/PendingSafariArchiveImporterTests`.

Content scripts can't call `sendNativeMessage` directly — everything routes through
`background.js` (`runtime.sendMessage` → `sendNativeMessage`).

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Clip → enable + allow all websites. Verify via Clip app Settings screen ("Safari extension status" shows last tracked URL).
