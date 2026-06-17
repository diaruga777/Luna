# Content Platforms

Click accepts and renders links from many platforms beyond plain articles:
YouTube, X, Bluesky, Reddit, TikTok, Instagram, Facebook, plus provider-agnostic
**music** and **podcast** items (Spotify / Apple). A recognized platform URL is
saved as a no-content `.ready` item (NEVER "Couldn't Load") and rendered with a
platform glyph + creator; tapping runs a launch ladder.

## Architecture (`Clip/Platforms/`, enums in `ReaderKit/`)

- **`ContentPlatform`** (ReaderKit) — `youtube/x/bluesky/reddit/tiktok/instagram/
  facebook/music/podcast`. `MusicProvider` — `apple/spotify`. (In ReaderKit so
  `ReadingListItem` can store them.)
- **`PlatformModule`** — per-platform: `classify(urlString) -> PlatformMatch?`,
  `glyphSymbolName`, `subtitle`, `appDeepLink`, `embed`, optional `metadataFetcher`.
- **`PlatformRegistry`** — ordered modules; `detect(urlString)` (replaces the old
  hardcoded YouTube `if`) and `module(for:)`. Registers all nine.
- **`PlatformEmbedViewController`** — generalized WKWebView embed (16:9, optional
  Referer + "ended" watcher → mark read). Used by YouTube; available to others.
- **`InAppBrowser`** — `SFSafariViewController` wrapper, the ultimate fallback.
- **Row art** is rendered by `ReadingListItemCell` (see reading-list.md): cached
  art aspect-fit, else the platform's bundled brand logo. `ContentPlatform.logoAssetName`
  → full-color favicon-derived PNGs (`logo-youtube/x/bluesky/reddit/tiktok/instagram/facebook`
  in Assets.xcassets); music/podcast fall back to the SF `glyphSymbolName`.

## Data model (`ReaderKit/ReadingListItem.swift`)

Added optionals (decodeIfPresent — back-compatible): `platform`, `platformItemID`
(generalizes `youtubeVideoID`), `mediaCreatorName`, `mediaItemTitle`,
`mediaSourceService`. Computed: `contentPlatform` (falls back to `.youtube` for
legacy items), `isPlatformItem`, `isURLlessMedia`. `isYouTubeVideo` now also true
when `platform == .youtube`.

## Acceptance & rendering

- **Ingest** (`ReadingListIngestor.ingest`): YouTube branch first (keeps its
  bespoke watch-later/suggestion path), then `PlatformRegistry.detect` →
  `ingestPlatformItem` (best-effort metadata via the module's fetcher →
  `ReadingListStore.savePlatformMetadata`, always `.ready`), then the article
  extractor. Platform items never enter `.failed`.
- **Cell**: `ReadingListItemCell` — spinner while fetching, fetched art, or the
  brand-logo fallback. Reddit images: `RedditMetadataFetcher.bestImageURL` tries
  preview source → `media_metadata` gallery → direct `i.redd.it`/imgur → crosspost
  → thumbnail. Creator shows via `channelName`/`mediaCreatorName`.
- **Tap (launch ladder)**: native app deep link (`canOpenURL` → `open` → mark
  read) → in-app embed (`PlatformEmbedViewController`) → `InAppBrowser` (Safari).
  YouTube uses its existing `openVideo`. Music/podcast use `openMediaItem` (below).
- Article-only actions (Kindle/Boox/eBook/Speed Read) are hidden for all platform
  items (`!isPlatformItem`); ereader send guards broadened to `isPlatformItem`.

## Per-platform capability

| Platform | Classify | Metadata | App link | Embed | Search intent |
|---|---|---|---|---|---|
| YouTube | `YouTubeURL` | oEmbed (existing) | `youtube://` | yes | `FindYouTubeVideoIntent` |
| Bluesky | `BlueskyLink` | oEmbed (author) | — | — | `FindBlueskyPostIntent` (keyless searchPosts) |
| X | `XLink` | fxtwitter (author/text) | `twitter://status?id=` | — | none (no free search) |
| TikTok | `TikTokLink` | oEmbed (author/title/thumb) | — | — | none |
| Reddit | `RedditLink` | public `.json` (title/subreddit) | — | — | `FindRedditPostIntent` (public search.json) |
| Instagram | `InstagramLink` | og: scrape (login-walled → logo) | — | — | none |
| Facebook | `FacebookLink` | og: scrape | — | — | none |
| Music | `MediaLink` | iTunes Lookup / Spotify oEmbed | preferred app | — | `SaveMusicItemIntent` (URL-less) |
| Podcast | `MediaLink` | Apple: SCRAPE the page (`og:title` episode + `og:image` art) + iTunes lookup of the show id for the show name — episode ids are NOT lookup-able. Spotify: oEmbed. | preferred app | — | `SavePodcastItemIntent` (URL-less) |

X/TikTok/Instagram/Facebook have **no free search**, so they have no find-intent
(an always-failing intent is worse than none) — captured via the share sheet /
paste / Safari, which always yield the full URL and bypass the ingestor.

## Music & Podcasts portability

`MediaLink` classifies Spotify/Apple URLs into a provider-agnostic `music`/
`podcast` item + `sourceService`. `MediaProviderSettings` (App Group) holds the
preferred app per kind (nil = unset). `openMediaItem`: exact same-provider link
(web→app scheme via `MediaLink.appSchemeURL`) → search in the preferred app
(`MusicProvider.appSearchURL`) → Safari (original URL or web search). Unset →
prompt to choose in Settings → "Music & Podcasts".

**URL-less items** (no shareable http URL) come from `SaveMusicItemIntent`/
`SavePodcastItemIntent` (now-playing OCR via the shortcut). Keyed by a synthetic
`clickmusic://`/`clickpodcast://` (`MediaItemKey`); `ReadingListStore.
createURLlessMediaItem`. They share via the CloudKit **`mediaItem`** case
(`MessageBody.mediaItem(kind:creator:title:)` + `SocialMessageCenter.
sendMediaItem`/receive), not as URLs. URL-based platform items share for free via
the existing `readingListItem` path (recipient re-classifies via the registry).

## Info.plist

`LSApplicationQueriesSchemes`: `youtube, twitter, x, bluesky, reddit, spotify,
music, podcasts, tiktok, snssdk1233, instagram, fb` (so `canOpenURL` works).

## Bundled Shortcut (manual)

The OCR-driven capture flow (current app → screenshot → scan text → the matching
`Find…`/`Save…` intent) must be authored in the Shortcuts app and re-bundled
(`BundledShortcut`); the `.shortcut` binary can't be generated in code. **Pending
manual step.**

## Tests (`ClipTests/`)

`PlatformRegistryTests`, `BlueskyLinkTests`, `PlatformParsersTests` (X/TikTok/
Reddit/Instagram/Facebook), `MediaPlatformTests` (parse/scheme/search-links/
URL-less creation/`mediaItem` round-trip). Network is not hit in tests.

## Caveats (unverified live)

fxtwitter/oEmbed/og-scrape endpoints and rate limits can change; IG/FB scrapes
are often login-walled (→ logo fallback). App-scheme opens depend on the app
being installed. Not validated end-to-end against every live service.
