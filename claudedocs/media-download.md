# Social Media Download

Luna downloads the first still image, GIF, or video from supported X, Instagram,
TikTok, and Facebook posts. Resolution is keyless/client-side and therefore best effort.

## Downloader storage model

Every Downloader save has one durable `SavedMediaItem` row and exactly one visible
`StorageState`:

1. **`undownloaded`** — the URL is saved, but no media backing exists yet. The grid
   shows a dotted-outline download glyph on a grey square. Selecting it starts the
   download instead of opening the viewer.
2. **`localFile(fileName:)`** — the media file lives under the shared App Group at
   `SavedMedia/Files`; an optional generated thumbnail lives in `SavedMedia/Thumbnails`.
3. **`photosReference(localIdentifier:…)`** — the manifest keeps PhotoKit's durable
   `PHAsset.localIdentifier`, not a duplicate media file. Grid thumbnails, image data,
   videos, sharing, and clipboard exports resolve the asset through PhotoKit each time.
   A small multicolor Photos rosette appears in the grid's top-right corner and in the
   fullscreen viewer so this backing is visible at a glance.

`SavedMediaStore.ensureUndownloaded` creates the manifest row before transfer and uses
the reading-list UUID as its stable identity. Existing manifests with the old required
`fileName` field decode as `.localFile`, so migration does not lose downloads. If a local
file disappears, store recovery changes the row back to `.undownloaded`.

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

1. atomically commit `.photosReference` together with the old local file/thumbnail names
   as pending deletion;
2. delete those files durably, then atomically clear the pending names.

`SavedMediaStore.items()` finishes interrupted pending deletions on the next load. Thus a
confirmed Photos save never reverts to local merely because the process stopped between
the manifest commit and file cleanup.

### Photos deletion and authorization

The grid reconciles Photos references when `.readWrite` authorization is available.
If `PHAsset.fetchAssets(withLocalIdentifiers:)` no longer finds an asset, Luna deletes the
Downloader item and clears its download-dedup marker, so saving the URL again can download
it again. Reconciliation is skipped for denied/restricted access and for `.limited`
access, where a nil fetch can mean "not selected" rather than deleted. Limited access can
still display selected assets, but Luna only interprets absence as deletion with full
`.authorized` read/write access.

Deleting a Photos-backed item from either the Downloader grid or fullscreen viewer first
deletes the referenced `PHAsset` through `PHPhotoLibrary`, then removes the Downloader and
reading-list records. If Photos access is denied, or limited access cannot resolve the
asset, the Luna records are retained until the user grants sufficient access. A Photos
asset that was already deleted is treated as an idempotent successful deletion.

Local retention (default seven days, configurable 1–30 days or disabled) applies only to
`.localFile` rows. Expiry deletes local files and returns the row to `.undownloaded`;
Photos references remain governed by the user's Photos library.

## Entry points and UI

- **Main Downloader grid** — `SavedMediaGridViewController` displays all three states in
  chronological order. Downloaded local and Photos items open
  `SavedMediaViewerViewController`; undownloaded items start a transfer. Local rows offer
  **Save to Photos**; Photos-backed rows do not offer a redundant save action.
- **Viewer** — local images/videos open from their App Group file. Photos-backed images
  load with PhotoKit image-data APIs and Photos-backed videos load through
  `PHImageManager.requestAVAsset`. Paging, deletion, autoplay/pause, and the zoom
  transition remain common to both backings.
- **Share and action extensions** — `SavedNonTextualViewController` retains its inline
  preview state machine (`pending`, `downloading`, `ready`, `failed`). The separate
  `autoDownloadMediaInPreview` setting, also default on, decides whether preview download
  starts automatically. Once ready, Downloader persists through the same destination
  policy above; sibling apps retain their legacy Photos behavior.
- **Ingest, App Intents, and short-lived extensions** —
  `ReadingListIngestor.ingestPlatformItem` calls `MediaAutoDownloader`; short-lived
  processes hand work to `LiveMediaDownloadManager` so system background transfer and the
  Live Activity survive process suspension.
- **Legacy reading-list long press** — manual Save to Photos remains available in the
  combined/debug list and uses the same confirmed local-to-Photos transition for
  Downloader rows.
- **Downloader App Clip** — downloads to a temporary file and presents the system share
  sheet. It does not become part of the durable three-state store or request Photos
  directly.

The grid and viewer observe both `.savedMediaChanged` and `.readingListChanged`.
`SavedMediaStore` also posts an App-Group-specific Darwin notification for mutations made
in another process; the grid bridges it back to `.savedMediaChanged` and reloads on app
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

Downloader's `Settings → Auto-Download Media` screen has three groups:

1. **Local Files** — retention days and Keep Until Deleted.
2. **After Downloading** — **Auto-Save to Photos** (default on) and **Copy Downloads to
   Clipboard** (default off).
3. **Auto-download media** — whether the extension preview starts downloading
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
