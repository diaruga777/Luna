# Intents & Action Button Shortcut

Press the Action Button while reading in Safari → the current page is saved to the reading list, no UI, no app switch.

## Share-suggestion token (return value)

The two save intents that can trigger a share suggestion — `LuneSafariPageIntent` and `FindYouTubeVideoIntent` — RETURN a token string describing the pending suggestion (from `ShareSuggestionStore.pendingSuggestionToken()`), so the shortcut can branch without a separate "get suggestion" action:

- `""` — no suggestion; the shortcut does nothing further.
- `"3:<username>"` — a streak/channel **match**: offer 3 options (Yes / Always / No). `SetShareChoiceIntent` maps Yes→Share Once, Always→Always Share, No→Don't Share.
- `"2:<username>"` — a semantic **recommendation** (`PendingSuggestion.isSemantic`): offer 2 options (Yes / No) — NO "always", since semantic matches shouldn't auto-share.

The prefix is the menu-option count. Usernames cannot contain `:` (enforced in `ProfileValidation.normalizedUsername`), so the token splits unambiguously on the first colon. The bundled shortcut is hand-edited by the user to consume this.

## Key files

- `Lune/Intents/LuneSafariPageIntent.swift` — "Lune Current Safari Page": `openAppWhenRun = false`. ALWAYS targets `SafariURLStore.lastURL` (from the extension); the `url: URL?` parameter NEVER overrides it. When `url` is present it's a **fuzzy prefix check** (`URLPrefixMatch`: scheme/www./trailing-slash/case ignored, either-direction prefix) → `trackedURLMismatch` on failure; when absent, no check. `app: String?` guards you're in Safari (nil treated as Safari). Returns the **share-suggestion token** (`ReturnsValue<String>`, see above). The save goes through `ReadingListIngestor.handleSavePress` — repeat presses are ignored except the Kindle double-save (see send-to-kindle.md); new-save automation (auto-share, suggestions, watch-later) NEVER runs for repeat presses.
- `Lune/Intents/SaveLinkIntent.swift` — "Save Link": required `url: URL`, same `handleSavePress` path with the URL exactly as given. Returns the saved URL.
- `Lune/Intents/FindYouTubeVideoIntent.swift` — see youtube.md. Returns the **share-suggestion token** (same as LuneSafariPageIntent).
- Platform search/save intents (see `content-platforms.md`): `FindBlueskyPostIntent`, `FindRedditPostIntent` (real search → URL → save, return the token), `SaveMusicItemIntent`/`SavePodcastItemIntent` (URL-less media; return the synthetic key). X/TikTok/Instagram/Facebook have no find-intent (no free search). All registered in `LuneShortcuts`.
- `Lune/Intents/ShareSuggestionIntents.swift` — `SetShareChoiceIntent(choice:)` accepts "Don't Share" / "Share Once" / "Always Share" plus the menu literals "Yes" (→ Share Once) / "No" (→ Don't Share), and acts on the app-side pending suggestion (see social-sharing.md). The former `GetShareSuggestionIntent` / `GetShareSuggestionKindIntent` were REMOVED — the save intents return the token directly.
- `Lune/Intents/LuneShortcuts.swift` — `AppShortcutsProvider` exposing both intents.

## Bundled shortcut

`Lune/Resources/Lune Shortcut.shortcut` — an AEA1-signed `.shortcut` bundle (display name "Lune Shortcut", the single source of truth is `BundledShortcut.displayName`). It is **hand-edited by the user in the Shortcuts app**, then re-exported, because the AEA-wrapped/LZFSE payload can't be regenerated headlessly (see memory). New flow shape the user wires: Get Current App → LuneSafariPageIntent (returns the token string) → split the token on `:` → branch on the prefix (`""` do nothing, `"2"` → 2-option Yes/No menu, `"3"` → 3-option Yes/Always/No menu over `<username>`) → SetShareChoiceIntent with the chosen literal. Settings → "Install Shortcut" (`BundledShortcut.presentInstaller`) shares the bundled file to the Shortcuts app; users RE-IMPORT after changes. NOTE: `shortcuts://import-workflow?url=` REJECTS local file URLs, so install stays share-sheet based.

## User setup (documented in-app: Settings → Action Button Setup)

1. Enable the Safari extension (see safari-extension.md).
2. Settings → Install Shortcut → share to Shortcuts → Add Shortcut. (First run prompts to allow sharing app info with Lune — Always Allow.)
3. Settings → Action Button → Shortcut → pick "Lune Shortcut".

Action Button can't be assigned programmatically; the simulator has no Action Button (test by running the shortcut from the Shortcuts app).
