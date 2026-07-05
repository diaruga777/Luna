# Luna performance & bug review — implementation plan (2026-07-05)

Reviewed by: Fable (full manual pass over the launch path, main screen, store,
readers, catch-up, transitions, ingest, search; leak sweeps over timers,
observers, script handlers, closures). This plan is the implementation contract
for the fix agents. **Commit each numbered item separately** once its tests pass.

Context: a prior quality pass (see `CODE_REVIEW_PLAN.md`, 2026-07-02) already
fixed retain cycles, data-safety, and dead code. This pass focuses on what's
left: **launch time, screen-transition latency, main-thread disk I/O, and a few
small bugs.** The dominant systemic issue is that `ReadingListStore` re-reads and
re-decodes the entire `readingList.json` on *every* call, and every mutation
rewrites the whole file and posts `.readingListChanged` — so hot paths multiply
into full-file JSON cycles on the main thread.

Measured shape of the problem (by code inspection):
- App launch: ~8 full decodes of `readingList.json` on the main thread before
  first frame (AppDelegate ×3, ReadingListViewController.reload ×4–5).
- Every `.readingListChanged` notification: 4–5 more full decodes + a full
  `reloadData`. Ingest of N items fires ~2–3 notifications each.
- Dragging the RSVP scrubber: **2 coordinated full-file read+decode+encode+write
  cycles per slider tick** (continuous events), each posting a notification that
  makes the list VC behind the reader do its 4–5-decode reload.

## Verification recipe (every item)

Compile check: `xcodebuild build-for-testing -scheme Luna -destination
'generic/platform=iOS Simulator' -derivedDataPath .build-dd
DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`.
Full/targeted tests: see CLAUDE.md "Running the unit tests" (needs a booted
iOS 26.x simulator; do NOT pass `CODE_SIGNING_ALLOWED=NO`). Run the suites
touching what you changed per item; run the FULL suite once at the end of your
batch. Snapshot tests are device-specific — if one fails, first check whether
your change legitimately altered rendering timing (see item 6's note) before
re-recording.

---

## Phase A — store layer (agent 1)

### 1. ✅ (done by reviewer) Commit the in-progress finish-detection work
The dirty working-tree changes (RSVP `finishIfAtEnd`, ScrollReader
`checkFinishedReading` after Phase-2/image swaps, + tests in
`ReaderScreenTests`) were reviewed and are correct. Committed separately before
agent work starts.

### 2. In-memory cache for `ReadingListStore` (biggest win)
`LunaLibraries/Sources/LunaStorage/ReadingListStore.swift`

`items()` currently coordinates + reads + decodes the whole file every call
("simple over fast"). Add a cache that preserves cross-process coherence:

- Add `private var cachedItems: [ReadingListItem]?` and a cache validity token
  = the file's `(modificationDate, fileSize)` captured when the cache was
  filled. Guard ALL cache state with the existing `mutationLock`.
- `items()`: stat the file (`FileManager.attributesOfItem`, microseconds). If
  the token matches, return `cachedItems`. Otherwise do the existing
  coordinated read + decode, then fill the cache with the fresh token.
- `coordinatedMutate` / `coordinatedUpdate`: after a successful
  `encodeItems`, update `cachedItems` to the just-written array and refresh the
  token (stat after write). On a skipped write (unchanged / unsafe), leave the
  cache as-is (but a decode that just happened may still refresh it).
- The stat check is what keeps writes from OTHER processes (intents,
  extensions) visible: their write changes mtime/size → next `items()` misses
  the cache and re-reads. Note in a doc comment that a same-mtime same-size
  cross-process write within the filesystem timestamp granularity is the
  accepted (harmless, notification-driven-reload-covered) trade-off.
- Update the class doc comment ("Reads fresh from disk on every operation") to
  describe the cache.
- Tests: extend the existing store tests — (a) mutation → `items()` returns
  updated list without hitting disk decode (hard to observe directly; at least
  assert correctness), (b) writing the file externally (direct `Data.write` to
  the store's URL in a temp-container store) is picked up by the next
  `items()` call.

### 3. Skip the write + notification when a mutation changed nothing
Same file. `coordinatedMutate` always re-encodes the array and posts
`.readingListChanged` even when `body` changed nothing (e.g. `add` returning an
existing item, `savePriceTracker` on a missing id,
`consumePendingSendFailureNotices` with no notices). Every such call is a full
disk write + a spurious full UI reload.

- Make `ReadingListItem` conform to `Equatable` (in
  `LunaLibraries/Sources/LunaModels/ReadingListItem.swift`; all stored fields
  are value types — synthesized conformance should work; check nested types
  need `Equatable` too and add where missing).
- In `coordinatedMutate`'s `perform`, capture the decoded array before `body`,
  and only `encodeItems` + mark changed when `all != decoded` (and
  `safeToRewrite`). Only `postChanged()` when a write actually happened.
  CAREFUL: `restore` / `restoreCatchUpState` / `seedForTesting` must still
  write when the arrays differ (they will — equality handles it), and
  `saveContent` also writes files outside the array (it mutates the array too,
  so it's covered).
- Tests: `add` on an existing URL must NOT post `.readingListChanged` (observe
  with an expectation + short timeout); a real mutation still posts.

### 4. Batch the RSVP reader's exit writes (store API half)
`ReadingListStore.saveReaderExitPosition` already batches scroll-reader exit
writes. Add a `lastWordIndex: Int? = nil` parameter (same skip-if-unchanged
semantics as `setLastWordIndex`) so the RSVP reader can persist word index +
reading progress in ONE coordinated cycle. Keep `setLastWordIndex` for other
callers. Tests: one call persists both fields; unchanged values don't write.

---

## Phase B — UI layer (agent 2; starts after Phase A is committed)

### 5. RSVP scrubber: stop persisting on every slider tick
`LunaLibraries/Sources/LunaReaderUI/RSVPViewController.swift`

`scrubbed()` is wired to `.valueChanged` (UISlider default: continuous) and
calls `pause()`, which calls `saveProgress()` → 2 (after item 4: 1) coordinated
full-file cycles per tick, each posting `.readingListChanged`.

- In `scrubbed()`: only call `pause()` when `isPlaying` (a paused scrub
  shouldn't re-run pause's save/display work); always `seek(toWord:)`.
- Persist once when the scrub gesture ends: add the slider targets for
  `.touchUpInside`, `.touchUpOutside`, `.touchCancel` → `saveProgress()`.
- `pause()` currently always calls `saveProgress()`. Keep that (play→pause is a
  legitimate save point) but make `viewWillDisappear` not double-save: it calls
  `pause()` then `saveProgress()` — one of the two saves is redundant. Simplest:
  `viewWillDisappear` calls `pause()` only when playing, then a single
  `saveProgress()`.
- Switch `saveProgress()` to the new batched
  `saveReaderExitPosition(readingProgress:lastWordIndex:for:)` (item 4) — one
  coordinated cycle instead of two.
- Tests: `ReaderScreenTests` cover RSVP; add one asserting a scrub
  `.valueChanged` does not write (e.g. `lastWordIndex` unchanged in the store
  until touch-up fires).

### 6. Price-tracker rows: stop decoding images synchronously on the main thread
`Luna/ReadingList/ReadingListViewController.swift`,
`configurePriceTrackerCell(_:item:tracker:)` does
`Data(contentsOf:)` + `UIImage(data:)` per cell on the main thread — full-size
decode, no cache — while the cell already has an async, downsampled,
NSCache-backed path (`Thumbnail.art(path:)`).

- Replace the manual load with
  `.art(path: store.articlesDirectory.appendingPathComponent(fileName).path)`
  (fall back to the existing `.logo` when `imageFileName` is nil). Keep the
  reuseKey shape.
- Same pattern in `Luna/CatchUp/CatchUpSubviews.swift` (~line 311 media card,
  ~line 565 tracker card): these are one-card-at-a-time so lower stakes, but
  they decode full-size on main. Use `UIImage(contentsOfFile:)` → the
  ImageIO downsampling helper. `ReadingListItemCell.decodeThumbnail` is
  private; either make a small shared helper (e.g. in LunaDesignSystem or a
  fileprivate copy) or expose a static decode on the cell — pick the cleanest
  minimal change.
- SNAPSHOT-TEST RISK: list snapshots that previously rendered the tracker
  image synchronously may now capture the spinner/logo frame. If a snapshot
  test fails, prefer making the test deterministic (pre-warm
  `ReadingListItemCell`'s decoded cache, or pump the runloop until the async
  decode lands) over re-recording a spinner frame.

### 7. Coalesce reading-list reloads and read the store once per reload
`Luna/ReadingList/ReadingListViewController.swift`

- `reload()` triggers `store.items()` 4–5 times per notification
  (`buildGroups`, `updateFilterVisibility` → `shouldShowFilter`,
  `visibleFilters`, `updateCatchUpButton`,
  `presentPendingSendFailureNoticeIfNeeded`). After item 2 these are cheap, but
  still: fetch `store.items()` ONCE at the top of `reload()` and pass the array
  through (change the private helpers to take `items:` parameters).
- Coalesce notification bursts: `.readingListChanged` arrives once per store
  mutation (ingest fires several per item). Replace the direct
  `reload` selector with a `setNeedsReload()` that dedupes to one reload per
  main-runloop pass (`private var reloadPending = false; DispatchQueue.main.async`
  flag-reset pattern). Keep the `isApplyingReorder`/`isAnimatingRowChange`
  guards inside the actual reload.
- `deleteItemAnimated`'s completion calls `updateFilterVisibility()` but not
  `updateCatchUpButton()` — the swallowed notification means the catch-up badge
  can go stale after an animated delete. Call it (and
  `presentPendingSendFailureNoticeIfNeeded()` is not needed there).

### 8. Batch deletes
- `ReadingListViewController.deleteSelectedTapped`: replace the per-item
  `store.delete(item)` loop with `store.deleteItems(ids:)` (one coordinated
  cycle + one notification instead of N).
- `CatchUpViewController.commitAndClose`: same — replace the
  `for id in pendingDeleteIDs { item(withID:) + delete }` loop with
  `store.deleteItems(ids: Set(pendingDeleteIDs))`.

### 9. `handlePriceRefresh`: install the expiration handler before starting work
`Luna/AppDelegate.swift`. `handleMailFetch` installs `task.expirationHandler`
BEFORE creating the work task (its comment says the price handler mirrors it),
but `handlePriceRefresh` creates the `work` Task first and installs the
expiration handler after — a (small) window where an immediate expiration has
no handler. Reorder to match `handleMailFetch` (use the same `var work:
Task<Void, Never>?` pattern).

### 10. Warning cleanup
`LunaLibraries/Sources/LunaStorage/ReadingListStore.swift` top:
`public extension Notification.Name { public static let readingListChanged … }`
— redundant nested `public` (compiler warning). Drop the inner `public`.

---

## Explicitly reviewed, NO action needed (don't "fix" these)

- Dot Matrix transition stack (center/session/animator/nav delegate/modal):
  prewarmed Metal overlay, ≤2× snapshots, careful bar compositing — sound.
- RabbitHole reader: spare-layer prewarm, preload promotion, region-confined
  wipes, session-owned speculative preloads with deinit backstop — sound.
- ScrollReader progressive two-phase render + the just-committed
  finish-detection changes — sound.
- Script message handlers all go through `WeakScriptMessageHandler` (prior
  pass); selector-based NotificationCenter observers auto-remove; RSVP/archive
  timers are weak+invalidated (`ArchiveWebReaderViewController` invalidates in
  `deinit`).
- `ReadingListItemCell` async downsampled thumbnail pipeline — the model to
  copy, not change.
- Search: `ReadingListSearchEngine.prepare()` runs off-main; it holds all body
  text in memory for the search session — acceptable, documented trade-off.

## Deferred (out of scope for the agents)

- Making `ReadingListViewController.open` load `store.content(for:)` off-main
  (needs a loading state in the push path; revisit if large articles still
  stall after items 2–8).
- Search-index memory footprint for very large libraries.
- Swift 6 strict concurrency; per-app dependency slimming (already in
  CLAUDE.md).
