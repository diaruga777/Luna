# Content Platforms

Luna accepts articles, documents, products, supported social/video links, and
direct HTTP(S) media-file URLs.
Recognized platform URLs are saved as ready items and open through the platform's
native deep link, embed, or in-app browser fallback.

## Supported platforms

`ContentPlatform` contains X, Bluesky, Reddit, TikTok, Instagram, Facebook,
YouTube, and the synthetic `web` value used for directly hosted media.
`PlatformRecognizer` is the single URL-classification table; `PlatformRegistry`
owns each platform module's presentation and optional metadata fetcher.

Music and podcast items are no longer a Luna content type. Spotify, Apple Music,
and Apple Podcasts URLs are not classified as platform media and cannot create
URL-less saved items through App Intents or the saves list. The Safari
extension's `content.js` recognizes exactly these six platforms too (generated
from `PlatformRecognizer` — see `safari-extension.md`'s "Shared platform-host
list"); it no longer shows a "Download in Luna" pill on Spotify/Apple
Music/Apple Podcasts pages, since the app has no way to act on them.

## Ingestion and rendering

`IngestPipeline` routes recognized social/video URLs directly to their typed
outcomes, so they never enter article extraction. `SavesIngestor` persists
the platform, item identifier, available title, and thumbnail, then marks
the item ready. Platform items do not become failed articles when metadata is
unavailable.

`DirectMediaURL` is the shared URL-only detector for direct image, animated GIF,
video, and audio assets. It recognizes the file extension in the URL path
(including signed CDN URLs with query strings), and `Classifier` routes a match
to `.video(.web, itemID: nil)` before any HTML fetch. The synthetic platform
keeps the existing Downloader-owned outcome/persistence path while the media
download layer uses the source URL itself as the already-resolved `MediaAsset`.

The saves list renders cached art when present, otherwise the platform logo.
Tapping uses the module's native-app link first, then an embed, then the in-app
browser.

Platform posts can also be captured without a link via the Action Button
screenshot flow (`app-intents.md`): the Save intent's vision model reads the
platform app's screen and `PlatformFieldSave` finds the post through the
platform's search (`BlueskyPostQuery`/`RedditPostQuery`) or the keyless
`SocialPostFinder` (X/TikTok/Instagram/Facebook), then saves the resolved URL
through the normal ingest path above.

## Tests

Platform recognition and presentation are covered by the platform parser and
registry tests. No music or podcast capture tests remain because those save paths
have been retired.
