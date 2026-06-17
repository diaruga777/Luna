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
   platforms; shows a "Saving media…" toast then a success/error toast.

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
    `&`,`\/`,`&amp;`. Resolver tries the `/embed/captioned/` page first, then the post page.
  - Requests use a desktop Safari UA (`MediaDownloadHTTP.browserUserAgent`).
- **`MediaDownloadService.swift`** — `downloadFirstMediaToPhotos(from:onProgress:)`:
  guards `supports`, requests add-only auth FIRST, resolves, downloads the first asset,
  saves. `MediaFileDownloader` (URLSessionDownloadDelegate) streams to a temp file with
  progress and picks the extension by kind + MIME (`fileExtension`). TikTok downloads set
  a `https://www.tiktok.com/` Referer.
- **`PhotoLibrarySaver.swift`** — `.addOnly` authorization; `PHAssetCreationRequest`
  `addResource(with: .video/.photo, fileURL:, options.shouldMoveFile=true)`.

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
