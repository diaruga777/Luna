# Content Platforms

Luna accepts articles, documents, products, and supported social/video links.
Recognized platform URLs are saved as ready items and open through the platform's
native deep link, embed, or in-app browser fallback.

## Supported platforms

`ContentPlatform` contains X, Bluesky, Reddit, TikTok, Instagram, and Facebook.
`PlatformRecognizer` is the single URL-classification table; `PlatformRegistry`
owns each platform module's presentation and optional metadata fetcher.

Music and podcast items are no longer a Luna content type. Spotify, Apple Music,
and Apple Podcasts URLs are not classified as platform media and cannot create
URL-less saved items through App Intents or the reading list.

## Ingestion and rendering

`IngestPipeline` routes recognized social/video URLs directly to their typed
outcomes, so they never enter article extraction. `ReadingListIngestor` persists
the platform, item identifier, available title/creator, and thumbnail, then marks
the item ready. Platform items do not become failed articles when metadata is
unavailable.

The reading list renders cached art when present, otherwise the platform logo.
Tapping uses the module's native-app link first, then an embed, then the in-app
browser.

## Tests

Platform recognition and presentation are covered by the platform parser and
registry tests. No music or podcast capture tests remain because those save paths
have been retired.
