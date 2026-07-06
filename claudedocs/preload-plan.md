# Link Preloading Plan (nextcommands #2)

Goal: when an article is saved, background-preload the content of all links on it,
recursively to a configurable depth, so tapping a link in any save opens the inline
viewer ~instantly. Preloaded pages are stored in the same on-disk form as a normal
save (reader content / platform-URL / web-archive fallback), in a **shared,
URL-keyed, refcounted cache** so duplicate links across trees keep one copy and are
deleted when no save references them.

## Hard safety invariant
The preload cache is **physically isolated** from real saves: its own directory
(`Preloads/`) and index (`preloads.json`), never `readingList.json` / `Articles/`.
Preload code never deletes or mutates a user's saved item or its files. The only
touch-point in `ReadingListStore` is a single call on item delete that asks
`PreloadStore` to release that root's subtree — and `PreloadStore` only ever deletes
files under `Preloads/`. A bug in preloading can waste space or fail to preload; it
can never corrupt or delete the user's library.

## Setting
`ReaderSettings.preloadDepth: Int` (App Group), default **1**, clamped 0…5. 0 = off.
Settings UI: a stepper/segmented row under Reading List (or Experimental). Depth N
means: preload links on the saved page (depth 1), then links on those pages (depth
2), … up to N.

## Data model (`PreloadStore`, ReaderKit, App Group `Preloads/`)
`preloads.json` = `[urlKey: PreloadEntry]`.
- `urlKey` = sha256 hex of the canonical URL (`ArticleFetcher.canonicalForArchiving`
  / unwrapped + lowercased host + no fragment). Stable, filesystem-safe.
- `PreloadEntry`:
  - `urlString` (canonical)
  - `kind`: `.article` | `.platform` | `.webArchive` | `.unrepresentable` (paywalled/
    failed — recorded so we don't re-crawl every time, and so the viewer falls back
    to a live load)
  - `contentFile`: `<urlKey>.json` (article) or `<urlKey>.webarchive`, or nil
  - `platform`: small descriptor (ContentPlatform + itemID) for `.platform`
  - `owners`: `Set<UUID>` of ROOT save item IDs whose preload subtree includes this
    URL (the refcount = `owners.count`)
  - `children`: `[urlKey]` discovered outbound links (for tree teardown + resume)
  - `depthRemaining`: how much deeper we still intend to crawl from here (for resume)
  - `state`: `.pending` | `.loaded` | `.failed`
  - `updated`: Date

Refcount semantics: when root R's tree is (re)built, every URL reached is given
`owners.insert(R)`. On delete of R, `releaseTree(rootID: R)` removes R from every
entry's `owners`; any entry with empty `owners` has its files deleted and is dropped.
(Children are reachable transitively via `children`, so teardown walks R's roots.)

## Preload engine (`PreloadCoordinator`, main app)
- Trigger: after a root article is persisted (`IngestorOutcomePresenter` article path)
  AND on demand for any existing `.ready` article missing a complete tree (resume).
- BFS queue of `(urlKey, url, depthRemaining, rootID)`. For each not-yet-loaded URL:
  - Run the **UI-free** `IngestPipeline.process` (silent only — no WKWebView, no
    CAPTCHA). Map Outcome:
    - `.article(content, _)` → save `<urlKey>.json`, kind `.article`; enqueue its
      links at `depthRemaining-1`.
    - `.social/.video/.audio` → kind `.platform` (store descriptor); no children.
    - `.needsArchive` (paywall the silent leg couldn't crack) → kind
      `.unrepresentable` (give up — no UI/CAPTCHA in preload).
    - `.product` → kind `.unrepresentable` for v1 (not a reader page; the live tap
      handles product UI). [Deferred: dedicated product preload.]
    - `.failed` / non-reader → **web-archive fallback** (see below), else
      `.unrepresentable`.
  - Dedup: if the urlKey already exists `.loaded`, just add the root to `owners` and
    enqueue its existing `children` (so the shared copy's subtree is owned too) — no
    re-fetch.
- Concurrency: a small bounded worker (≤3) off the main thread. Never blocks UI:
  the save's checkmark/Outcome completes immediately; preload runs detached.
- Background survival: fresh-save preloads wrap with `UIApplication.beginBackgroundTask`
  (main app) for a brief background window, and stop on expiration. Bulk foreground
  resume does NOT claim background time; it is coalesced, foreground-only, and cancelled
  on `UIApplication.didEnterBackgroundNotification` so a reopen/close cycle cannot
  leave a long crawl running after the user leaves Luna.
- Refresh policy: already-loaded preload entries are never refreshed by background
  crawls. A cached article may refresh only after the user opens that article, only
  while the app is foreground-active, and only when its `lastLoadedAt` is at least
  48 hours old (legacy entries with no timestamp are treated as due once). If the app
  backgrounds mid-refresh, the refresh task is cancelled; first-time root/nested loads
  are the only preload work allowed to spend background time.
- Resume: on `sceneWillEnterForeground` and in the existing inbox BGAppRefresh, call
  `PreloadCoordinator.resumeIncomplete()` which finds `.ready` articles whose root
  tree is missing/partial and continues. We do NOT re-refresh already-complete trees.

## Web-archive fallback (best-effort, main app only)
A non-reader, non-platform, non-paywalled page is saved as a `.webarchive` via a
headless (off-screen) `WKWebView` snapshot on the main actor, guarded by background
time and skipped in extensions. This is the one piece that needs a WKWebView; it is
NOT used for paywalled pages (those are `.unrepresentable`). [If background time is
unavailable it's deferred to the next foreground resume.]

## Inline viewer instant-load + refresh (`InlineReaderPageViewController`)
- On open, check `PreloadStore.entry(for: url)`:
  - `.article` → embed the reader from the cached `ArticleContent` immediately (no
    fetch) → instant.
  - `.platform` → show the platform view.
  - `.webArchive` → load the archive file.
  - none/`.unrepresentable` → current live fetch+extract path.
- Background refresh: after showing the cached copy, kick a live `IngestPipeline`
  fetch; if it yields fresher content, replace the on-disk copy and refresh the view,
  **preserving scroll** by capturing the reader's `currentReadingWordIndex` /
  content offset and restoring it after re-render. [Scroll preservation is
  best-effort; if the content changed materially we keep top.]

## Deletion
`ReadingListStore.removeFiles(for:)` → `PreloadStore.releaseTree(rootID: item.id)`.
Only `Preloads/` files are touched.

## Tests (no live network)
- `PreloadStore`: refcount add/release across two roots sharing a URL → file kept
  until both released, then deleted; URL-key canonicalization; index round-trip.
- `PreloadDepth` setting clamp.
- BFS planning (pure): given a link graph + depth, the set of URLs to crawl and the
  dedup/owner assignment. (Pure `PreloadPlanner` over an injected link-provider.)
- Outcome→kind mapping.
Live fetching is NOT unit-tested (no network in tests / don't hit sites).

## v1 scope vs deferred
v1 implements: the setting + UI, `PreloadStore` (refcounted shared cache for
`.article`/`.platform`/`.unrepresentable`), `PreloadCoordinator` BFS via the UI-free
pipeline, dedup, deletion release, foreground/BG resume, and inline instant-load from
the article cache + background refresh.
Deferred (documented, low-value/high-risk): headless web-archive snapshotting and
scroll-preserving live refresh are implemented behind guards but may no-op if
background time/WKWebView is unavailable; dedicated product-page preload.
