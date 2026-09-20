# Social Media Video

Luna Video fetches the first still image, GIF, or video from supported X, Instagram,
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

## Video storage model

**The library is SQL.** `media_saves` is a child table of `saves` under `ON DELETE
CASCADE` — there is no `savedMedia.json`. The media file and its poster are `files`
rows owned by `file_refs`, so deleting the save takes the row, the row's edges, and
(through the release trigger and `PendingDeleteReaper`) the files. `SavedMediaStore`
unlinks nothing itself. Consequences worth knowing before touching this: one media
row per save (a replacement reuses the save's id); posters get generated
`thumb-<UUID>.jpg` names because a released path is retired forever; a download
reserves its save row up front via `MediaSaveBacking`; and the local→Photos
transition is a single write, because the delete queue is the durable intent the
old `pendingLocal*` pair used to provide. See `claudedocs/saves.md`.

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
3. **`photosReference(localIdentifier:…)`** — the row keeps PhotoKit's durable
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

`SavedMediaStore.ensureUndownloaded` creates the media row before transfer and uses
the saves list UUID as its stable identity. There is no runtime import or destructive
cleanup for the retired `savedMedia.json` format: pre-SQL/intermediate installs are
unsupported and the App Group is wiped before installing this build. In particular,
launch maintenance never empties `media_saves` or sweeps `SavedMedia/` as a migration.
If a current SQL row's local file disappears, ordinary store recovery changes that row
back to `.undownloaded`.

`MediaSaveBacking` parses `platform` + `platformItemID` before reserving that save.
The reservation matches the durable identity in both `saves` and `media_saves` under
one SQLite write lock, then uses normalized URL equality as a bounded fallback. A
short/wrapper spelling and its permalink therefore reuse the media row's owning
`save_id` instead of leaving a second pending save with no media behind it.
This layer does not follow network redirects: an opaque wrapper such as Reddit's
`/r/…/s/<token>` has no locally parseable post id, so the download start path must
continue to pass the canonical URL returned by its resolver. Until then, only exact
normalized-URL fallback is possible.

Safari's in-page player is a direct-resolved exception to the ordinary ingest
funnel, but not to this invariant: its queue drain calls `ensureUndownloaded`
before creating the job, then awaits preflight until the named background task is
registered before returning the foreground to Safari. A completed transfer can
therefore never arrive without a media row to receive it, and suspension cannot
catch the handoff in the persist-before-task gap. The save row it reserved
is finished the same way it would be in any other save — just later and in the
background, after the bounce: see "The save the hand-off did not have time to
finish" below.

Each row also carries best-effort `platform`/`platformItemID` (from
`PlatformRecognizer.recognize`, purely parsed from the URL — no network).
Every write path (`ensureUndownloaded`, `addDownloadedFile`) matches an incoming save
against existing rows by exact URL OR, failing that, by `platform` + `platformItemID`, so
a share-link token and its resolved permalink — or any other differently-shaped URL for
the same post — dedupe onto one row instead of creating a duplicate and re-downloading.
`SavedMediaStore.existingDownloadedItem(forURLString:)` uses the same matching to find a
row that's ALREADY `.localFile`/`.photosReference`, so callers can show it instead of
fetching again; `matchingItem(forURLString:)` does the same match regardless of storage
state. `SavedMediaItem.displayTitle` falls back title → raw URL — the rule every
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

All Luna Video completion paths use this policy: foreground ingest/App Intents
(`MediaDownloadService`), background URLSession (and, when enabled, Live Activity)
(`LiveMediaDownloadManager`), and the share/action-extension inline preview
(`SavedNonTextualViewController`). The bounded downloaded-URL list prevents those paths
from saving the same post twice.

### Local to Photos transition

Manual **Save to Photos** copies the local file to a PhotoKit staging URL. After PhotoKit
confirms the save and returns an identifier, `transitionToPhotosReference` performs one
SQLite transaction:

1. commit `.photosReference` while retaining the small generated thumbnail;
2. remove the old media-file ownership edge, whose trigger records the path in
   `pending_deletes`, in that same commit.

The reaper unlinks queued paths after the commit and retries after a process interruption.
Thus a confirmed Photos save cannot leave the row and its ownership edges disagreeing;
physical cleanup remains durable and idempotent.

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
thing the save path does NOT mirror is the carousel's save deletion: the
save being processed right now owns that row, so it stays.

The verdict comes from `PhotosBackingProbing`; the real `PhotoKitBackingProbe`
NEVER prompts, and reports `.indeterminate` without full `.authorized` read/write
access, so an unauthorized extension leaves the row untouched rather than
guessing. Local-file rows never consult PhotoKit at all.

Deleting a Photos-backed item from the card's long-press menu first
deletes the referenced `PHAsset` through `PHPhotoLibrary`, then removes the Downloader and
saves list records. If Photos access is denied, or limited access cannot resolve the
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
  the saved-media record and files, shared save, auto-download marker,
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
  If Save to Photos moves a video while its full-screen player is open, the player
  swaps to PhotoKit's asset at the same playback position; the screen also changes to
  the Photos-backed saved row, so later Play and Share actions never use the moved
  temporary file.
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
  title hard-coded to "Luna Video" in all apps) and Liquid Glass action pills in
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
  Photos asset first when one backs the item, then removes the Downloader and saves list
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
  that it threw and the transfer ran invisibly. Luna Video's **Settings → Video →
  Notify save progress** setting defaults to off, so ordinary background saves remain
  silent; when enabled it permits Luna's Live Activity. On iOS 27 builds compiled with Xcode 27 the
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
  `LunaMediaDownload` in the app or the share/action/Safari extensions, and
  `MediaIntentHandoff.install()` runs only from `KindWiring+Luna.swift` /
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
- **Legacy saves list long press** — manual Save to Photos remains available in the
  combined/debug list and uses the same confirmed local-to-Photos transition for
  Downloader rows.

The carousel observes both `.savedMediaChanged` and `.savesChanged`.
`SavedMediaStore` also posts an App-Group-specific Darwin notification for mutations made
in another process; the carousel bridges it back to `.savedMediaChanged` and reloads on app
activation because Darwin notifications may be dropped while suspended.

## Bounce back to Safari, and optional tap-to-view Live Activity

A media pill save (`&ret=safari` on the deep link, `claudedocs/safari-extension.md`)
reopens the original https page in Safari once the download has actually started:
`PlatformItemIngestor.ingest` is awaited all the way through
`LiveMediaDownloadManager.shared.start` (which requests a Live Activity only when the
user has enabled **Notify save progress**) before
`SceneDelegate`'s save-press `Task` returns, so by the time
`SafariReturnPolicy.shouldReturn` decides to bounce (`UIApplication.shared.open` on
the original URL, never a private scheme), the transfer is already running in the
background `URLSession` — bouncing away doesn't race the transfer. When enabled,
the activity is already visible. The transfer and the optional activity's lifecycle are otherwise unaffected by
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
`.localFile` centers the deck on that item's card; it does **not** open the
source URL in an in-app browser. The card is the handoff destination. The finished
card's separate Share link still centers the card and raises the system share sheet.
`.photosReference` reuses the card's own "open in Photos" mechanism
(`MediaCardFactory.openInPhotos`, the `photos-redirect://` scheme — no new scheme was
invented); still-downloading or an unknown URL just lands on the deck, the same as
any other cold/foreground launch.

**The finished card gets FIVE SECONDS live, and a dismissal policy cannot buy them.**
ActivityKit's `dismissalPolicy` governs only the Lock Screen's after-end banner: the
LIVE presentation — the Dynamic Island the user is watching from Safari — is gone the
instant `end()` is called. `save()` used to `end` immediately after its `.finished`
update, so the completed state never had any screen time at all: the island froze at
whatever progress the app saw before it suspended (a background `URLSession` sends no
progress to a suspended process — expected) and then simply vanished. The finished flow
is now three steps, in `LiveMediaDownloadManager`:

1. **Update to `.finished`, alerting.** The end-of-life alert (title + body + sound,
   same shape as the download-started one, and still suppressed while
   `areActivityAlertsSuspended` — a bulk import) rides the UPDATE now rather than an
   end call, since the activity is not ending yet. `updateActivity(for:alerting:)` and
   `endActivity` share the one `endOfLifeAlert(for:)` definition.
2. **Clean the store up immediately** (`removeRedditStaging`, `store.remove`) — the
   save is complete and there is nothing left to recover.
3. **Hold, then end `.immediate`.** `holdFinishedActivity` sleeps
   `finishedLiveHold` (5s) in a detached task under its OWN
   `BackgroundExecutionLease`, so a process woken purely to finish this download
   survives its own hold — deliberately **not** `startTrackedBackgroundWork`, whose
   counter gates the `handleEventsForBackgroundURLSession` completion handler and must
   not be held five extra seconds. Only afterwards does it delete the job's files
   (`store.removeFiles`): the widget reads its thumbnail off disk on EVERY render, so
   it has to outlive the card — which is also why a finished job used to leak its
   `<jobID>.jpg` in the App Group forever.

Because the job record is gone during the hold, a process killed inside those five
seconds would strand an active card that nothing could ever end (an activity outlives
the process that requested it). So `resumeUnfinishedDownloads` — launch, foreground,
the overnight pass — finishes with an **orphan reaper**:
`reapOrphanedActivities(keepingJobIDs:)` ends, immediately and without an alert, any
`.active` activity whose `attributes.jobID` the store no longer knows. Cards mid-hold
in THIS process are exempt (`jobIDsInFinishedHold`), and already-ENDED activities are
left alone — that's a failure card living out its `failureDismissalDelay`, deliberate
and none of the reaper's business. The FAILURE paths (`failJob`, `startFailedActivity`,
`tearDownSuspendedJob`) are otherwise unchanged: they still end with a dismissal delay
rather than a live hold.

**What the finished card shows** (`LunaDownloaderLiveActivityWidget.swift` — one source
file, compiled into both widget targets): the thumbnail, the title, the completed
message (`Saved to Luna` / `Saved to Photos`, from `job.statusMessage`), and where the
moon-horizon progress track was, two `Link`s — **Play** (`play.fill`) and **Share**
(`square.and.arrow.up`). A full track would read as a stalled transfer rather than a
result, so it is not drawn at `.finished`, and compact trailing shows a checkmark
instead of a percentage with nowhere left to go. Links rather than buttons because a
widget cannot present anything itself: Play opens `viewURLString` (the tap-to-view route
above), Share opens `shareURLString` — the SAME `media` route plus `&share=1`
(`LunaDeepLink.mediaShareLink` / `mediaShareRequested(from:)`, tolerant of reordered
query items, and `mediaViewURLString(from:)` still recovers the source URL from it), so
`SceneDelegate.openMediaDeepLink` centers the same card and then raises
`UIActivityViewController` over a materialized copy of the file. Producing that copy is
the media kind's answer, `KindWiring.mediaShareFileExporter` — a
`MediaShareFileExporting` of plain Foundation closures (so the universal shell names no
media type), non-nil only in `Luna`/`LunaDownloader`, wrapping the same
`MediaAutoDownloader.exportFile` + `MediaDownloadStorage.discardIntentExport` pair the
card's own share menu and the App Intent handoff use. Everything with no file to hand
over — a `.photosReference` save, a transfer still running, an unknown URL, an export
that fails, an app that links no media kind — degrades to exactly the tap-to-view
behavior described above.

## Finishing the hand-off's save

Safari's Download hand-off (`claudedocs/safari-extension.md`) is the one save that
leaves the app before its row has any metadata: the launch reserves the row, starts
the transfer, requests the activity and bounces. That row must not sit blank in the
deck until somebody opens the app.

- `PendingResolvedMediaDownloads.persistSave` reserves the row **and** records the
  debt (`PendingIngestCompletions.owe`, LunaStorage, App-Group backed, 3-day
  lifetime) in the same breath — before anything that can fail or take time. The
  debt is durable precisely so a process that dies still owes it.
- **Normally it then pays that debt from the record**, with no network at all:
  the appex resolved this post to render its in-page player, so the title and the
  page's own author (`content.js`'s `pageAuthor()`) that it sent, plus
  `PlatformRecognizer`'s URL-parsed `platform`/`platformItemID`, are already
  enough to write the row a metadata pass would (`completeFromHandoff`). The row
  THUMBNAIL is the one field left to a fetch — it needs image bytes, which the
  transfer's own poster fetch gets anyway. Which author signals the page is read
  for, and what happens when it states none, are in
  `claudedocs/safari-extension.md`.
- **A record that could not answer** (the resolve had not finished, so no title;
  or a URL no platform rule recognizes) stays owed, and the app finishes it
  itself, in the background, once the user is already back on the page.
- After the bounce the drain posts `requestRun()`; `BackgroundIngestCompletion`
  (LunaSaves — the tier that can name `SavesIngestor`, which the media
  module cannot) runs the ordinary non-interactive ingest for each owed row under
  its own `BackgroundExecutionLease`, ended the moment that row reaches a verdict.
  The ingest's media leg attaches to the transfer already running rather than
  starting a second one.
- **If iOS reclaims the window mid-ingest**, the lease's `onExpiration` cancels the
  ingest task at the one point that is safe: `SavesIngestor.ingest` checks
  `Task.isCancelled` after the pipeline and before it persists, so a cancelled pass
  writes nothing and the row stays exactly `.pending` — never half-written. The debt
  stays queued with its attempt count bumped, and the next resume finishes it: the
  background `URLSession` running this very download wakes the process when it
  completes (`AppDelegate.handleEventsForBackgroundURLSession` works the queue on a
  fresh lease, without delaying the session handler), and launch works it too.
- `SavesIngestor.ingestAllPending` is unchanged and remains the safety net for
  a process that was killed outright — it is simply no longer what the normal path
  depends on.

## In-app progress: embedded, never floating

In-app download progress is drawn **on the item that is downloading**, not in
app-level chrome. There is no floating download bar; the former
`DownloaderProgressFooterView` — a glass slab pinned above the scrub strip that
adopted whichever job started first — is deleted.

- An **`.undownloaded` carousel card** carries its own progress: poster + dim +
  an embedded glass status bar inside the card's bottom edge (status line,
  percentage while `.downloading`, moon-horizon bar). Failure keeps the bar up
  with the reason in red, the retry glyph, and — for a `.noMedia` failure — the
  chat hand-off row, the same one the failed-save card shows (see
  `claudedocs/llm-handoff.md`).
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
touching the download. Any card or full-screen player pauses on backgrounding,
so a completed background transfer can never start or continue video audio;
only the Live Activity's explicit pause
(`LiveMediaDownloadManager.suspend(jobID:)`, called solely from the widget's
intent) ever suspends one. A card recreated mid-transfer re-reads the snapshot and
picks the bar up where it is, and out-of-app progress remains the Live Activity's
job.

## Long downloads, interruption, and storage

`LiveMediaDownloadManager` uses a shared-container background `URLSession` with launch
events, connectivity waiting, and a seven-day resource timeout. Its stable identifier is
`<process bundle id>.mediaDownload.background.v2`, so the containing app and each of its
share, action, Safari, and Live Activity processes own distinct sessions even though
they use the same App Group. When iOS wakes a containing app for a completed
extension transfer, `AppDelegate` routes the callback's identifier through the media shell;
the manager recreates that exact session and retains its delegate until the session finishes
delivering events. The central app accepts only its own exact embedded-process identifiers,
not sibling app identifiers that merely share its bundle-id prefix. This is a clean-break
identifier change; the retired generic session is intentionally not adopted.

Each `media_download_jobs` row persists that exact session identifier as well. Launch repair,
explicit retry, pause/resume, and expired-suspension cleanup operate through the owning
session's retained manager; a process never compares a shared job with the wrong session's
task list and starts a duplicate transfer.

Jobs persist expected and
received byte counts, resolver stage, source range, and a sidecar resume-data file. A user
pause asks `URLSessionDownloadTask` to produce resume data; transient network failures retry
once and then remain in the visible **Waiting to resume** state instead of being discarded.
`JobStore` applies every existing-job change as a single lock-held mutation, so progress
callbacks cannot overwrite retry counters or resolver bookkeeping. It also creates jobs with
an atomic insert-or-reuse check, preventing simultaneous starts for one source URL from
registering duplicate background transfers. Job state is stored only in the
`media_download_jobs` table. The retired `jobs.json` is neither imported nor deleted at
runtime; the same manual-wipe upgrade policy applies, so an obsolete sidecar can never be
mistaken for authority or used as a reason to clear current SQL rows.
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
(`/<user>/reel/<code>/`). Resolution then runs a three-stage ladder, and the order
exists for one reason: **Instagram hands out a reel's cover frame freely and its
playable MP4 from exactly one endpoint.**

1. **The post page as served to a search crawler** — a cookie-free GET to
   `/p/<code>/` with the Googlebot user agent
   (`MediaDownloadHTTP.googleCrawlerUserAgent`). Instagram serves that UA the full
   logged-out rehydration JSON it strips from the same page under a browser UA:
   `data-sjs` script tags carrying `xig_polaris_media.if_not_gated_logged_out`, an
   api-v1-shaped media node (`media_type`, `video_versions`, `image_versions2`,
   `carousel_media`). Today this is the only keyless source that still returns a
   reel's playable URL, and it serves stills and carousels too.
2. **The web client's persisted GraphQL query** — a GET to
   `/graphql/query/?doc_id=…&variables={"shortcode":…}` with the public
   `X-IG-App-ID` instagram.com's own JavaScript sends. `doc_id` names a query
   Instagram has already registered server-side, so there is no key and no login.
   It returned `video_url` until Instagram login-walled the logged-out endpoint
   (observed 2026-09: 401 `require_login` for every request); it stays in the
   ladder because it answers again the moment that wall lifts. It is a
   GET rather than the POST the site itself issues because the durable background
   engine can only run plain download tasks (no request body) — and the endpoint
   answers this GET while 403-ing a bodyless POST.
3. **The embed page** (`/p/<code>/embed/captioned/`) — its `contextJSON` blob
   still carries stills and carousels, and any `video_url` it does hand back.
   A copyright-flagged reel's embed reports `copyright_blocked` and never carries
   the URL.

The GraphQL and embed endpoints return the same `shortcode_media` node shape, down
to `edge_sidecar_to_children`; only `__typename` gains an `XDT` prefix on the
GraphQL one, which is why video detection matches that name's suffix. One node
parser serves both; the crawler page's api-v1 node has its own.

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
downloads the wrong thing. The durable background engine mirrors the same three
stages (`instagramPostPage` → `instagramGraphQL` → `instagramEmbed`, via
`startNextInstagramResolve`), the way its Facebook and YouTube ladders mirror
theirs; reordering one means reordering both.

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
fail explicitly when no public progressive stream is present. Luna now treats ordinary YouTube watch
pages as **playback-only** rather than launching a doomed transfer: the extensions show an independently
fetched poster and an **Open in YouTube** button. Tapping the poster replaces it with the official inline
IFrame Player; the button attempts to open the original URL and then closes the extension whether the
launch succeeds or not. The Downloader and central Luna decks load that same player immediately inside a
16:9 media rectangle, with the native poster/button retained as its policy/error fallback. The iframe is
hosted in `WKWebView` through YouTube's documented iOS local-HTML integration: the HTML's HTTPS `baseURL`
is the running bundle identifier, supplying the required Referer/client identity that a direct `/embed/`
navigation omits (and which YouTube rejects as error 153). Only the player rectangle claims web gestures;
the rest of the card remains available for carousel paging and its blank space for the card context menu.
The iframe starts transparent over the same cached, decoded poster used by the mini-carousel chip: fast
card paging therefore keeps the correctly sized still visible, while a centered card overlays a spinner
until the IFrame reports ready. Direct `/shorts/` URLs retain
the existing downloader path. YouTube's developer policies also
restrict downloading/offline playback without authorization; shipping this feature requires a
separate product/legal review.

## Settings

Luna and Luna Video share the same `Settings → Video` screen with two picker rows and
one toggle:

1. **Begin Streaming** — **Never**, **Always** (the default), or **On Wi-Fi Only**.
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
3. **Notify save progress** — defaults to off. Enabling it restores the background
   save Live Activity; the setting has no explanatory footer.

The screen writes through `MediaStorageSettings.choose`, not `option`, so the user's
answer is recorded as theirs (`hasExplicitChoice`). That marker is what the util
card's inline **“Store files in Luna / in Photos”** line waits on: Luna is the
default, and Photos needs a permission nobody has been asked for, so both downloading
apps offer the choice on the card until it is answered anywhere — and that row, unlike
this screen, asks for Photos access BEFORE it saves the setting
(`MediaUtilCardStorageChoice`, `claudedocs/util-card.md`).

All values live in the App Group so the app, App Intents, share/action extensions, and
background completion code make the same decision. Photos storage is global: every completed
download is saved to Photos or none are; there are no per-platform Photos toggles.

## Core implementation

**Central Luna does not call any of the resolvers below.** It resolves
social/video media through the plugin platform instead —
`PluginMediaResolver` (LunaPluginIngest) runs the classify+ingest walk over
the bundled `reddit.js`/`instagram.js`/`tiktok.js`/`facebook.js`/`x.js`/
`youtube.js`/`direct-media.js` plugins and installs itself as
`PluginMediaSeams.resolver`/`.reresolver`; `MediaAssetResolution`
(LunaMediaDownload) reads that seam and falls back to `SocialMediaResolver`
only when it is nil. Everything in this section — `SocialMediaResolver`,
`YouTubeMediaResolver`, and the reresolve path they drive — is still the
ONLY implementation for the Downloader app and for the three sibling Safari
appexes, which link no plugin module at all. Full detail, including the
JS↔Swift fixture parity and the schema columns (`plugin_id`, `quality`,
`expires_at`, `request_headers_json`) that make reresolution work for a
plugin-owned job, is in `claudedocs/plugins.md`.

- `MediaDownload.swift` defines `MediaAsset`, supported platforms, errors, and the
  resolver/downloader/Photo-library protocols.
- `SocialMediaResolver.swift` dispatches to pure parsers for X, Instagram, TikTok, and
  Facebook. X uses fxtwitter JSON; TikTok parses hydration/reflow JSON; Instagram prefers
  the crawler-served post page and never substitutes a still for a video (see the Instagram
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
  finishes) holds an iOS background-execution lease — `BackgroundExecutionLease`, which
  lives in LunaStorage because the hand-off's background ingest holds one too. The lease ends as soon as the
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
- `SavedMediaStore.swift` owns the SQL-backed three-state model, local files/thumbnails,
  retention, and crash recovery. It has no legacy-manifest migration/reset path.
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
