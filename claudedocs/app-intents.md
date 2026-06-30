# App Intents (`Lune/Intents/`)

All save actions are `AppIntent`s. They appear in the Shortcuts **action search**
when discoverable; the ones in `LuneShortcuts` (`AppShortcutsProvider`) also show
prominently at the top of the app's Shortcuts page + Spotlight.

> **Hard limit: an `AppShortcutsProvider` may list AT MOST 10 `AppShortcut`s.**
> Exceeding it is a HALTING build error in `appintentsmetadataprocessor` — and
> then NO AppIntents metadata is exported at all (every intent disappears from
> Shortcuts). Keep `LuneShortcuts.appShortcuts` ≤ 10.

To check what's actually registered, inspect the built metadata:
`Lune.app/Metadata.appintents/extract.actionsdata` (JSON; `autoShortcuts` = the
provider list, `actions` = all discoverable intents).

## The 10 prominent App Shortcuts (`LuneShortcuts.swift`)

`LuneSafariPageIntent`, `SaveLinkIntent`, `FindYouTubeVideoIntent`,
`FindBlueskyPostIntent`, `FindRedditPostIntent`, `SaveXPostIntent`,
`SaveTikTokIntent`, `SaveInstagramPostIntent`, `SaveFromAppIntent`,
`ScreenAnalysisPromptIntent`. (Save Song / Save Podcast / Save Facebook are
discoverable in the action search but not in the prominent list.)

## Per-platform save intents (precise params, not vague search strings)

- **YouTube** (`FindYouTubeVideoIntent`): `channel` + `title` → YouTube Data API
  search (needs sign-in).
- **Bluesky** (`FindBlueskyPostIntent`): `handle` + `text` → `from:<handle> <text>`
  (`BlueskyPostQuery`).
- **Reddit** (`FindRedditPostIntent`): `subreddit` + `title` + optional `author` →
  `<title> subreddit:<sub> author:<user>` (`RedditPostQuery`).
- **Music** (`SaveMusicItemIntent`): `artist` + `title` (URL-less).
- **Podcast** (`SavePodcastItemIntent`): `show` + `episode` (episode is a TITLE
  string, NOT a number — stated in the param description).
- **X / TikTok / Instagram / Facebook** (`PlatformLinkIntents.swift`): each takes
  the author `handle` + a content phrase and/or timestamp and FINDS the post link
  via `SocialPostFinder`. It tries progressively looser keyless DuckDuckGo HTML
  queries — quoted phrase → unquoted → no `site:` filter — sanitizes the phrase
  (strips quotes, caps length), then `bestMatch` keeps only post-shaped URLs on the
  platform's hosts and prefers one whose path contains the handle. No public search
  API exists, so this is best-effort.

## Generic / AI flow

- **`SaveFromAppIntent`** (`app`, `details: String`, both optional): routes by the
  current app to the right per-platform save. `details` is the **single** response
  string the on-device model produced for that app's screen; `parseFields` splits
  it on `" ; "` (trimming, dropping empties; `"none"`/empty → no fields). Per-app
  field order — YouTube `channel ; title`, Bluesky `handle ; phrase`, Reddit
  `subreddit ; title ; author`, Music/Spotify `artist ; title`, Podcasts
  `show ; episode title`, X/TikTok/Instagram/Facebook `handle ; phrase ; date?` (the
  prompt asks for an exact short quote and appends the post date/time when visible —
  the optional timestamp field helps the lookup). Safari and
  unknown apps may pass an empty/nil `details` — a `http…` link in the response is
  used if present, else `SafariURLStore.lastURL` (the tracked page). Returns the
  share-suggestion token (`ShareSuggestionStore.pendingSuggestionToken` — `"3:<name>"`
  streak / `"2:<name>"` semantic / `""`) for the shortcut to branch on.
- **`ScreenAnalysisPromptIntent`** (`app`, optional): returns the per-app prompt
  (`AppNamePlatform.screenPrompt`) telling an image model to read the current app's
  screen and respond with a **single line** in exactly the `" ; "`-joined format
  `SaveFromAppIntent.parseFields` expects, or `"none"`. Returns the exact string
  `"unsupported"` when the current app is neither a known platform nor Safari
  (`AppNamePlatform.isSupported` is false — the shortcut branches on it), and `""`
  for a supported app that needs no prompt (Safari → the tracked page URL is saved).
  The bundled shortcut: Get Current App → Screen Analysis Prompt → (screenshot +
  prompt → image model) → Save from App (`details` = that model response string). A
  model error / "none" passes through as empty → nothing to save (Safari still saves
  the tracked URL).

> **ITMS-90626**: an App Intent `title`/`description`/parameter string must NEVER
> contain "apple" or Siri references, or App Store processing silently drops the
> build. (Doc comments, `.apple` enum cases, and `itunes.apple.com` URLs in code
> are fine — only the AppIntents metadata strings are scanned.) Use "Music or
> Spotify" / "Podcasts", not "Apple Music" / "Apple Podcasts".
