# Intents & Action Button Shortcut

Press the Action Button while reading in Safari → the current page is saved to the reading list, no UI, no app switch.

## Key files

- `Clip/Intents/ClipSafariPageIntent.swift` — "Clip Current Safari Page": `openAppWhenRun = false`. ALWAYS targets `SafariURLStore.lastURL` (from the extension); the `url: URL?` parameter NEVER overrides it. When `url` is present it's a **fuzzy prefix check** (`URLPrefixMatch`: scheme/www./trailing-slash/case ignored, either-direction prefix) → `trackedURLMismatch` on failure; when absent, no check. `app: String?` guards you're in Safari (nil treated as Safari). Returns the saved URL (`ReturnsValue<String?>`; nil on the 12 s timeout). The save goes through `ReadingListIngestor.handleSavePress` — repeat presses are ignored except the Kindle double-save (see send-to-kindle.md); new-save automation (auto-share, suggestions, watch-later) NEVER runs for repeat presses.
- `Clip/Intents/SaveLinkIntent.swift` — "Save Link": required `url: URL`, same `handleSavePress` path with the URL exactly as given. Returns the saved URL.
- `Clip/Intents/FindYouTubeVideoIntent.swift` — see youtube.md.
- `Clip/Intents/ShareSuggestionIntents.swift` — `GetShareSuggestionIntent` returns the username suggested by the last save (nil when none); `SetShareChoiceIntent(choice:)` accepts "Don't Share" / "Share Once" / "Always Share" and acts on the app-side pending suggestion (see social-sharing.md).
- `Clip/Intents/ClipShortcuts.swift` — `AppShortcutsProvider` exposing both intents.

## Bundled shortcut

`Clip/Resources/Clip Safari Page.shortcut` — generated WFWorkflow plist signed with `shortcuts sign --mode anyone`. Flow: Get Current App → ClipSafariPageIntent (app bound via WFTextTokenString attachment) → GetShareSuggestionIntent → If (WFCondition 100 "has any value" on its output) → Choose from Menu ("Share with <name>?": Don't Share / Share Once / Always Share) → SetShareChoiceIntent with the literal choice string. Generator: the python script writes the plist (action identifiers `<bundleID>.<IntentName>`, `AppIntentDescriptor` with TeamIdentifier MM5QBNLXR6, control flow via GroupingIdentifier + WFControlFlowMode 0/1/2). Settings → "Install Shortcut" shares it to the Shortcuts app; users must RE-IMPORT after the flow changes. NOTE: `shortcuts://import-workflow?url=` REJECTS local file URLs, so install stays share-sheet based.

## User setup (documented in-app: Settings → Action Button Setup)

1. Enable the Safari extension (see safari-extension.md).
2. Settings → Install Shortcut → share to Shortcuts → Add Shortcut. (First run prompts to allow sharing app info with Clip — Always Allow.)
3. Settings → Action Button → Shortcut → pick "Clip Safari Page".

Action Button can't be assigned programmatically; the simulator has no Action Button (test by running the shortcut from the Shortcuts app).
