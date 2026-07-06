# Intents & Action Button Shortcut

Press the Action Button while reading in Safari -> the current page is saved to
the reading list, no UI, no app switch.

## Return Value

Save intents return a simple status string such as `"Saved to Luna."`. They no
longer return or consume friend-share suggestion tokens.

## Key Files

- `Luna/Intents/LunaSafariPageIntent.swift` - "Luna Current Safari Page":
  `openAppWhenRun = false`. ALWAYS targets `SafariURLStore.lastURL` (from the
  extension); the `url: URL?` parameter NEVER overrides it. When `url` is
  present it's a fuzzy prefix check (`URLPrefixMatch`:
  scheme/www./trailing-slash/case ignored, either-direction prefix) ->
  `trackedURLMismatch` on failure; when absent, no check. `app: String?` guards
  you're in Safari (nil treated as Safari). Returns a status string. The save
  goes through `ReadingListIngestor.handleSavePress`; repeat presses are ignored
  except the Kindle double-save (see `send-to-kindle.md`).
- `Luna/Intents/SaveLinkIntent.swift` - "Save Link": required `url: URL`, same
  `handleSavePress` path with the URL exactly as given. Returns the saved URL.
- `Luna/Intents/FindYouTubeVideoIntent.swift` - see `youtube.md`. Returns a
  status string.
- Platform search/save intents (see `content-platforms.md`):
  `FindBlueskyPostIntent`, `FindRedditPostIntent` (real search -> URL -> save,
  return a status string), `SaveMusicItemIntent`/`SavePodcastItemIntent`
  (URL-less media; return the synthetic key). X/TikTok/Instagram/Facebook have
  no find-intent (no free search). All registered in `LunaShortcuts`.
- `Luna/Intents/LunaShortcuts.swift` - `AppShortcutsProvider` exposing the save
  intents.

## Bundled Shortcut

`Luna/Resources/Luna Shortcut.shortcut` - an AEA1-signed `.shortcut` bundle
(display name "Luna Shortcut", the single source of truth is
`BundledShortcut.displayName`). Settings -> "Install Shortcut"
(`BundledShortcut.presentInstaller`) shares the bundled file to the Shortcuts
app. NOTE: `shortcuts://import-workflow?url=` REJECTS local file URLs, so
install stays share-sheet based.

## User Setup For Action Button Shortcut

1. Enable the Safari extension (see `safari-extension.md`).
2. Settings -> Install Shortcut -> share to Shortcuts -> Add Shortcut. First run
   prompts to allow sharing app info with Luna; choose Always Allow.
3. Settings -> Action Button -> Shortcut -> pick "Luna Shortcut".

The Action Button shortcut setup section is hidden below iOS 27, but the Safari
extension's in-page "Read in Luna" button remains available from Settings ->
Shortcut & Safari. Action Button can't be assigned programmatically; the
simulator has no Action Button (test by running the shortcut from the Shortcuts
app).
