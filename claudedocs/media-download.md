# Social Media Download

Luna downloads the first still image, GIF, or video from supported X, Instagram,
TikTok, Facebook, Reddit, and YouTube links. It also downloads directly hosted
image, GIF, video, and audio file URLs without a platform-resolution request.
Platform resolution is keyless/client-side and therefore best effort.

`DirectMediaURL` recognizes common image (`jpg/jpeg/png/webp/heic/heif/avif`),
GIF, video (`mp4/m4v/mov`), and audio
(`mp3/m4a/aac/wav/caf/aif/aiff/flac`) path extensions. Query strings and
fragments do not interfere, so signed CDN URLs such as `clip.mp4?token=…` work.
`MediaAsset.direct(url:)` maps that shared classification into the download
model. Foreground downloads return it immediately from `SocialMediaResolver`;
durable background jobs skip the resolve transfer entirely and start the media
transfer with the original URL.

## Downloader storage model

Every Downloader save has one durable `SavedMediaItem` row and exactly one visible
`StorageState`:

1. **`undownloaded`** — the URL is saved, but no media backing exists yet. The
   carousel card shows a dotted-outline download glyph. While a job runs it becomes
   a downloading card with an explicit **Downloading** status, moon-horizon progress
   bar, and a static poster as soon as the resolver exposes one. Tapping the glyph
   starts the download.
2. **`localFile(fileName:)`** — the media file lives under the shared App Group at
   `SavedMedia/Files`; an optional generated thumbnail lives in `SavedMedia/Thumbnails`.
3. **`photosReference(localIdentifier:…)`** — the manifest keeps PhotoKit's durable
   `PHAsset.localIdentifier`, not a duplicate media file. Card content, scrub-strip
   thumbnails, and pasteboard exports resolve the asset through PhotoKit each
   time. A small multicolor Photos rosette appears in the card's top-leading corner
   so this backing is visible at a glance; tapping it opens that asset in Photos.

`archivedAt` removes a row from the main carousel and places it in the pull-out
archive tray without losing its source identity. Archiving a `.localFile` immediately
deletes the full media and changes the row to `.undownloaded`, while retaining the
small opportunistic thumbnail. A PhotoKit reference remains intact and playable;
transitions into Photos retain their generated thumbnail as the archive fallback.
Re-download completion preserves `archivedAt`, updates `dateSaved` to the download
date, and therefore uses the ordinary local-retention clock without unarchiving.

`SavedMediaStore.ensureUndownloaded` creates the manifest row before transfer and uses
the reading-list UUID as its stable identity. Existing manifests with the old required
`fileName` field decode as `.localFile`, so migration does not lose downloads. If a local
file disappears, store recovery changes the row back to `.undownloaded`.

Each row also carries best-effort `platform`/`platformItemID` (from
`PlatformRecognizer.recognize`, purely parsed from the URL — no network) and `creator`
(from the same platform metadata fetch that populates the reading-list item's title).
Every write path (`ensureUndownloaded`, `addDownloadedFile`) matches an incoming save
against existing rows by exact URL OR, failing that, by `platform` + `platformItemID`, so
a share-link token and its resolved permalink — or any other differently-shaped URL for
the same post — dedupe onto one row instead of creating a duplicate and re-downloading.
`SavedMediaStore.existingDownloadedItem(forURLString:)` uses the same matching to find a
row that's ALREADY `.localFile`/`.photosReference`, so callers can show it instead of
fetching again; `matchingItem(forURLString:)` does the same match regardless of storage
state. `SavedMediaItem.displayTitle` falls back title → creator → raw URL — the rule every
UI surface uses instead of ever showing the URL when metadata was fetched.

### Download destination

`AutoDownloadSettings.autoSaveDownloadsToPhotos` is App-Group backed and defaults to
**on**:

- On: a completed download is written to Photos and the returned durable identifier is
  committed as `.photosReference`.
- Off: the download is moved into App Group storage as `.localFile`.
- If automatic Photos authorization/save fails, Luna preserves the completed bytes as a
  local file rather than discarding the download.
- Direct audio is always preserved as a local file because PhotoKit does not
  accept standalone audio assets.

All Downloader completion paths use this policy: foreground ingest/App Intents
(`MediaDownloadService`), background URLSession/Live Activity
(`LiveMediaDownloadManager`), and the share/action-extension inline preview
(`SavedNonTextualViewController`). The bounded downloaded-URL list prevents those paths
from saving the same post twice.

### Local to Photos transition

Manual **Save to Photos** copies the local file to a PhotoKit staging URL. After PhotoKit
confirms the save and returns an identifier, `transitionToPhotosReference` performs a
crash-recoverable two-write transaction:

1. atomically commit `.photosReference` together with the old local file name
   as pending deletion (the small generated thumbnail is retained);
2. delete those files durably, then atomically clear the pending names.

`SavedMediaStore.items()` finishes interrupted pending deletions on the next load. Thus a
confirmed Photos save never reverts to local merely because the process stopped between
the manifest commit and file cleanup.

### Photos deletion and authorization

The root carousel reconciles Photos references when `.readWrite` authorization is
available.
If `PHAsset.fetchAssets(withLocalIdentifiers:)` no longer finds an active asset, Luna deletes the
Downloader item and clears its download-dedup marker, so saving the URL again can download
it again. An archived missing asset instead becomes `.undownloaded`, stays slightly dimmed
with a dotted-outline download icon, and re-downloads when tapped. Reconciliation is skipped for denied/restricted access and for `.limited`
access, where a nil fetch can mean "not selected" rather than deleted. Limited access can
still display selected assets, but Luna only interprets absence as deletion with full
`.authorized` read/write access.

Deleting a Photos-backed item from the card's long-press menu first
deletes the referenced `PHAsset` through `PHPhotoLibrary`, then removes the Downloader and
reading-list records. If Photos access is denied, or limited access cannot resolve the
asset, the Luna records are retained until the user grants sufficient access. A Photos
asset that was already deleted is treated as an idempotent successful deletion.

Local retention applies only to `.localFile` rows, and only when the user stores
downloads in Luna rather than Photos (the two are one exclusive **Storage** choice —
see Settings below). Expiry deletes local files and returns the row to `.undownloaded`;
Photos references remain governed by the user's Photos library.

## Entry points and UI

- **Main Downloader carousel** — `SavedMediaCardsViewController` (the root screen)
  displays all three states newest-first from left to right as full-content cards; there is no
  separate pushed viewer (see `claudedocs/card-carousel.md` for the carousel's
  interaction model). Local video and audio play from their App Group files;
  Photos-backed images
  load with PhotoKit image APIs and Photos-backed videos load through
  `PHImageManager.requestAVAsset`. Long-press menus offer **Save to Photos** on local
  rows (Photos-backed rows do not offer a redundant save action), Share, Archive, and Delete.
  The archive tray shows thumbnail-only square cells. Available local/PhotoKit media opens
  fullscreen; unavailable media re-downloads on tap; long-press offers Unarchive,
  Share, and Delete. Delete uses the same full cleanup as an active card: it removes
  the saved-media record and files, shared reading-list save, auto-download marker,
  and any referenced Photos asset.
  Settings and direct system file sharing flank the edge-to-edge scrub strip in glass
  circles; there is no root Friends or Add button. Sharing hands the activity controller
  exactly one concrete media file URL (no source link, text, or lazy provider), so it shows
  the media preview and supports normal file destinations. The current Photos-backed card
  is exported to a friendly-named temporary file in advance to minimize tap latency. A
  probable URL on the pasteboard appears as a transient leading paste-icon card
  without reading the value. Paging onto it performs the read and validates that
  Downloader owns the URL, then starts a moon-horizon download into a one-hour
  temporary file without creating a durable row. The completed media replaces the
  placeholder as a normal full card and scrubber thumbnail, but starts paused.
  Explicit Play (or tapping a still image) commits it to Luna and Photos; pasteboard
  changes and the one-hour deadline delete an uncommitted file.
- **Share and action extensions** — `SavedNonTextualViewController` retains its inline
  preview state machine (`pending`, `downloading`, `ready`, `alreadyDownloaded`, `failed`).
  Video/social links arrive through the same shared `IngestPipeline` outcomes and media
  resolver as every other ingestion context; YouTube has no extension-only embed or
  URL-derived poster path. Once resolved, media renders only in the extension preview
  area with the extension's Download, Share, Save to Photos, and Delete controls.
  Before deciding to auto-download or wait for a tap, it checks
  `SavedMediaStore.existingDownloadedItem(forURLString:)`; a duplicate link renders
  directly from the existing local file or Photos asset (`alreadyDownloaded`) with no
  network fetch — Save-to-Photos stays enabled for a local-file duplicate (still copies it
  to Photos) and is disabled once the match is already Photos-backed. The button remains
  disabled with a green checkmark after either an automatic or manual Photos save. The
  download and progress rows retain fixed layout slots while their contents change, so
  completion does not pull the Share/Save controls upward. **Delete and exit** removes a
  Photos asset first when one backs the item, then removes the Downloader and reading-list
  records; a Photos permission failure retains the Luna records. The separate
  `autoDownloadMediaInPreview` setting, also default on, decides whether a genuinely new
  link starts downloading automatically. Once ready, Downloader persists through the same
  destination policy above; sibling apps retain their legacy Photos behavior.
- **Ingest, App Intents, and short-lived extensions** — normal ingestion calls
  `MediaAutoDownloader`, while `.appIntent` ingestion deliberately skips the awaited inline
  downloader and any automatic Downloader-host Live Activity; the Save/Provide Context intent
  owns the single handoff after the reading-list result is known. Returning media to Shortcuts
  (`AppIntentSettings.returnsMediaToShortcuts`, App-Group-backed, default on — the inverse of the
  **Download in Background** row under Settings → Shortcut & Safari) first resolves
  the asset and its advertised/HEAD content length. Known files up to **100 MiB** run through the
  Live Activity/background URLSession engine and are awaited so the intent can return an optional
  `IntentFile`. Larger or indeterminate files are handed to that engine and the intent returns
  immediately with no file. Existing local files are reused and Photos-backed rows are copied to
  a transient file. Turning **Download in Background** on always uses the immediate
  background handoff.
  **A handoff that downloads nothing is an ERROR, not a quiet nil.**
  `LiveMediaDownloadManager.startReportingResult` names why a start didn't happen
  (`LiveMediaDownloadStartResult`: `started` / `alreadyDownloaded` / `deferredUntilWiFi` /
  `notAuthorized` / `unsupported` / `failed(message:)`) — the plain `start(…) -> Bool`
  collapses all of those into one `false`, which is what let a Shortcut exit reporting
  success with an empty library. The awaited path likewise returns
  `MediaAutoDownloader.AwaitedIntentDownload` (`completed` / `handledWithoutFile` /
  `failed`). `MediaIntentHandoff` throws `downloadFailed`/`notAuthorized` for anything that
  isn't `isDownloadHandled`; already-downloaded and Wi-Fi-deferred remain legitimate
  no-file returns (see `app-intents.md`, "Error reporting").
  Intent exports use a sanitized item title or platform base name (for example
  `tiktok.mp4`) as the actual temporary URL filename and declare its concrete file type,
  rather than leaking the durable UUID-backed library filename to Shortcuts.
  When Downloader has ever launched, both modes carry Downloader ownership, create/maintain
  `SavedMediaStore` state, honor Downloader's shared Storage setting in every host, and fall back to shared local storage when Photos permission is denied. Reader and
  Price Tracker embed host-prefixed copies of the same Live Activity widget configuration.
  Downloader-owned dedup is based on the durable `SavedMediaStore` state: a stale
  `autoDownloadedURLs` marker never suppresses a missing or `.undownloaded` row, so an
  interrupted/crashed save is restartable by pasting the URL again. Store-change notifications
  and live job-progress notifications from async ingestion / URLSession delegates are marshalled
  onto the main queue before UIKit carousel/footer observers run. A launch pass compares every
  persisted resolving/downloading/waiting job with the background session's real tasks and recreates a
  missing transfer; pasting the same interrupted URL performs the same repair immediately. New
  jobs register their background task before notifying UI, so a termination cannot leave a
  durable forever-resolving job in the old persist-before-task window.
- **Legacy reading-list long press** — manual Save to Photos remains available in the
  combined/debug list and uses the same confirmed local-to-Photos transition for
  Downloader rows.
- **Downloader App Clip** — downloads to a temporary file and presents the system share
  sheet. It does not become part of the durable three-state store or request Photos
  directly.

The carousel observes both `.savedMediaChanged` and `.readingListChanged`.
`SavedMediaStore` also posts an App-Group-specific Darwin notification for mutations made
in another process; the carousel bridges it back to `.savedMediaChanged` and reloads on app
activation because Darwin notifications may be dropped while suspended.

## Long downloads, interruption, and storage

`LiveMediaDownloadManager` uses a shared-container background `URLSession` with launch
events, connectivity waiting, and a seven-day resource timeout. Jobs persist expected and
received byte counts, resolver stage, source range, and a sidecar resume-data file. A user
pause asks `URLSessionDownloadTask` to produce resume data; transient network failures retry
once and then remain in the visible **Waiting to resume** state instead of being discarded.
Launch/foreground repair and Downloader's twice-daily BG processing job compare persisted jobs
with the background session and restart every missing resolving, downloading, or waiting task.
The local saving/YouTube-range-export stage is persisted too: the untouched transfer stays in a
`.source` staging file until the final output exists, so overnight repair can finish an export
without applying a range twice.

Every foreground and background path checks
`volumeAvailableCapacityForImportantUsage` before starting or resuming. The required capacity
includes the expected file, a 256 MiB reserve, transfer overhead, and a second full-file allowance
when a timestamp range requires local video export. Unknown sizes require the reserve. Failure is
shown in the card/Live Activity (and thrown as an App Intent dialog) with a user-facing amount to
free. The corresponding `E174.1` disk-space required-reason declaration lives in the
`LunaMediaDownload` privacy manifest.

## YouTube

`PlatformRecognizer` accepts concrete video URLs on `youtube.com` and all subdomains (including
`m.youtube.com`), `youtube-nocookie.com`, and `youtu.be`: watch URLs, Shorts, live, embed, `/v/`,
and `/clip/`. `YouTubeLink` normalizes these to a canonical video id and preserves `t`, `start`,
`end`, and `#t=` values (plain seconds or `1h2m3s`). Clip pages expand their underlying video id
and millisecond range. The downloaded progressive MP4 is trimmed locally for a requested start/end
range before it is committed.

YouTube's mobile-web player currently exposes a progressive MP4 whose Google Video request returns
HTTP 403 without a GVS Proof-of-Origin token. Luna therefore follows the current keyless/no-token
fallback used by [`yt-dlp`](https://github.com/yt-dlp/yt-dlp): it opens the watch page to establish
the guest `VISITOR`/`YSC` session, reads `VISITOR_DATA` and the active player-JavaScript URL, extracts
the numeric `signatureTimestamp` from that JavaScript, and sends a guest-bound `ANDROID_VR` 1.65.10
Innertube player request. That response contains a direct progressive MP4 with both H.264 video and
AAC audio for ordinary public videos. The exact client identity and version intentionally match
the maintained [yt-dlp YouTube client
configuration](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_base.py);
newer Android VR versions can return SABR-only media.

The foreground resolver and durable background resolver use the same sequence. The background job
persists guest visitor data and each resolver stage, while its named URLSession uses the shared
cookie jar so a relaunch or overnight repair can continue the bound session. It still selects only
progressive MP4 formats containing audio—never an adaptive video-only stream. Posters come from
`i.ytimg.com` immediately, and an expired signed CDN URL (HTTP 403 after a later resume) restarts the
source handshake rather than retrying stale bytes.

This deliberately does not embed `yt-dlp`, execute or decipher player JavaScript, supply external
PO tokens, or bypass login/DRM/age/region/private-video controls. The JavaScript fetch is data-only
and reads the published five-digit signature timestamp. Videos whose available formats still
require a player challenge or [PO token](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide)
fail explicitly when no public progressive stream is present. YouTube's developer policies also
restrict downloading/offline playback without authorization; shipping this feature requires a
separate product/legal review.

## Pasteboard providers

`MediaItemProviderFactory` and `MediaPasteboard` build a lazy, file-backed
`NSItemProvider` for either storage state: local state uses
`NSItemProvider(contentsOf: fileURL)`; Photos state registers a file representation which
resolves the durable asset ID and streams the selected `PHAssetResource` to a temporary
file on demand. Luna never assigns video `Data` to the pasteboard, so copying does not
eagerly materialize a large movie in memory. (The automatic
"copy every completed download" setting these backed was removed; the providers remain
the way to put media on the pasteboard.)

## Settings

Downloader's `Settings → Downloads` screen has two picker rows:

1. **Download Automatically** — **Never**, **Always** (the default), or **On Wi-Fi Only**.
   `AutoDownloadSettings.policy` reads and writes the two prefs behind it
   (`autoDownloadMediaInPreview` + `wifiOnlyDownloads`): Never means nothing downloads on
   its own, and the two on-values differ only in whether a download that starts on cellular
   waits for Wi-Fi. Manual per-item downloads always start immediately.
2. **Storage** — **Save to Photos** (the default) or **Delete after 1 day / 3 days /
   2 weeks / 1 month**. `MediaStorageSettings.option` maps this one choice onto
   `autoSaveDownloadsToPhotos` + `MediaRetentionSettings.option`, which makes the two
   mutually exclusive: choosing Photos clears the deletion clock, choosing an age turns
   Photos off. An installation that had Photos off with no retention choice reads as the
   default age (1 month); a since-removed age (2 days, 1 week) maps to the closest
   surviving one.

**Download in Background** (whether the Action Button intents wait for the download and
hand the file back to Shortcuts) lives under `Settings → Shortcut & Safari`, and only on
the media-handling surfaces.

All values live in the App Group so the app, App Intents, share/action extensions, and
background completion code make the same decision. Reader/Price Tracker continue to show
their legacy per-platform Photos auto-save controls.

## Core implementation

- `MediaDownload.swift` defines `MediaAsset`, supported platforms, errors, and the
  resolver/downloader/Photo-library protocols.
- `SocialMediaResolver.swift` dispatches to pure parsers for X, Instagram, TikTok, and
  Facebook. X uses fxtwitter JSON; TikTok parses hydration/reflow JSON; Instagram prefers
  embed `contextJSON`; Facebook prefers playable URLs in browser-page JSON. Facebook share
  tracking is removed before every resolution stage (`v` is retained for `/watch/` identity),
  because tracked and stable permalinks can receive different logged-out response shapes.
  Its final crawler response is parsed for both inline `browser_native_*_url` JSON and Open
  Graph video rather than assuming crawler pages contain `og:video`. TikTok media requests
  set its required Referer.
- `YouTubeMediaResolver.swift` normalizes the YouTube URL family, expands clips, establishes the
  guest watch-page session, performs the Android VR player handshake, parses player responses, and
  selects direct progressive MP4 media.
- `MediaDownloadPreflight.swift` owns size, 100 MiB intent, and storage-reserve policy;
  `MediaVideoTrimmer.swift` applies source-requested video ranges.
- `MediaDownloadService.swift` resolves and streams remote media to a temporary file,
  then applies Downloader's destination policy. Downloads never hold a full
  video in memory.
- `LiveMediaDownloadManager.swift` implements the equivalent background-transfer path.
  Its Facebook resolver follows the extension resolver's plugin-embed-first sequence,
  then falls back through the desktop page, mobile page, any canonical video page, and the
  crawler page;
  this is important because logged-out `/reel/` pages commonly return HTTP 400 to the
  desktop request. Facebook resolver requests bypass cookies and cached responses so a
  prior consent/login wall cannot mask a public reel. The mobile and crawler fallbacks accept
  video metadata regardless of attribute order or whether Facebook uses inline JSON,
  `property`, or `name`.
- `SavedMediaStore.swift` owns `savedMedia.json`, the three-state model, legacy decoding,
  local files/thumbnails, retention, and crash recovery.
- `PhotoLibrarySaver.swift` requests authorization, creates `.photo`/`.video` resources
  with `shouldMoveFile`, returns `placeholderForCreatedAsset.localIdentifier`, fetches by
  identifier, and streams original resources with iCloud network access allowed.
- `MediaItemProvider.swift` builds lazy file-backed providers for local and Photos media
  and contains the main-actor pasteboard helper.

## Permissions

Both add and read access are required: add access creates the asset; `.readWrite` access
lets Downloader resolve its durable identifier later. `NSPhotoLibraryAddUsageDescription`
and `NSPhotoLibraryUsageDescription` are present in the shared app, action-extension, and
share-extension Info plists. The share plist needs both because downloadable media opens
`SavedNonTextualViewController` on both extension surfaces.

## Caveats and tests

Undocumented media endpoints can change, rate-limit, or return only a poster. Twitter
“GIFs” are MP4 videos; TikTok CDN URLs may reject requests without expected cookies;
YouTube may require a PO token/player challenge and expose no usable progressive stream.
The exact user-reported Shorts and `youtu.be` links have opt-in live coverage in
`SocialMediaResolverTests`: `RUN_LIVE_YOUTUBE_TESTS=1` validates full foreground transfers and
audio/video tracks, while `RUN_LIVE_YOUTUBE_BACKGROUND_TESTS=1` validates the named background
session through durable Downloader storage. Keep both gated because they access live YouTube.

Parser and extension mapping are covered by `SocialMediaResolverTests`; three-state
storage, migration, settings defaults, retention, and transition recovery are covered by
the SavedMedia/AutoDownload tests. Real PhotoKit library mutation still requires
device/simulator integration testing.
