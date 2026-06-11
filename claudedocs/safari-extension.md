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

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Clip → enable + allow all websites. Verify via Clip app Settings screen ("Safari extension status" shows last tracked URL).
