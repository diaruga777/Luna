# Social Media Download to Photos

Downloads still images, GIFs, and videos from **X, Instagram, and TikTok** posts and
saves them to the user's photo library (PhotoKit). If a post has multiple media items,
the **first** is taken. Mirrors public web downloaders (twittervideodownloader,
snapinsta, …) with keyless, client-side extraction.

## Entry points

1. **Action extension ("Queue it")** — `ShareKit/SavedNonTextualViewController` shows,
   between the saved-confirmation label and the download button, a **fixed-height static
   media preview** (the poster for a video) for X/Instagram/TikTok posts (gated on
   `MediaDownloadablePlatform.supports`). The preview space is reserved from load with a
   spinner while `MediaPreviewFetcher.fetchPreview` resolves the post (the same
   `SocialMediaResolver` the download uses) and loads a downsampled image — the resolved
   asset for an image, the `og:image` poster for a video. The **"Download media to photo
   roll"** button stays invisible-but-space-holding (`alpha`, never `isHidden`) until that
   fetch confirms media exists; if there's no media the spinner just hides. The preview
   image uses `.scaleAspectFill` so a tall poster fills the well instead of rendering as
   a thin centered strip. Critically the
   preview/button reserve constant space so neither the elements above nor the friend list
   below shift with the media state. Tapping the button swaps it for a `UIProgressView`
   + status label; on success it becomes a green checkmark + "Saved to Photos" (the user
   exits via Done), on failure it shows the error and re-enables to retry.
2. **Reading list row long-press** — `ReadingListViewController.downloadMediaToPhotos`
   adds a **"Download Media to Photos"** action (`photo.badge.arrow.down`) for the same
   platforms. Progress + result show in a **non-blocking bottom pill**
   (`MediaDownloadStatusView`, `isUserInteractionEnabled=false`) — the list stays
   tappable and the pill is a subview of the list so it never appears over the reader.
   The download + save continues if the app is backgrounded (a `beginBackgroundTask`
   assertion around the work).

## Core (`ReaderKit/MediaDownload/`, shared by app + action ext)

- **`MediaDownload.swift`** — `MediaAsset` (`url` + `Kind` = image/gif/video),
  `MediaDownloadError` (with `.message`), `MediaDownloadablePlatform` (supported set =
  `.x/.instagram/.tiktok`, `supports(urlString)` via `PlatformClassifier`), and the
  protocols `SocialMediaResolving` / `PhotoLibrarySaving` / `MediaDownloading`.
- **`SocialMediaResolver.swift`** — `resolveAssets(for:)` dispatches by platform; fetch
  is injectable (`Fetch` closure) so the **pure parsers** are unit-tested:
  - `XMediaParser` — fxtwitter JSON `https://api.fxtwitter.com/status/<id>`; uses
    `tweet.media.all` (ordered, typed: photo→image, video/gif→video=mp4), falls back to
    `videos`/`photos`.
  - `TikTokMediaParser` — the page's `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">`
    JSON → `…webapp.video-detail.itemInfo.itemStruct`: `imagePost.images[].imageURL.urlList[0]`
    (photo carousel) else `video.playAddr` (no-watermark) / `video.downloadAddr`.
  - `InstagramMediaParser` — the resolver fetches the **`/p/{code}/embed/captioned/`
    page FIRST** and parses its `contextJSON` blob (`assetsFromEmbedContextJSON`): a
    JSON-encoded string holding `gql_data.shortcode_media`, from which it reads
    `video_url` (GraphVideo / `is_video`), `display_url` (image), or an
    `edge_sidecar_to_children` carousel — clean URLs straight from parsed JSON. This is
    the only reliable keyless source for a reel's real video; the crawler `og:` tags
    now expose ONLY the poster still behind a login wall, so the OLD og-first order
    saved a still from every video reel. Fallbacks (in order): legacy regex
    `assets(fromHTML:)` (`"video_url"` / `"display_url"` / `og:` tags; `unescape` fixes
    `&`,`\/`,`&amp;`), then the post page's `og:` tags via `facebookexternalhit/1.1`.
  - Requests use a desktop Safari UA (`MediaDownloadHTTP.browserUserAgent`).
- **`MediaDownloadService.swift`** — `downloadFirstMediaToPhotos(from:onProgress:)`:
  guards `supports`, requests add-only auth FIRST, resolves, downloads the first asset,
  saves. `MediaFileDownloader` (URLSessionDownloadDelegate) streams to a temp file with
  progress and picks the extension by kind + MIME (`fileExtension`). TikTok downloads set
  a `https://www.tiktok.com/` Referer.
- **`PhotoLibrarySaver.swift`** — `.addOnly` authorization; `PHAssetCreationRequest`
  `addResource(with: .video/.photo, fileURL:, options.shouldMoveFile=true)`.

## Auto-download (per-platform toggle)

`Settings → Auto-Download Media` (`AutoDownloadSettingsScreen`) has per-platform
toggles (`AutoDownloadSettings`, App Group). Turning one on requests Photos add
access (`PhotoLibrarySaver.requestAddAuthorization`) and reverts if denied.
`MediaAutoDownloader.runIfEnabled(forURLString:)` is called from the ingest funnel
(`ReadingListIngestor.ingestPlatformItem`): when the saved post's platform is
enabled it downloads the first media item to Photos in the background. The download is **awaited** in the ingest funnel (`runIfEnabledAwaiting`), so an app
intent finishes the download before returning (intents run in the main-app process,
sharing the toggle's Photos grant). The **share extension stays alive** showing a
"Saving media…" glass spinner until the download completes, then a "Saved" checkmark,
then dismisses (`ShareViewController.autoDownloadThenComplete`) — so the process isn't
killed mid-download. A bounded dedup list (`AutoDownloadSettings.markDownloaded`/
`wasDownloaded`) means a post downloaded in one process isn't downloaded again when
the main app re-ingests it. Note: the share extension has its OWN Photos permission
(separate from the main app); it prompts within the extension on first use.

## Permissions

`NSPhotoLibraryAddUsageDescription` is in both `Clip/Info.plist` and
`Clip Action Extension/Info.plist`.

## Caveats (best-effort, like the web tools)

Keyless extraction depends on third-party/undocumented endpoints that change and may be
rate-limited or login-walled: Instagram video relies on the embed `contextJSON` (verified
working for reels); if Instagram drops it the fallbacks yield only the poster still.
TikTok `playAddr` can 403 without page cookies. The parsers are tested; live extraction
is not guaranteed end-to-end. Twitter "GIFs" are mp4 and save as videos.

## Tests

`ClipTests/MediaDownloadTests.swift` — platform support, X/TikTok/Instagram parsers
(incl. fallbacks + unescape), `fileExtension` mapping, and resolver dispatch via an
injected fetch. Network is not hit.
