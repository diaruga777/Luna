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
   a downloading card: a static poster as soon as the resolver exposes one, dimmed
   behind an **embedded glass status bar** inside the card's own bottom edge that
   carries the job's status line, a percentage while bytes are moving, and the
   moon-horizon progress bar. Tapping the glyph starts the download. See
   "In-app progress" below for why nothing floats.
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

Safari's in-page player is a direct-resolved exception to the ordinary ingest
funnel, but not to this invariant: its queue drain calls `ensureUndownloaded`
before creating the job, then awaits preflight until the named background task is
registered before returning the foreground to Safari. A completed transfer can
therefore never arrive without a manifest row to receive it, and suspension cannot
catch the handoff in the persist-before-task gap.

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
**off**:

- On: a completed download is written to Photos and the returned durable identifier is
  committed as `.photosReference`.
- Off: the download is moved into App Group storage as `.localFile`; this is the
  shipped default, so a fresh install never asks for Photos access.
- The util card offers the choice inline until someone answers it and asks for
  Photos access before saving a Photos answer (`claudedocs/util-card.md`,
  "Where downloads are stored").
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

The carousel is not the only place that has to notice. **Every save path re-checks
the backing before it treats a duplicate URL as already downloaded**, so a process
with no deck — an App Intent, a share/action extension, a Shortcut run — behaves
like the app that reconciles on foreground. `SavedMediaStore` owns the check at the
two questions the save paths actually ask:

- `existingDownloadedItem(forURLString:)` — the "don't re-fetch, hand back what we
  have" query (the intent media handoff, the awaited-transfer poll, the extension's
  saved-media screen). A Photos row whose asset is gone answers nil.
- `ensureUndownloaded(…)` — the row-ensure every download makes before starting, so
  `LiveMediaDownloadStartPolicy.downloaderShouldStart` sees work to do instead of
  rejecting the start as `.alreadyDownloaded`.

Both route through `discardSaveWithDeletedPhotosBacking(_:)`, whose outcome is the
same as the carousel's: an active row is **deleted** (the incoming save then makes
a new one, via the very `ensureUndownloaded` above) and an archived row instead
becomes `.undownloaded` with its poster retained. The legacy `AutoDownloadSettings`
dedup marker — the other "already downloaded" gate — is cleared with it. The one
thing the save path does NOT mirror is the carousel's reading-list deletion: the
save being processed right now owns that row, so it stays.

The verdict comes from `PhotosBackingProbing`; the real `PhotoKitBackingProbe`
NEVER prompts, and reports `.indeterminate` without full `.authorized` read/write
access, so an unauthorized extension leaves the row untouched rather than
guessing. Local-file rows never consult PhotoKit at all.

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
  A PAUSED video or audio card shows its playback controls — the position bar
  under the card and a glass speed pill (0.25×–2×) at the card's bottom-left,
  remembered per row for the run of the app, shared with the fullscreen system
  player's own speed menu (`claudedocs/card-carousel.md`).
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
  area, which is a SQUARE filled aspect-fit: its side follows the content column, not
  the still's proportions, so the media's vertical centre — and the Photos button
  anchored under it — is fixed from load.
  Before deciding to auto-download or wait for a tap, it checks
  `SavedMediaStore.existingDownloadedItem(forURLString:)`; a duplicate link renders
  directly from the existing local file or Photos asset (`alreadyDownloaded`) with no
  network fetch — Save-to-Photos stays enabled for a local-file duplicate (still copies it
  to Photos) and is disabled once the match is already Photos-backed. The button keeps the
  Photos pinwheel (`PhotosAppGlyph`, drawn — a sandboxed app can't read another app's icon)
  set inline before the word "Photos" in BOTH states, and reads "Saved to Photos", disabled,
  after either an automatic or manual Photos save. Download progress is drawn INSIDE the
  media placeholder (`MoonHorizonProgressBar` under the media icon) rather than in a row of
  its own, and there is no separate spinner — one indicator for one wait. **Download and
  Save to Photos are one fixed-height slot** directly under the preview, in two states —
  the media either isn't on disk yet or is, never both — so nothing moves when the
  download completes, and the status line under it stays put. Save to Photos is inset one
  further standard margin on each side than the full-width controls, so it reads as the
  media's own action.
  Its chrome is the extensions' shared chrome: a
  `GlassConfirmationBadge` header ("Saved to Luna" — the screen used to carry a navigation
  title hard-coded to "Luna Downloader" in all four apps) and Liquid Glass action pills in
  the host app's own tint (`GlassStyle.actionButtonConfiguration(tint:)`). **The ways out
  stack up from the bottom safe area** instead: a full-width **Done** carrying the app's
  tint as a real glass fill (`GlassStyle.primaryActionButtonConfiguration`, iOS 26
  prominent glass — plain glass tinted at 55% is indistinguishable from the quiet pills
  over true black), **Delete** directly above it, and — in the ACTION extension only, whose
  user did not arrive from a share sheet — the system-share affordance as a floating glass
  circle above that (`ExtensionFloatingGlassButton`, the same object as
  `ExtensionExitButton`, which every other extension surface still uses bottom-right) —
  pinned to the trailing edge the two pills end at, not centred over them.
  Because the stack is bottom-anchored, an absent Share circle is not a gap.
  Leaving completes SILENTLY — the host's "Saved" checkmark card used to animate in over a
  screen the user had just dismissed, re-stating the header it replaced. **Delete** removes a
  Photos asset first when one backs the item, then removes the Downloader and reading-list
  records; a Photos permission failure retains the Luna records. The separate
  `autoDownloadMediaInPreview` setting, also default on, decides whether a genuinely new
  link starts downloading automatically. Once ready, Downloader persists through the same
  destination policy above; sibling apps retain their legacy Photos behavior.
- **Ingest, App Intents, and short-lived extensions** — normal ingestion calls
  `MediaAutoDownloader`, while `.appIntent` ingestion deliberately skips the awaited inline
  downloader and any automatic Downloader-host Live Activity. Provide Context resolves
  the asset and its advertised/HEAD content length, checks storage, and returns a
  versioned opaque checkpoint; Save owns the only actual transfer. Known files up to **100 MiB** run through the
  Live Activity/background URLSession engine and are awaited so the intent can return an optional
  `IntentFile`. Larger or indeterminate files are handed to that engine and the intent returns
  immediately with no file. Existing local files are reused and Photos-backed rows are copied to
  a transient file. There is no user switch for this size policy.
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
  **Who shows progress:** SaveIntent compiles the guarded long-running runtime in
  every app, while only Downloader + central Luna install the media handoff and
  can start a transfer. Save conforms to `LiveActivityIntent`, which is
  what lets `Activity.request` succeed from a background Action Button run at all — before
  that it threw and the transfer ran invisibly. On iOS 27 builds compiled with Xcode 27 the
  Save also runs under `LongRunningIntent`, whose own system progress UI covers the
  AWAITED leg; `LiveMediaDownloadManager.systemProvidesProgressUI` (a task local bound by
  `MediaIntentHandoff`) suppresses Luna's activity for exactly that leg so the two don't
  stack. The background leg always keeps Luna's activity — the system's ends when the
  intent returns. Note also that `isDiscretionary` is IGNORED for a transfer started while
  the app is in the background ("the system assumes this property is `true`"), so an
  intent-started download may sit queued until the system finds a good moment; "started"
  is not "downloading now".
  Intent exports use a sanitized item title or platform base name (for example
  `tiktok.mp4`) as the actual temporary URL filename and declare its concrete file type,
  rather than leaking the durable UUID-backed library filename to Shortcuts.
  When Downloader has ever launched, both modes carry Downloader ownership, create/maintain
  `SavedMediaStore` state, honor Downloader's shared Storage setting in every host, and fall back to shared local storage when Photos permission is denied. **Only the
  media-handling hosts embed the Live Activity widget** — `LunaLiveActivity` (central
  Luna) and `LunaDownloaderLiveActivity` (Downloader) build host-prefixed copies of the
  same configuration out of `LunaDownloaderLiveActivity/`. Reader and Price Tracker used
  to embed copies too, but the four-app compile-time split left them without
  `LunaMediaDownload` in the app, the share/action/Safari extensions, or the App Clip,
  and `MediaIntentHandoff.install()` runs only from `KindWiring+Luna.swift` /
  `KindWiring+Downloader.swift`. An ActivityKit activity is owned by the process that
  requests it and rendered only by a widget extension embedded in that same app, so
  those two copies could never be reached; both targets were removed.
  Downloader-owned dedup is based on the durable `SavedMediaStore` state: a stale
  `autoDownloadedURLs` marker never suppresses a missing or `.undownloaded` row, so an
  interrupted/crashed save is restartable by pasting the URL again. Store-change notifications
  and live job-progress notifications from async ingestion / URLSession delegates are marshalled
  onto the main queue before UIKit card/tray observers run. A launch pass compares every
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

## Bounce back to Safari, and tap-to-view on the Live Activity

A media pill save (`&ret=safari` on the deep link, `claudedocs/safari-extension.md`)
reopens the original https page in Safari once the download has actually started:
`PlatformItemIngestor.ingest` is awaited all the way through
`LiveMediaDownloadManager.shared.start` (which requests the Live Activity) before
`SceneDelegate`'s save-press `Task` returns, so by the time
`SafariReturnPolicy.shouldReturn` decides to bounce (`UIApplication.shared.open` on
the original URL, never a private scheme), the transfer is already running in the
background `URLSession` and the activity is already visible — bouncing away doesn't
race either. The transfer and the activity's lifecycle are otherwise unaffected by
whether the app is foreground, backgrounded, or suspended: a background-session
delegate callback wakes the process briefly to advance the job regardless.

The activity is tappable everywhere it renders (`.widgetURL` on the lock-screen view
AND the Dynamic Island's expanded center region, `LunaDownloaderLiveActivityWidget
.swift`), for every phase including `.finished`: `<ownScheme>://media?url=<encoded
sourceURLString>`. The URL string is a prebuilt `ContentState.viewURLString` field
(`LiveMediaDownloadManager.activityState(for:)` sets it — that file already imports
`LunaDeepLink`, while the widget target links only `LunaMediaDownload` +
`LunaDesignSystem`, mirroring how `actionURLString` is already populated for the
Photos-permission failure link) rather than a widget-side `LunaDeepLink` call.
`SceneDelegate.route`'s `media` host branch resolves it via
`KindWiring.mediaDeepLinkAction(forURLString:)` — one answer per app, since only
`Luna`/`LunaDownloader` link the media module (Reader/Price Tracker return `.none`,
never actually reachable there since neither ever runs the Live Activity):
`.localFile` centers the deck on that item and opens it (`ExternalItemOpening`,
which every deck root now provides via the base `CardCarouselHostViewController`);
`.photosReference` reuses the card's own "open in Photos" mechanism
(`MediaCardFactory.openInPhotos`, the `photos-redirect://` scheme — no new scheme was
invented); still-downloading or an unknown URL just lands on the deck, the same as
any other cold/foreground launch.

**The finished-state dismissal window is UNCHANGED** (`endActivity`'s 20s default) —
tap-to-view instead rides the alert `endActivity` already sends on its final
`.finished`/`.failed` update (title + body + sound, same shape as the download-started
alert), which re-presents the activity prominently regardless of foreground/background
state; the fix here was making sure that final alerting state carries the view URL, not
lengthening how long the card lingers.

## In-app progress: embedded, never floating

In-app download progress is drawn **on the item that is downloading**, not in
app-level chrome. There is no floating download bar; the former
`DownloaderProgressFooterView` — a glass slab pinned above the scrub strip that
adopted whichever job started first — is deleted.

- An **`.undownloaded` carousel card** carries its own progress: poster + dim +
  an embedded glass status bar inside the card's bottom edge (status line,
  percentage while `.downloading`, moon-horizon bar). Failure keeps the bar up
  with the reason in red, the retry glyph, and — for a `.noMedia` failure with a
  model available — "Try Apple Intelligence" (see `claudedocs/url-rescue.md`).
- An **archived row re-downloading in place** (tapping an unavailable archive
  cell) draws its bar on that cell. `ArchiveTrayController.setDownloadProgress`
  applies ticks to visible cells directly — a `reloadData` per tick would restart
  every visible cell's thumbnail load. While downloading, the cell drops the
  dotted glyph and the unavailable dimming, because it is active work rather than
  missing media.
- The **pasteboard preview card** keeps its own progress card, as before.

**Every one of these views is a pure observer.** They read
`.downloaderJobProgressChanged` (and `currentDownloadSnapshot(forSourceURLString:)`
on load) and never own the transfer, which lives in `LiveMediaDownloadManager`'s
shared-container background `URLSession`. So paging the card off screen, leaving
the Downloader screen, or backgrounding the app tears the view down without
touching the download; only the Live Activity's explicit pause
(`LiveMediaDownloadManager.suspend(jobID:)`, called solely from the widget's
intent) ever suspends one. A card recreated mid-transfer re-reads the snapshot and
picks the bar up where it is, and out-of-app progress remains the Live Activity's
job.

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

The AppDelegate background-session completion handler is not released merely
because delegate events finished arriving. `LiveMediaDownloadManager` counts the
async transition work those events started (next resolve/media task, trim, mux,
store commit, Activity update/end) and releases the handler only when that work
has either completed or installed its next system-owned task. Reddit follows the
same rule: its video, guessed audio, and DASH-manifest/audio fallback are sequential
roles in the named background session, with the companion URLs and completed video
staging file persisted in the job. No Reddit transfer leg uses `URLSession.shared`.

Every foreground and background path checks
`volumeAvailableCapacityForImportantUsage` before starting or resuming. The required capacity
includes the expected file, a 256 MiB reserve, transfer overhead, and a second full-file allowance
when a timestamp range requires local video export. Unknown sizes require the reserve. Failure is
shown in the card/Live Activity (and thrown as an App Intent dialog) with a user-facing amount to
free. The corresponding `E174.1` disk-space required-reason declaration lives in the
`LunaMediaDownload` privacy manifest.

## Instagram

`PlatformRecognizer` takes the shortcode out of any `(p|reel|reels|tv)/<code>`
path, including the username-prefixed form Instagram now shares
(`/<user>/reel/<code>/`). Resolution then runs a two-stage ladder, and the order
exists for one reason: **Instagram hands out a reel's cover frame freely and its
playable MP4 from exactly one endpoint.**

1. **The web client's persisted GraphQL query** — a GET to
   `/graphql/query/?doc_id=…&variables={"shortcode":…}` with the public
   `X-IG-App-ID` instagram.com's own JavaScript sends. `doc_id` names a query
   Instagram has already registered server-side, so there is no key and no login.
   This is today the only keyless source that still returns `video_url`. It is a
   GET rather than the POST the site itself issues because the durable background
   engine can only run plain download tasks (no request body) — and the endpoint
   answers this GET while 403-ing a bodyless POST.
2. **The embed page** (`/p/<code>/embed/captioned/`) — its `contextJSON` blob
   still carries stills and carousels, and any `video_url` it does hand back.

Both endpoints return the same `shortcode_media` node shape, down to
`edge_sidecar_to_children`; only `__typename` gains an `XDT` prefix on the GraphQL
one, which is why video detection matches that name's suffix. One node parser
serves both.

**A video node with no playable URL yields nothing, never its still.** Instagram's
embed payload now describes a reel as a video (`is_video`, `video_duration`,
`product_type: clips`) while omitting `video_url` entirely; reading that as "no
video here" and falling through to `display_url` is what made a saved reel come
back as a static image — the reel's own cover frame, stored as though it were the
reel. `InstagramPost.declaresVideo` carries the fact up so the ladder stops rather
than scraping an `og:image` poster from the post page. A reel Luna cannot fetch
stays a usable link; it never becomes a picture of itself. Photo posts and
carousels are unaffected — their stills *are* the media, and the `og:` stage
remains their last resort.

`doc_id`s rotate. When this one is retired the query returns no media rather than
wrong media, so the degradation is a reel that fails to download, not a reel that
downloads the wrong thing. The durable background engine mirrors the same two
stages (`instagramGraphQL` → `instagramEmbed`, via `startNextInstagramResolve`),
the way its Facebook and YouTube ladders mirror theirs; reordering one means
reordering both.

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

## Settings

Luna and Luna Downloader share the same `Settings → Downloads` screen with two picker rows:

1. **Download Automatically** — **Never**, **Always** (the default), or **On Wi-Fi Only**.
   `AutoDownloadSettings.policy` reads and writes the two prefs behind it
   (`autoDownloadMediaInPreview` + `wifiOnlyDownloads`): Never means nothing downloads on
   its own, and the two on-values differ only in whether a download that starts on cellular
   waits for Wi-Fi. Manual per-item downloads always start immediately.
2. **Storage** — **in Luna** (the default, with the inline 2-week retention) or
   **Save to Photos** / **Delete after 1 day / 3 days / 2 weeks / 1 month**.
   `MediaStorageSettings.option` maps this one choice onto
   `autoSaveDownloadsToPhotos` + `MediaRetentionSettings.option`, which makes the two
   mutually exclusive: choosing Photos clears the deletion clock, choosing an age turns
   Photos off. An installation that had Photos off with no retention choice reads as the
   default age (1 month); a since-removed age (2 days, 1 week) maps to the closest
   surviving one.

The screen writes through `MediaStorageSettings.choose`, not `option`, so the user's
answer is recorded as theirs (`hasExplicitChoice`). That marker is what the util
card's inline **“Store downloads in Luna / in Photos”** line waits on: Luna is the
default, and Photos needs a permission nobody has been asked for, so both downloading
apps offer the choice on the card until it is answered anywhere — and that row, unlike
this screen, asks for Photos access BEFORE it saves the setting
(`MediaUtilCardStorageChoice`, `claudedocs/util-card.md`).

All values live in the App Group so the app, App Intents, share/action extensions, and
background completion code make the same decision. Photos storage is global: every completed
download is saved to Photos or none are; there are no per-platform Photos toggles.

## Core implementation

- `MediaDownload.swift` defines `MediaAsset`, supported platforms, errors, and the
  resolver/downloader/Photo-library protocols.
- `SocialMediaResolver.swift` dispatches to pure parsers for X, Instagram, TikTok, and
  Facebook. X uses fxtwitter JSON; TikTok parses hydration/reflow JSON; Instagram prefers
  the persisted GraphQL query and never substitutes a still for a video (see the Instagram
  section above); Facebook prefers playable URLs in browser-page JSON. Facebook share
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
  Every app-owned transition around that path (initial resolution/preflight before a
  task exists, local processing between tasks, and final persistence after a task
  finishes) holds an iOS background-execution lease. The lease ends as soon as the
  next system-owned background `URLSession` task is registered or local work finishes;
  the transfer itself never depends on foreground execution. Safari's resolved-media
  handoff therefore returns after the library row, recoverable job, and Live Activity
  exist, without waiting for the optional size probe. If the process is later killed
  in that small pre-task window, launch repair recreates the transfer from the asset
  URLs persisted in the job. **The lease is inert in an `.appex`** — the share and
  action extensions reach the same start path
  (`ShareViewController.autoDownloadThenComplete` →
  `MediaAutoDownloader.startLiveActivityIfEnabled`), `UIApplication.shared` is nil
  there, and Swift's non-optional bridge traps on it; an extension has no app
  lifetime to extend anyway, since its host decides when it dies. It is also
  acquired asynchronously rather than with `DispatchQueue.main.sync`, because every
  caller is an `async` context on the cooperative pool.
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
