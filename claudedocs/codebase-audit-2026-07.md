# Luna codebase audit — July 2026 — fix plan

Scope: startup performance, runtime performance, bugs, animations, multi-thread
usage, memory usage, code design/quality, across all three apps and the
`LunaLibraries` package.

Overall assessment: the codebase is disciplined — the reading-list store has a
stat-token cache and cross-process file coordination, list-cell thumbnails
already decode downsampled off-main through an NSCache, Spotlight sweeps are
debounced onto a utility queue, BGTask scheduling is idempotent, and audio
persistence deliberately separates cheap App-Group ticks from store writes.
The issues below are the remaining hot spots, ordered by user impact within
each workstream.

Conventions for implementers (from CLAUDE.md and repo practice):
- Commit each fix as its own small commit; **stage only the files you touched**
  (`git add <paths>`, never `git add -A`) — the working tree carries unrelated
  uncommitted changes (`Luna.xcodeproj/project.pbxproj`, icon `Contents.json`)
  that must not be swept into a commit.
- Compile-check per commit:
  `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS Simulator' DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO -derivedDataPath .build-dd-262`
  The full unit-test suite runs ONCE at the end of all workstreams (the
  coordinator does this), not per commit.
- Package modules need `public` API + explicit `public init`s; Swift 5 language
  mode; UIKit; deployment target iOS 18.
- Match surrounding code style, incl. the repo's "explain the why" comment
  voice. Update `claudedocs/` feature docs if behavior described there changes.

---

## WS-A — Downloader download pipeline I/O (LunaMediaDownload)

**A1. `JobStore` re-reads/re-writes `jobs.json` on every progress callback.**
`LunaLibraries/Sources/LunaMediaDownload/LiveMediaDownloadManager.swift:1332-1424`.
`urlSession(_:downloadTask:didWriteData:…)` (line ~1024) runs per received
chunk — often many times per second — and each call does
`store.job(id:)` (full disk read + JSON decode of jobs.json) followed by
`store.upsert(job)` (another full read + decode + encode + atomic write), on
the URLSession delegate queue. `jobs.json` has **no other writer process**
(verified: no LiveMediaDownloadManager/jobs.json references in
LunaShareSurface, LunaIntents, or Luna/Intents), so:
- Give `JobStore` an authoritative in-memory `[LiveMediaDownloadJob]` (loaded
  once lazily from disk, guarded by its existing `lock`), and make
  `jobs()`/`job(id:)` serve from memory.
- Keep persisting to disk (a background relaunch after suspension must be able
  to restore jobs), but throttle persistence from the progress path: write on
  phase changes and job add/remove always; for pure progress updates write at
  most ~2×/sec or on whole-percent change. In-memory state always updates.

**A2. Live Activity updated on every chunk.** Same delegate method ends with
`Task { await updateActivity(for: job) }` — unthrottled `activity.update`
calls per chunk burn CPU and ActivityKit update budget. Throttle to
whole-percent progress changes (the in-process notification already does this
via `previousPercent`) — reuse that same gate for `updateActivity`, while
keeping unconditional updates on phase transitions.

**A3. `SavedMediaStore.items()` decodes the manifest from disk on every call.**
`LunaLibraries/Sources/LunaMediaDownload/SavedMediaStore.swift:265` (and
`item(id:)`/`item(forURLString:)` funnel through it). The manifest IS written
by other flows, so mirror `ReadingListStore`'s pattern: an in-memory cache
validated by a file-stat token (modification date + size), refreshed by every
mutation from the array it just wrote. Keep all existing locking.

**A4. `purgeExpired()` runs on the main thread.** Two call sites:
`Luna/AppDelegate.swift:177-182` (`.readingListChanged` observer on
`queue: .main`) and `Luna/SceneDelegate.swift:217`
(`sceneWillEnterForeground`). Both do manifest disk I/O (+ file deletion)
under a lock on main. Dispatch the `purgeExpired()` work to a utility queue at
both call sites (the store is already lock-guarded and posts its change
notification on main).

Files: `LunaLibraries/Sources/LunaMediaDownload/LiveMediaDownloadManager.swift`,
`LunaLibraries/Sources/LunaMediaDownload/SavedMediaStore.swift`,
`Luna/AppDelegate.swift`, `Luna/SceneDelegate.swift`.
Tests: `LunaTests` has media-download/saved-media coverage — extend it for the
JobStore cache (cache serves writes back; persisted file still restorable) and
the SavedMediaStore stat-token cache (cross-instance visibility via re-stat).

---

## WS-B — Image decode hygiene (memory + scroll performance)

The repo already has the right pattern twice (downsampled, off-main, NSCache:
`LunaLibraries/Sources/LunaReadingListUI/ReadingListItemCell.swift:24-45`,
`Luna/CatchUp/CatchUpSubviews.swift:310`). Extend it to the remaining
full-size main-thread decodes:

**B1. Downloader grid cells decode full-size on main.**
`Luna/Downloader/SavedMediaGridViewController.swift:589` —
`UIImage(contentsOfFile:)` per cell configure while scrolling (video
thumbnails can be large). Add a small shared downsampling loader (suggested
home: `LunaDesignSystem`, e.g. `DownsampledImageLoader` with
`load(path:pointSize:scale:into:token:)` semantics — CGImageSource thumbnail
API, NSCache keyed by path+size, decode on a utility queue, token check on
main delivery like `ReadingListItemCell.loadToken`). Adopt it in the grid
cell. Do NOT rework `ReadingListItemCell`'s existing implementation (snapshot
tests depend on its timing); adopting the shared helper there is optional and
only if snapshots stay green.

**B2. Downloader progress footer decodes the thumbnail from disk on every
progress notification.**
`LunaLibraries/Sources/LunaReadingListUI/DownloaderProgressFooterView.swift:123-125`
— `apply(_:)` runs per posted percent tick and re-reads + re-decodes the same
thumbnail file each time. Cache the decoded image keyed by `fileName` (one
`UIImage?` + key ivar is enough — the footer tracks a single job).

**B3. Scroll reader decodes a full image on every touch.**
`LunaLibraries/Sources/LunaReaderUI/ScrollReaderViewController.swift:633-673` —
`gestureRecognizer(_:shouldReceive:)` calls `image(at:)`, which performs
`UIImage(contentsOfFile:)` just to decide whether a touch landed on an image.
Split it: a `imageEntry(at:) -> (entry, rect)?` hit-test that only consults
`rendered.imageRanges` + glyph rects (no decode), used by `shouldReceive`; the
actual decode happens only in `imageTapped` when presenting the lightbox (and
can reuse `ArticleTextRenderer`'s decoded cache if suitable — see
`LunaLibraries/Sources/LunaReaderUI/ArticleTextRenderer.swift:190`).

**B4. Saved-media viewer decodes full-size synchronously on main.**
`Luna/Downloader/SavedMediaViewerViewController.swift:376`. Full resolution is
wanted here, but decode it off-main: load the `UIImage`, call
`byPreparingForDisplay()` (or `prepareForDisplay`) on a background task, then
assign on main with a stale-page token check.

**B5 (minor). Now Playing artwork.**
`LunaLibraries/Sources/LunaAudioPlayback/NowPlayingCoordinator.swift:198` —
`UIImage(contentsOfFile:)` for lock-screen artwork. Verify its calling thread;
if main, move the decode into the `MPMediaItemArtwork` request handler or a
background queue, and downsample to the requested size.

Files: `Luna/Downloader/SavedMediaGridViewController.swift`,
`Luna/Downloader/SavedMediaViewerViewController.swift`,
`LunaLibraries/Sources/LunaDesignSystem/` (new helper),
`LunaLibraries/Sources/LunaReadingListUI/DownloaderProgressFooterView.swift`,
`LunaLibraries/Sources/LunaReaderUI/ScrollReaderViewController.swift`,
`LunaLibraries/Sources/LunaAudioPlayback/NowPlayingCoordinator.swift`.
Tests: unit-test the new loader (downsamples to requested size, caches, token
staleness). UI behavior is covered by existing snapshot tests — if a snapshot
legitimately changes (it shouldn't; images should render identically), stop
and reconsider rather than re-recording.

---

## WS-C — Startup path (all three apps)

`application(_:didFinishLaunchingWithOptions:)` already defers most heavy work,
but three synchronous store/keychain touches remain on the launch frame:

**C1. First reading-list decode happens on main during launch.**
`Luna/AppDelegate.swift:202-203` — `schedulePriceRefresh(reason: "launch")` and
`refreshOverduePriceTrackersOnLaunch()` both call
`ReadingListStore.shared.priceTrackersStalestFirst()` → `items()` → file
coordination + full JSON decode, twice, before `didFinishLaunching` returns.
Defer both calls off the launch frame (e.g. a single
`DispatchQueue.global(qos: .utility).async` that computes, then hops to main
for any UI/BGTask work — note `schedulePriceRefresh` itself is already mostly
async via `getPendingTaskRequests`; the expensive part is just the store
read). Preserve call order/semantics: refresh-overdue must still run once per
launch.

**C2. `ingestAllPending()` sweeps synchronously on main at launch and
foreground.** `LunaLibraries/Sources/LunaReadingList/ReadingListIngestor.swift`
(`ingestAllPending`, line ~427): `store.items()` decode + per-item Task spawn
+ `backfillMissingWebArchives()` / `backfillMissingThumbnails()` (which scan
items and stat files). Called from `Luna/AppDelegate.swift:152` and
`Luna/SceneDelegate.swift:218`. Move the sweep body onto a background
queue/Task (its per-item work is already async; the enumeration and backfill
scans are the synchronous part). Check the backfill implementations for
main-thread assumptions before moving.

**C3. Keychain/email-account reads on the launch frame for diagnostics only.**
`Luna/AppDelegate.swift:51-52` reads `EmailAccountStore.shared.account` just to
record a diagnostic line. Fold that read into the existing deferred/utility
work so the (possibly slow, post-reboot) keychain query is off the critical
path. `DiagnosticLog.exportIdentityProvider` (line 63) is lazy already — fine.

Files: `Luna/AppDelegate.swift`, `Luna/SceneDelegate.swift`,
`LunaLibraries/Sources/LunaReadingList/ReadingListIngestor.swift`.
Tests: existing ingest tests must stay green; if `ingestAllPending` becomes
async-dispatched, add a test seam (e.g. injectable queue or completion) so
tests can await the sweep deterministically.

---

## WS-D — Reading-list reload churn (runtime perf + animation quality)

**D1. Every `.readingListChanged` does a full `tableView.reloadData()`.**
`Luna/ReadingList/ReadingListViewController.swift:474-488`. Ingest bursts are
already debounced to one reload per runloop pass (`scheduleReload`), but each
reload still rebuilds and reloads the whole table — losing in-flight row
animations and re-configuring every visible cell. The codebase already has an
id-keyed differ used by the filter path (`ReadingListDiff`, used in
`applyFilteredGroups`, line ~642). Reuse it in `reload()`: diff old vs new
groups, apply row/section inserts/deletes/moves + reconfigure-in-place, and
fall back to `reloadData()` when the diff is degenerate (first load, empty→
non-empty, section-structure change). Respect the existing
`isApplyingReorder` / `isAnimatingRowChange` guards. Note: cells self-identify
via `reuseKey` — reconfigure persisted rows through the existing
`configureItemCell` path.

**D2 (minor). `updateEmptyState()` rebuilds its label/container every reload.**
Same file, line ~493. Cache the background view and toggle it.

Files: `Luna/ReadingList/ReadingListViewController.swift` (and
`LunaLibraries/Sources/LunaReadingListUI/ReadingListDiff*` if the differ needs
a small extension).
Tests: `ReadingListSectioningTests` and snapshot tests exist — add coverage
for the diff-applied reload path if the differ gains new API. Snapshots must
not change.

---

## WS-E — Animation robustness

**E1. Onboarding looping animations die on backgrounding.**
`LunaLibraries/Sources/LunaSocialUI/OnboardingAnimationView.swift` uses
repeating `UIView.animateKeyframes(…, options: [.repeat])` (lines 395, 748,
1104, 1377, 1717, 2297). UIKit removes CAAnimations when the app backgrounds,
so returning to onboarding shows a frozen mockup. The view already has
`start()`/`stop()` (line ~103-126) that reset the animation tree. Add a
`didBecomeActiveNotification` observer (or `didMoveToWindow` + active check)
that calls `start()` again when the view is in a window; make sure re-entry
still can't stack loops (start() already resets first).

Files: `LunaLibraries/Sources/LunaSocialUI/OnboardingAnimationView.swift`.
Tests: none practical beyond compile + existing suite; keep changes minimal.

---

## WS-F — Store write hygiene (main-thread relief, measured scope)

**F1. Reader-exit store writes run a whole-list decode+encode+write on main,
mid pop-transition.** `ReadingListStore.coordinatedUpdate` executes
synchronously on the caller's thread; `saveReaderExitPosition` is called from
reader teardown paths (`ScrollReaderViewController.swift:803`,
`RSVPViewController.swift:1237`, `RabbitHoleReaderViewController.swift:796`,
`OriginalPageViewController.swift:87`) while the pop animation runs.
Scoped fix — do NOT make the whole store async:
- Add a private serial utility queue to `ReadingListStore` and an internal
  `asyncUpdate(_ body:)` that dispatches `coordinatedUpdate` onto it (the
  existing `mutationLock` already serializes against sync mutations from
  other threads; the `.readingListChanged` post already hops to main).
- Route ONLY the fire-and-forget position setters through it:
  `saveReaderExitPosition`, `setLastScrollOffset`, `setLastSpokenWordIndex`,
  `setLastWordIndex`, `setReadingProgress`. Everything with a return value or
  read-back expectation stays synchronous.
- Ordering caveat: a queued async update targeting a deleted item is already a
  safe no-op (`firstIndex` guard). The visible-state race (async write not yet
  applied when `items()` is read) is acceptable for these fields — they're
  resume positions consumed on the NEXT open — but verify no test or UI path
  reads them back immediately after writing.
- Test seam: add a `flushPendingUpdates()` (or make the queue injectable) so
  `LunaTests` can assert deterministically; update any test that calls these
  setters synchronously.

**F2 (design note, include in commit message not code).** If profiling ever
shows `items()` decode itself as a cost, the next step is caching decode
across processes via the existing stat token — already done. No action.

Files: `LunaLibraries/Sources/LunaStorage/ReadingListStore.swift`, affected
tests under `LunaTests`.

---

## WS-G — Repo/code hygiene

**G1. Untracked build cruft at repo root.** `.build-dd-262/` (derived data),
`Luna.xcodeproj/-Xcc/` (clearly an artifact of a malformed `xcodebuild`
invocation — a directory literally named `-Xcc`), `LunaLibraries/.swiftpm/`.
Add `.gitignore` entries for `.build*/`, `LunaLibraries/.swiftpm/`, and
`Luna.xcodeproj/-Xcc/`. Do not delete anything — just ignore. (Deleting the
stray `-Xcc` dir is safe if empty of project files, but leave that to the
user.)

**G2. `AppDelegate` `.readingListChanged` observer mixes concerns.** It both
purges saved media and reschedules the price refresh (lines 177-182). After
WS-A4 moves the purge off-main, consider whether the purge belongs on this
notification at all (media saves don't change on reading-list edits) — if the
original intent was "some activity happened, take out the trash", keep it but
say so in a comment. Minimal change; behavior-preserving.

Files: `.gitignore`, `Luna/AppDelegate.swift` (comment only).

---

## Verification (coordinator, after all workstreams land)

1. `xcodebuild build -scheme LunaDownloader …` and `-scheme LunaPriceTracker …`
   (compile all three shells).
2. Full suite once on an iOS 26.x simulator:
   `xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM"
   -configuration Debug -derivedDataPath $DD
   DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`
   Expected: 918+ tests, 8 skipped, 0 failures (modulo the environment-fragile
   `ArticleAudioEngineTests` — see CLAUDE.md; skip that class and run the rest
   if mediaserverd deadlocks).
3. Snapshot tests must pass WITHOUT re-recording — none of these fixes should
   change rendered pixels.

## Agent partitioning (sequential, one agent at a time, same working tree)

- Agent 1: WS-A (downloader pipeline + saved-media store)
- Agent 2: WS-B (image decode hygiene)
- Agent 3: WS-C + WS-F (startup + store write hygiene — both touch
  AppDelegate/store, keep together)
- Agent 4: WS-D + WS-E + WS-G (list reload diffing, animations, hygiene)

Sequential execution avoids git index races; each agent commits its own work
in small chunks and compile-checks per commit.
