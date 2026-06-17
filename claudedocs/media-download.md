# Social Media Download to Photos

Downloads still images, GIFs, and videos from **X, Instagram, and TikTok** posts and
saves them to the user's photo library (PhotoKit). If a post has multiple media items,
the **first** is taken. Mirrors public web downloaders (twittervideodownloader,
snapinsta, …) with keyless, client-side extraction.

## Entry points

1. **Action extension ("Queue it")** — `ShareKit/SavedNonTextualViewController` shows a
   **"Download media to photo roll"** button for X/Instagram/TikTok posts (gated on
   `MediaDownloadablePlatform.supports`). Tapping swaps the button for a `UIProgressView`
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
  - `InstagramMediaParser` — post/embed HTML: `"video_url"` / `og:video` → video, else
    `"display_url"` / `EmbeddedMediaImage` / `og:image` → image; `unescape` fixes
    `&`,`\/`,`&amp;`. The resolver fetches the POST page FIRST with a link-unfurler UA
    (`facebookexternalhit/1.1`, which exposes `og:video`) and prefers a video asset;
    the `/embed/captioned/` page is only the image fallback (it lacks the video — the
    earlier embed-first order saved a still from videos).
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
rate-limited or login-walled: Instagram is the most fragile (login wall → no media),
TikTok `playAddr` can 403 without page cookies. The parsers are tested; live extraction
is not guaranteed end-to-end. Twitter "GIFs" are mp4 and save as videos.

## Tests

`ClipTests/MediaDownloadTests.swift` — platform support, X/TikTok/Instagram parsers
(incl. fallbacks + unescape), `fileExtension` mapping, and resolver dispatch via an
injected fetch. Network is not hit.
