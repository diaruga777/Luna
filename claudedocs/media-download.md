# Social Media Download

Luna downloads the first still image, GIF, or video from supported X, Instagram,
TikTok, and Facebook posts. Resolution is keyless/client-side and therefore best effort.

## Downloader storage model

Every Downloader save has one durable `SavedMediaItem` row and exactly one visible
`StorageState`:

1. **`undownloaded`** — the URL is saved, but no media backing exists yet. The
   carousel card shows a dotted-outline download glyph (with a live progress ring
   while a job runs). Tapping the glyph starts the download.
2. **`localFile(fileName:)`** — the media file lives under the shared App Group at
   `SavedMedia/Files`; an optional generated thumbnail lives in `SavedMedia/Thumbnails`.
3. **`photosReference(localIdentifier:…)`** — the manifest keeps PhotoKit's durable
   `PHAsset.localIdentifier`, not a duplicate media file. Card content, scrub-strip
   thumbnails, sharing, and clipboard exports resolve the asset through PhotoKit each
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

Local retention (default **Never**, with choices of 1 day, 2 days, 1 week, 2 weeks, or
1 month) applies only to `.localFile` rows. Expiry deletes local files and returns the
row to `.undownloaded`; Photos references remain governed by the user's Photos library.

## Entry points and UI

- **Main Downloader carousel** — `SavedMediaCardsViewController` (the root screen)
  displays all three states in chronological order as full-content cards; there is no
  separate pushed viewer (see `claudedocs/card-carousel.md` for the carousel's
  interaction model). Local media plays from its App Group file; Photos-backed images
  load with PhotoKit image APIs and Photos-backed videos load through
  `PHImageManager.requestAVAsset`. Long-press menus offer **Save to Photos** on local
  rows (Photos-backed rows do not offer a redundant save action), Share, Archive, and Delete.
  The archive tray shows thumbnail-only square cells. Available local/PhotoKit media opens
  fullscreen; unavailable media re-downloads on tap; long-press offers Unarchive
  and Share.
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
  owns the single handoff after the reading-list result is known. **Return Downloaded Media**
  (`AutoDownloadSettings.returnMediaFromAppIntents`, App-Group-backed, default on) awaits the
  durable Downloader download and exposes the completed static image/GIF/video to Shortcuts as
  an optional `IntentFile` property on the returned transient entity. It reuses existing local
  files; Photos-backed rows are copied to a transient file for the result. Turning the setting
  off retains the former `LiveMediaDownloadManager` background job and returns no media file.
  Intent exports use a sanitized item title or platform base name (for example
  `tiktok.mp4`) as the actual temporary URL filename and declare its concrete file type,
  rather than leaking the durable UUID-backed library filename to Shortcuts.
  When Downloader has ever launched, both modes carry Downloader ownership, create/maintain
  `SavedMediaStore` state, honor Downloader's shared Photos and clipboard settings in every
  host, and fall back to shared local storage when Photos permission is denied. Reader and
  Price Tracker embed host-prefixed copies of the same Live Activity widget configuration.
  Downloader-owned dedup is based on the durable `SavedMediaStore` state: a stale
  `autoDownloadedURLs` marker never suppresses a missing or `.undownloaded` row, so an
  interrupted/crashed save is restartable by pasting the URL again. Store-change notifications
  and live job-progress notifications from async ingestion / URLSession delegates are marshalled
  onto the main queue before UIKit carousel/footer observers run. A launch pass compares every
  persisted resolving/downloading job with the background session's real tasks and recreates a
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

## Clipboard completion action

`AutoDownloadSettings.autoCopyDownloadsToClipboard` defaults to **off**. When enabled,
every successful Downloader completion places one `NSItemProvider` on
`UIPasteboard.general.itemProviders` after the final durable storage state is known:

- local state uses `NSItemProvider(contentsOf: fileURL)`;
- Photos state registers a lazy file representation which resolves the durable asset ID
  and streams the selected `PHAssetResource` to a temporary file on demand.

This includes videos. Luna never assigns video `Data` to the pasteboard, so copying does
not eagerly materialize a large movie in memory. `MediaItemProviderFactory` and
`MediaPasteboard` contain the common implementation.

## Settings

Downloader's `Settings → Auto-Download Media` screen has four groups:

1. **Local Files** — one **Delete After** picker: **Never** (the default), **After 1
   day**, **After 2 days**, **After 1 week**, **After 2 weeks**, or **After 1 month**.
2. **Network** — **Wi-Fi Only** (default off).
3. **After Downloading** — **Auto-Save to Photos** (default on) and **Copy Downloads to
   Clipboard** (default off).
4. **Auto-download media** — whether the extension preview starts downloading
   automatically (default on).

All values live in the App Group so the app, App Intents, share/action extensions, and
background completion code make the same decision. Reader/Price Tracker continue to show
their legacy per-platform Photos auto-save controls.

## Core implementation

- `MediaDownload.swift` defines `MediaAsset`, supported platforms, errors, and the
  resolver/downloader/Photo-library protocols.
- `SocialMediaResolver.swift` dispatches to pure parsers for X, Instagram, TikTok, and
  Facebook. X uses fxtwitter JSON; TikTok parses hydration/reflow JSON; Instagram prefers
  embed `contextJSON`; Facebook prefers playable URLs in browser-page JSON. Instagram and
  Facebook fall back to Open Graph media. TikTok media requests set its required Referer.
- `MediaDownloadService.swift` resolves and streams remote media to a temporary file,
  then applies Downloader destination and clipboard policy. Downloads never hold a full
  video in memory.
- `LiveMediaDownloadManager.swift` implements the equivalent background-transfer path.
  Its Facebook resolver follows the extension resolver's plugin-embed-first sequence,
  then falls back through the desktop page, mobile page, and any canonical video page;
  this is important because logged-out `/reel/` pages commonly return HTTP 400 to the
  desktop request. Facebook resolver requests bypass cookies and cached responses so a
  prior consent/login wall cannot mask a public reel; the mobile fallback accepts Open
  Graph video tags regardless of attribute order or whether Facebook uses `property` or
  `name`.
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
“GIFs” are MP4 videos; TikTok CDN URLs may reject requests without expected cookies.

Parser and extension mapping are covered by `SocialMediaResolverTests`; three-state
storage, migration, settings defaults, retention, and transition recovery are covered by
the SavedMedia/AutoDownload tests. End-to-end live extraction and real PhotoKit library
mutation still require device/simulator integration testing.
