# Social Media Download

Downloads still images, GIFs, and videos from **X, Instagram, TikTok, and Facebook** posts.
In **Luna Downloader**, supported saves always download the first media item into Luna's
app-owned saved-media library; sibling apps can still save to the user's photo library
(PhotoKit) from their legacy manual/opt-in paths. If a post has multiple media items, the **first** is taken. Mirrors
public web downloaders (twittervideodownloader, snapinsta, …) with keyless, client-side
extraction.

## Entry points

1. **Action extension ("Luna it")** — `ShareKit/SavedNonTextualViewController` shows a
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
   - **Auto-persist into the app library (Downloader only)** — the moment the media is
     `ready`, `persistToDownloaderLibraryIfNeeded` moves a **copy** of the downloaded file
     into `SavedMediaStore` (the grid's data source) and marks the URL downloaded, so a
     shared post shows up in the home grid with no extra tap. This is what makes saves
     actually land in the Downloader; without it the file only ever reached Photos and the
     grid stayed empty (the in-app ingest funnel's dedup then skipped it, because the
     preview download had already set `markDownloaded`). No-op in sibling apps, whose media
     flow stays Photos-only. A COPY is stored so the live preview file remains playable and
     usable for the explicit Photos export below.
   - **Save to Photos** — a **"Save to Photos"** button enables once `ready`. Tapping it
     calls `MediaDownloadService.saveDownloadedMediaToPhotos` (requests add-only auth, then
     `PhotoLibrarySaver.save`), marks the URL downloaded (`AutoDownloadSettings.markDownloaded`),
     and **marks the reading-list item read** (`ReadingListStore.markReadState(.read,…)` —
     NEW: saving now consumes the item). On success it becomes a green "Saved to Photos"
     checkmark; on failure it shows the error and re-enables. On Downloader this is a pure
     Photos export — the app-library copy already exists from the auto-persist step.
2. **Downloader saved-media grid** — the Downloader app's root screen is
   `SavedMediaGridViewController`, a Photos-style chronological grid backed by
   `SavedMediaStore`. Tapping an item opens a local-file viewer/player
   (`AVPlayerViewController` for videos, zoomable image view for stills/GIFs). Context
   menus expose Share and Delete. The old reading-list UI remains the root only for
   Reader, Price Tracker, and debug/test combined-list surfaces.
3. **Reading list row long-press** — `ReadingListViewController.saveMediaToPhotos`
   adds a **"Save to Photos"** action (`photo.badge.arrow.down`) for the same
   platforms. Progress + result show in a **non-blocking bottom pill**
   (`MediaDownloadStatusView`, `isUserInteractionEnabled=false`) — the list stays
   tappable and the pill is a subview of the list so it never appears over the reader.
   The explicit action remains Photos-oriented. On Downloader it uses the already-local
   `SavedMediaStore` file and copies that file to PhotoKit; it does not re-download.
   Downloader's local file persistence is automatic on save and is not exposed as a
   separate "save locally" command.
4. **Downloader App Clip** — `LunaDownloaderClip` launches from a web URL whose query
   carries the source media URL (`url`, `source`, `sourceURL`, or `u`). It uses
   `MediaDownloadService.downloadFirstMediaToFile(from:onProgress:)`, so it never
   requests Photos access or calls PhotoKit. The clip shows a simple foreground progress
   screen and, once the file is ready, immediately presents `UIActivityViewController`
   with the downloaded file URL so the user can save or send it through system services.
   If automatic presentation is interrupted, the completion screen exposes a share button
   backed by the same activity controller.

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
  - `FacebookMediaParser` — the resolver fetches the **full page with a browser UA
    FIRST** and parses the real playable video URL out of the inline JSON
    (`browser_native_hd_url` / `playable_url_quality_hd` / `hd_src` first, then the SD
    variants; `unescape` fixes `\/`,`&`,`&amp;`), then og:video, then the og:image
    poster. Same fix as Instagram: a reel's crawler `og:` tags expose ONLY the poster
    still behind a login wall, so the OLD og-first `resolveFacebook` saved a static image
    from every video reel. If the browser-UA page yields nothing it falls back to the
    `facebookexternalhit/1.1` og-unfurl (video, then poster image).
  - Requests use a desktop Safari UA (`MediaDownloadHTTP.browserUserAgent`).
- **`SavedMediaStore.swift`** — app-group backed durable saved-media manifest
  (`savedMedia.json`) plus local files/thumbnails under `SavedMedia/Files` and
  `SavedMedia/Thumbnails`. `MediaRetentionSettings` defaults to 7 days, clamps to 1-30
  days, or disables expiry when set to nil. Purging (`purgeExpired`) runs on app launch and
  foreground and is **age-based only** — saved media is app-owned (the grid's content,
  deleted explicitly from the grid or aged out), NOT tied to reading-list membership.
  (An earlier orphan rule that deleted any item whose `sourceURLString` wasn't in the
  reading list silently wiped freshly-saved media once the ingest funnel unwrapped/
  normalized the URL, since the stored copy keeps the pre-unwrap source URL.)
- **`MediaDownloadService.swift`** — `downloadFirstMediaToPhotos(from:onProgress:)`:
  guards `supports`, requests add-only auth FIRST, resolves, downloads the first asset,
  saves. `downloadFirstMediaToAppStorage(from:title:onProgress:)` resolves/downloads and
  moves the file into `SavedMediaStore` without Photos permission. The split path for the
  action-extension inline preview is
  `downloadFirstMediaToFile(from:onProgress:)` (resolves + downloads to a temp file, **no**
  Photos prompt → returns `DownloadedMedia { fileURL, kind }`) and
  `saveDownloadedMediaToPhotos(_:)` (requests auth, then saves). `MediaFileDownloader`
  (URLSessionDownloadDelegate) streams to a temp file with progress and picks the extension
  by kind + MIME (`fileExtension`). TikTok downloads set a `https://www.tiktok.com/` Referer.
- **`PhotoLibrarySaver.swift`** — `.addOnly` authorization; `PHAssetCreationRequest`
  `addResource(with: .video/.photo, fileURL:, options.shouldMoveFile=true)`.

## Auto-download and retention settings

`Settings → Auto-Download Media` (`AutoDownloadSettingsScreen`) has two sections, both
stored in the App Group (`group.com.hsanabria.luna`, readable by app + extensions):

1. **Saved Media retention** (`MediaRetentionSettings`) — default 7 days, configurable
   from 1-30 days, or **Keep Until Deleted** to disable automatic deletion.
2. **Master "Auto-download media"** toggle (`autoDownloadMediaInPreview`, **default ON**)
   — controls whether the action extension's inline preview auto-downloads on appear vs
   starts pending with a manual button. No Photos prompt (downloading inline doesn't touch
   Photos).

`MediaAutoDownloader.runIfEnabled(forURLString:)` is called from the ingest funnel
(`ReadingListIngestor.ingestPlatformItem`). Downloader bundles always return enabled for
supported platforms and persist to `SavedMediaStore`; sibling apps still honor legacy
per-platform defaults if those keys exist. The download is **awaited** in the ingest
funnel (`runIfEnabledAwaiting`), so an app intent finishes the download before returning.
A bounded dedup list (`AutoDownloadSettings.markDownloaded`/`wasDownloaded`) means a post
downloaded in one process isn't downloaded again when the main app re-ingests it.

## Permissions

`NSPhotoLibraryAddUsageDescription` is in both `Luna/Info.plist` and
`Luna Action Extension/Info.plist`.

## Caveats (best-effort, like the web tools)

Keyless extraction depends on third-party/undocumented endpoints that change and may be
rate-limited or login-walled: Instagram video relies on the embed `contextJSON` (verified
working for reels); if Instagram drops it the fallbacks yield only the poster still.
TikTok `playAddr` can 403 without page cookies. The parsers are tested; live extraction
is not guaranteed end-to-end. Twitter "GIFs" are mp4 and save as videos.

## Tests

`LunaTests/MediaDownloadTests.swift` — platform support, X/TikTok/Instagram parsers
(incl. fallbacks + unescape), `fileExtension` mapping, and resolver dispatch via an
injected fetch. Network is not hit.
