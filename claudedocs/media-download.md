# Social Media Download to Photos

Downloads still images, GIFs, and videos from **X, Instagram, and TikTok** posts and
saves them to the user's photo library (PhotoKit). If a post has multiple media items,
the **first** is taken. Mirrors public web downloaders (twittervideodownloader,
snapinsta, …) with keyless, client-side extraction.

## Entry points

1. **Action extension ("Queue it")** — `ShareKit/SavedNonTextualViewController` shows a
   **fixed-height inline media preview** for X/Instagram/TikTok/Facebook posts (gated on
   `MediaDownloadablePlatform.supports`). Unlike the old static-poster preview, it
   downloads the **actual media file** and shows it inline, driven by a small **state
   machine** (`MediaState`: `pending` / `downloading` / `ready(DownloadedMedia)` /
   `failed`). The preview area reserves constant space from load (so neither the elements
   above nor the friend list below shift), hosting a spinner, the still/poster image
   (`.scaleAspectFit`), a video play overlay, a pending media icon, and a load-failure
   placeholder. The flow:
   - **Auto vs pending** — gated on the master `AutoDownloadSettings.autoDownloadMediaInPreview`
     setting (App Group, **default ON**). ON → `startMediaDownload()` runs on appear
     (`downloading`: large spinner + progress bar). OFF → starts `pending` (media icon +
     **"Download media"** button; tapping it starts the download).
   - **Download** — `MediaDownloadService.downloadFirstMediaToFile(from:onProgress:)`
     streams the first asset to a temp file **without** touching Photos (no permission
     prompt while previewing). On success → `ready`; on failure → `failed` (error + retry
     via the same button).
   - **Inline display** — in `ready`, an image/gif renders downsampled (ImageIO, max 1400);
     a **video** renders a poster frame (`AVAssetImageGenerator`) with a red play overlay,
     and **tapping the preview plays it** in an `AVPlayerViewController`. The still is
     persisted into the shared store as the platform card thumbnail (`setThumbnail`).
   - **Save to Photos** — a **"Save to Photos"** button enables once `ready`. Tapping it
     calls `MediaDownloadService.saveDownloadedMediaToPhotos` (requests add-only auth, then
     `PhotoLibrarySaver.save`), marks the URL downloaded (`AutoDownloadSettings.markDownloaded`),
     and **marks the reading-list item read** (`ReadingListStore.markReadState(.read,…)` —
     NEW: saving now consumes the item). On success it becomes a green "Saved to Photos"
     checkmark; on failure it shows the error and re-enables.
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
  `.x/.instagram/.tiktok`, `supports(urlString)` via `PlatformRecognizer`), and the
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
  saves. The split path for the action-extension inline preview is
  `downloadFirstMediaToFile(from:onProgress:)` (resolves + downloads to a temp file, **no**
  Photos prompt → returns `DownloadedMedia { fileURL, kind }`) and
  `saveDownloadedMediaToPhotos(_:)` (requests auth, then saves). `MediaFileDownloader`
  (URLSessionDownloadDelegate) streams to a temp file with progress and picks the extension
  by kind + MIME (`fileExtension`). TikTok downloads set a `https://www.tiktok.com/` Referer.
- **`PhotoLibrarySaver.swift`** — `.addOnly` authorization; `PHAssetCreationRequest`
  `addResource(with: .video/.photo, fileURL:, options.shouldMoveFile=true)`.

## Auto-download settings

`Settings → Auto-Download Media` (`AutoDownloadSettingsScreen`) has two sections, both
stored in `AutoDownloadSettings` (App Group `group.com.hpiddy.clip`, readable by app +
extensions):

1. **Master "Auto-download media"** toggle (`autoDownloadMediaInPreview`, **default ON**)
   — controls whether the action extension's inline preview auto-downloads on appear vs
   starts pending with a manual button. No Photos prompt (downloading inline doesn't touch
   Photos).
2. **Per-platform auto-save-to-Photos** toggles (below) used by the main app's ingest
   funnel.

Turning a per-platform toggle on requests Photos add
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
