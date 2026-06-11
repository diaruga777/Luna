# Intents & Action Button Shortcut

Press the Action Button while reading in Safari → the current page is saved to the reading list, no UI, no app switch.

## Key files

- `Clip/Intents/ClipSafariPageIntent.swift` — "Clip Current Safari Page": `openAppWhenRun = false`. ALWAYS saves `SafariURLStore.lastURL` (from the extension). `app: String?` guards you're in Safari (nil treated as Safari); `url: URL?` is only a VERIFICATION — when present its host must match the tracked URL or the intent throws `trackedURLMismatch`. Success silent; failures throw (Shortcuts error alerts). Inline ingest capped at 12 s (`IntentIngestHelper`).
- `Clip/Intents/SaveLinkIntent.swift` — "Save Link": required `url: URL`, saves exactly as given. Silent success.
- `Clip/Intents/ClipShortcuts.swift` — `AppShortcutsProvider` exposing both intents.

## Bundled shortcut

`Clip/Resources/Clip Safari Page.shortcut` — generated WFWorkflow plist (Get Current App → ClipSafariPageIntent with app bound via WFTextTokenString) signed with `shortcuts sign --mode anyone`. Settings → "Install Shortcut" shares it to the Shortcuts app. NOTE: `shortcuts://import-workflow?url=` REJECTS local file URLs (verified: "Import Failed — invalid URL"), so a one-tap no-sheet install requires hosting the shortcut as an iCloud link (create on-device: Share → Copy iCloud Link) and opening that URL instead.

## User setup (documented in-app: Settings → Action Button Setup)

1. Enable the Safari extension (see safari-extension.md).
2. Settings → Install Shortcut → share to Shortcuts → Add Shortcut. (First run prompts to allow sharing app info with Clip — Always Allow.)
3. Settings → Action Button → Shortcut → pick "Clip Safari Page".

Action Button can't be assigned programmatically; the simulator has no Action Button (test by running the shortcut from the Shortcuts app).
