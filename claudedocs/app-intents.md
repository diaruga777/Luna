# App Intents (`Clip/Intents/`)

All save actions are `AppIntent`s. They appear in the Shortcuts **action search**
when discoverable; the ones in `ClipShortcuts` (`AppShortcutsProvider`) also show
prominently at the top of the app's Shortcuts page + Spotlight.

> **Hard limit: an `AppShortcutsProvider` may list AT MOST 10 `AppShortcut`s.**
> Exceeding it is a HALTING build error in `appintentsmetadataprocessor` — and
> then NO AppIntents metadata is exported at all (every intent disappears from
> Shortcuts). Keep `ClipShortcuts.appShortcuts` ≤ 10.

To check what's actually registered, inspect the built metadata:
`Clip.app/Metadata.appintents/extract.actionsdata` (JSON; `autoShortcuts` = the
provider list, `actions` = all discoverable intents).

## The 10 prominent App Shortcuts (`ClipShortcuts.swift`)

`ClipSafariPageIntent`, `SaveLinkIntent`, `FindYouTubeVideoIntent`,
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
  via `SocialPostFinder` (keyless DuckDuckGo HTML search scoped to the platform's
  domain, filtered to a post-shaped path). No public search API exists for these,
  so this is best-effort.

## Generic / AI flow

- **`SaveFromAppIntent`** (`app`, `values: [String]`, both optional): routes by the
  current app to the right per-platform save. Per-app value order is documented in
  its description — Safari/other `[link]`, YouTube `[channel, title]`, Bluesky
  `[handle, text]`, Reddit `[subreddit, title, author?]`, Music/Spotify
  `[artist, title]`, Podcasts `[show, episode title]`, X/TikTok/Instagram/Facebook
  `[link]`.
- **`ScreenAnalysisPromptIntent`** (`app`, optional): returns the per-app prompt
  (`AppNamePlatform.screenPrompt`) telling an image model to read the current
  app's screen and output exactly those ordered fields, " ; "-separated, or
  "none". The bundled shortcut: Get Current App → Screen Analysis Prompt →
  (screenshot + prompt → image model) → split on " ; " → Save from App.

> **ITMS-90626**: an App Intent `title`/`description`/parameter string must NEVER
> contain "apple" or Siri references, or App Store processing silently drops the
> build. (Doc comments, `.apple` enum cases, and `itunes.apple.com` URLs in code
> are fine — only the AppIntents metadata strings are scanned.) Use "Music or
> Spotify" / "Podcasts", not "Apple Music" / "Apple Podcasts".
