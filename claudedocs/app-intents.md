# App Intents (`Luna/Intents/`)

All save actions are `AppIntent`s. They appear in the Shortcuts **action search**
when discoverable; the ones in `LunaShortcuts` (`AppShortcutsProvider`) also show
prominently at the top of the app's Shortcuts page + Spotlight.

> **Hard limit: an `AppShortcutsProvider` may list AT MOST 10 `AppShortcut`s.**
> Exceeding it is a HALTING build error in `appintentsmetadataprocessor` — and
> then NO AppIntents metadata is exported at all (every intent disappears from
> Shortcuts). Keep `LunaShortcuts.appShortcuts` ≤ 10.

To check what's actually registered, inspect the built metadata:
`Luna.app/Metadata.appintents/extract.actionsdata` (JSON; `autoShortcuts` = the
provider list, `actions` = all discoverable intents).

## The 10 prominent App Shortcuts (`LunaShortcuts.swift`)

`FindBlueskyPostIntent`, `FindRedditPostIntent`, `SaveXPostIntent`,
`SaveTikTokIntent`, `SaveInstagramPostIntent`, `SaveFromAppIntent`,
`ScreenAnalysisPromptIntent`. (Save Song / Save Podcast / Save Facebook are
discoverable in the action search but not in the prominent list.)

## Per-platform save intents (precise params, not vague search strings)

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

- **`SaveFromAppIntent`** (`app`, `details: String`, both optional): FIRST, before
  any save work, gives the Action Button onboarding state machine
  (`LunaStorage.ActionButtonOnboardingStore.handleSaveIntentInvoked`) a chance to
  intercept the call — see "Action Button onboarding" below. If it doesn't
  intercept, routes by the current app to the right per-platform save. `details` is
  the **single** response string the on-device model produced for that app's
  screen; `parseFields` splits it on `" ; "` (trimming, dropping empties;
  Bluesky `handle ; phrase`, Reddit `subreddit ; title ; author`, Music/Spotify
  `artist ; title`, Podcasts `show ; episode title`, X/TikTok/Instagram/Facebook
  `handle ; phrase ; date?` (the prompt asks for an exact short quote and appends
  the post date/time when visible — the optional timestamp field helps the
  lookup). Safari and unknown apps may pass an empty/nil `details` — a `http…` link
  in the response is used if present, else `SafariURLStore.lastURL` (the tracked
  page). Returns `"Saved to Luna."` on a normal save, or `"4:<url>"` when a
  media-downloadable link was saved but auto-download is off (the shortcut can
  branch on the `4:` prefix to offer downloading).
- **`ScreenAnalysisPromptIntent`** (`app`, optional): returns the per-app prompt
  (`AppNamePlatform.screenPrompt`) telling an image model to read the current app's
  screen and respond with a **single line** in exactly the `" ; "`-joined format
  `SaveFromAppIntent.parseFields` expects, or `"none"`. Returns the exact string
  `"unsupported"` when the current app is neither a known platform, Safari, nor
  Shortcuts (`AppNamePlatform.isSupported` is false — the shortcut branches on it),
  and `""` for a supported app that needs no prompt (Safari → the tracked page URL
  is saved; Shortcuts → see below). The bundled shortcut: Get Current App → Screen
  Analysis Prompt → (screenshot + prompt → image model) → Save from App (`details` =
  that model response string). A model error / "none" passes through as empty →
  nothing to save (Safari still saves the tracked URL).

## Action Button onboarding (`LunaStorage.ActionButtonOnboardingStore`)

The iOS 27+ Action Button is set up by importing the bundled `Send To
Luna.shortcut` (Get Current App → Screen Analysis Prompt → [screenshot + prompt →
image model] → Save from App) and assigning it to the Action Button in Settings.
Both `SaveFromAppIntent` invocations that happen DURING this setup — one from the
Shortcuts app's own first run, one from wherever the Action Button is actually
pressed — need to behave differently from a normal save; `AppNamePlatform` treats
app name **"Shortcuts"** exactly like Safari (`isShortcuts(forAppName:)`; supported,
no screen prompt) so the first of these never reaches "unsupported".

`ActionButtonOnboardingStore` (`LunaLibraries/Sources/LunaStorage/`) is a
per-surface (`AppSurface.storageIdentifier`: `"reader"`/`"downloader"`/
`"pricetracker"`) state machine persisted in App Group `UserDefaults`
(`onboarding.actionButtonState.<surface>`), driven by:
- `SceneDelegate.sceneWillEnterForeground` / `AppDelegate.applicationDidEnterBackground`
  → `handleAppForegrounded`/`handleAppBackgrounded` (track the Luna↔Shortcuts↔Settings
  round trip),
- the onboarding UI → `beginInstallStep` / `markSettingsDeeplinkTapped`,
- `SaveFromAppIntent.perform()` → `handleSaveIntentInvoked(appName:isCurrentAppLuna:forSurface:)`,
  called before any save logic. It returns `.returnOpenLunaToken` (the intent
  returns `ActionButtonOnboardingStore.openLunaToken`, i.e. `"open-luna"` — the
  bundled shortcut's own "Open App → Luna" branch keys off this exact string),
  `.returnEmpty` (returns `""` — Luna is already frontmost, no bounce-back needed;
  the in-app UI reacts to `ActionButtonOnboardingStore.stateDidChangeNotification`
  instead), or `.none` (no interception — the normal save flow proceeds
  untouched).

`SystemSettingsLink.openActionButton()` deep-links Settings → Action Button
(`App-Prefs:root=ACTION_BUTTON`, falling back through the same private-scheme
cascade as `open()`).

> **ITMS-90626**: an App Intent `title`/`description`/parameter string must NEVER
> contain "apple" or Siri references, or App Store processing silently drops the
> build. (Doc comments, `.apple` enum cases, and `itunes.apple.com` URLs in code
> are fine — only the AppIntents metadata strings are scanned.) Use "Music or
> Spotify" / "Podcasts", not "Apple Music" / "Apple Podcasts".
