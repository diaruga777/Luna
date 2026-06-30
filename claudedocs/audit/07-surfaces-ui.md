# Audit 07 — Input Surfaces + UI Outcome Handling

Scope: every way a URL enters Lune and how each surface presents the pipeline's
outcome. Owner's rule: the SAME pipeline runs across ALL surfaces; each surface is
a thin presenter; no surface hangs.

The shared core already exists: **`ArticleIngestDecider.decide(...) -> ArticleIngestDecision`**
(`.article` | `.priceTracker` | `.needsArchive` | `.failed`). That's the right
idea. The problem is (a) the decider is *not* the whole pipeline — the
non-textual classification (YouTube/platform/document) lives OUTSIDE it and is
re-implemented per surface; (b) presentation logic for the same outcome is
duplicated and inconsistent; (c) no surface that calls the decider directly wraps
it in a timeout.

---

## 1. Current-state map

There are SIX entry surfaces. Two distinct pipeline "depths" exist:

- **Full pipeline** = `ReadingListIngestor.ingest(item:)`: news-aggregator unwrap →
  document gate → **YouTube gate** → **platform gate** → re-save/tracker dedup →
  `ArticleIngestDecider.decide` → outcome-specific store writes + notifications.
- **Decider only** = `ArticleIngestDecider.decide(url:)`: product detection →
  `ArticleResolver.resolve` (direct + silent bypass + archive) → classify. **No
  YouTube/platform/document gate. No outer timeout.**

| Surface | Entry point | Pipeline depth | Presents outcomes via |
|---|---|---|---|
| In-app paste suggestion | `ReadingListViewController.savePasteboardCandidate` → `ReadingListIngestor.saveNewWithContent` (article, content pre-fetched by `PasteboardSuggester`) OR `handleSavePress` (video) | partial: video pre-classified by `PasteboardSuggester`, article persisted directly (skips decider) | row re-renders; tap → `open(_:)` |
| In-app "Save a Link" (typed/pasted URL) | `ReadingListViewController.addTapped` → `handleSavePress(source:.manual)` | **full** | list row; price tracker via `.priceTrackerSavedInteractively` notification → push `PriceTrackingViewController`; tap → `open(_:)` |
| App intents (Save Link, Safari page, platform finders, Save-from-App) | `IntentIngestHelper.handleSavePressWithTimeout` → `handleSavePress(source:.appIntent)` (12 s task-group timeout) | **full** | none in-process (background); item appears in list later; tracker push fires only if app is foregrounded via notification |
| Share extension (`com.apple.share-services`) | `ShareViewController.routeSavedOrReader` → `ingestArticleThenComplete` (article) / `autoDownloadThenComplete` (non-textual) | **decider only** + ad-hoc `NonTextualContent.detect` gate | `finishArticleIngest`: `.article`→checkmark, `.priceTracker`→save-silent+checkmark, `.needsArchive`→`ArchiveWebReaderViewController`, `.failed`→checkmark |
| Action extension "Read in Lune" (`com.apple.ui-services`) | `ShareViewController.routeSavedOrReader` → `presentReader` → `ShareReaderViewController.ingestAndPresent` (article) / `presentSavedNonTextual` (non-textual) | **decider only**, NO timeout | `ShareReaderViewController`: `.article`→`ReaderViewController`, `.priceTracker`→confirmation card, `.needsArchive`→archive reader, `.failed`→error card |
| Friend share (incoming) | `SocialMessageCenter.process(.readingListItem)` → `startIngest` → `ReadingListIngestor.ingest(source:.friendShare)` | **full** | none (background); notification only; tap later → `open(_:)` |
| Friend share (outgoing via people-row) | `ShareViewController.handleFriendShare` → `PendingFriendShareWriter.enqueue` → main app `drainPendingFriendShares` | none (queue only) | `complete()` immediately |

Outcome→UI in the **main app** (`ReadingListViewController.open(_:presenter:)`,
lines 992–1023): price tracker → `PriceTrackingViewController`; YouTube/platform/
media → `openItem` (deep link → embed → in-app Safari); `.needsCaptcha` →
`ArchiveWebReaderViewController` (extracts → reopens native reader); `.ready` →
`ReaderViewController`. This is the richest, correct presenter — every other
surface is a degraded subset of it.

### Where they diverge

1. **Non-textual gate lives in the wrong layer.** `ReadingListIngestor.ingest`
   gates YouTube (`YouTubeURL.videoID`, line 101) and platform (`PlatformRegistry.detect`,
   line 110) BEFORE the decider, and routes them to dedicated metadata ingest that
   *never fails*. But `ArticleIngestDecider.decide` itself contains **zero**
   YouTube/platform/document handling (`grep` count = 0). So any surface that calls
   the decider directly (the two extensions) must re-implement the gate. The share
   extension does (`NonTextualContent.detect` in `routeSavedOrReader`). **The decider
   has no idea what a video is.** The `reading-list.md` doc *claims* "ProductPageDetector
   runs inside ArticleIngestDecider after the YouTube/platform checks" — that is FALSE
   of the current decider code; the checks are only in the ingestor. Doc/impl drift.

2. **Action-extension reader has no timeout and (when reached for a non-article)
   would run the full article+price path.** `ShareReaderViewController.ingestAndPresent`
   (line 73) calls `ArticleIngestDecider.decide(url: url)` with all defaults — meaning
   `PriceFetcher` with its 30 s WKWebView render (`PriceFetcher.overallTimeoutSeconds = 30`,
   `WebViewPriceRenderer.renderTimeoutSeconds = 20`) plus `ArticleResolver`'s direct
   fetch + every silent bypass strategy + `fetchArchivedHTML`. There is **no
   `withTaskGroup` timeout and no watchdog** in this VC (grep: none). The only thing
   that gates a video away from this VC today is the upstream `routeSavedOrReader`
   `NonTextualContent.detect` branch → `presentSavedNonTextual`. If that gate ever
   misses a platform/video URL (or for a slow product page), the spinner runs for up
   to ~50 s of stacked timeouts and then shows the failure/price card — the
   "spinner forever on every link" symptom. The decider being a *subset* of the
   pipeline is the root cause: the reader trusts it to classify everything, but it
   only classifies article-vs-product-vs-paywall.

3. **`youtube-text-extraction` symptom.** Because the decider doesn't know YouTube,
   if a YouTube URL reaches `decide` it is treated as an ordinary article: it fetches
   the watch page HTML and runs `ArticleExtractor` over it → junk text / `.failed`.
   The main app never hits this (gated at ingestor line 101); the extensions only
   avoid it via the *separate* `NonTextualContent` gate in `ShareViewController`.
   Two independent gates that must agree — they currently happen to, but nothing
   enforces parity.

4. **Outcome handling is unequal per surface.**
   - `.priceTracker`: main app → interactive `PriceTrackingViewController` (creation/merge,
     "Read instead" override via `saveAsArticle`). Both extensions → save tracker
     *silently* + a checkmark/confirmation (can't present the price UI). Intents/friend
     share → silent (notification suppressed for `.shareSheet/.friendShare/.email` in
     `postPriceTrackerSaved`, lines 286–291). Four different behaviors for one outcome.
   - `.needsArchive`: main app, share ext, action-ext reader each construct
     `ArchiveWebReaderViewController` with their own `onClose`/`onExtracted` wiring
     (three copies of the same presentation glue).
   - `.failed`: main app marks `.failed` (red "Couldn't Load" section, pull-to-retry);
     share ext shows a checkmark as if saved (relies on later background retry);
     action-ext reader shows a red error card with no retry. Inconsistent and partly
     misleading (share-ext "Saved" on a failure).

5. **Paste mangling of non-http.** `addTapped` (line 683) does
   `NewsAggregatorUnwrapper.normalizedIncomingURLString(entered)` then
   `if !text.hasPrefix("http") { text = "https://" + text }`. The `fbrpc://`
   normalize-first ordering is correct, but ANY other non-http scheme the user
   pastes (e.g. `mailto:`, `tel:`, a bare word) gets blindly prefixed to
   `https://word`. There is no validity check before `handleSavePress`; the bad URL
   becomes a `.failed` item. The pasteboard *suggestion* path is safe
   (`PasteboardSuggester` validates), but the typed path is not.

6. **Friend-share path differences.** Incoming friend shares route through the FULL
   `ReadingListIngestor.ingest` (good — identical decisions), but: dedup is done in
   `SocialMessageCenter` (line 338) AND again inside `ingest` (tracker dedup, line
   126) — two dedup layers. Outgoing people-row shares bypass the pipeline entirely
   (just enqueue), correct for that surface. The incoming path is the one surface
   that uses the full pipeline yet presents NO outcome UI (background only) — fine,
   but it means the "robust outcome UI for every outcome" rule is met only lazily
   (when the user later taps the row).

---

## 2. Problems (summary)

- **P1 — Decider is not the whole pipeline.** YouTube/platform/document
  classification lives in `ReadingListIngestor`, not in the shared decider, so every
  extension surface re-derives it (`NonTextualContent.detect`) and the decider can
  misclassify a video as an article (junk extraction / failure). Root cause of the
  youtube-text-extraction symptom.
- **P2 — No mandatory timeout in the decider/its direct callers.**
  `ShareReaderViewController.ingestAndPresent` has none; `ShareViewController`'s
  watchdog only covers attachment *load*, not `decide`. `PriceFetcher` (30 s) +
  `ArticleResolver` archive leg (12 s) + bypass strategies stack into a ~50 s
  worst case → the action-extension "spinner forever" feel. Nothing bounds the
  whole `decide` call.
- **P3 — Duplicated routing.** `routeSavedOrReader` (share ext) and
  `ingestAndPresent` (action ext) and `open(_:presenter:)` (app) each switch over
  outcomes independently with subtly different behavior. Three+ copies of
  archive-reader wiring; two copies of "save tracker silently + checkmark".
- **P4 — Outcomes not uniformly handled.** `.failed` shows "Saved" in the share
  extension; price-tracker UI exists only in the app; no surface except the app
  offers a `.needsArchive` retry/escape that survives process death cleanly.
- **P5 — Typed-URL paste mangling** of non-http schemes (`addTapped`), no validation.
- **P6 — Double dedup** across `SocialMessageCenter` and `ReadingListIngestor`.
- **P7 — Doc drift.** `reading-list.md` claims the YouTube/platform gate is inside
  the decider; it is not.

---

## 3. Proposed simplified design

### One pipeline entry, one outcome, thin presenters

Move the WHOLE classification into the shared core so the decider becomes the
*complete* pipeline, and make the source travel with the input so per-surface
behavior is data, not branching scattered across VCs.

```
        paste / typed / intent / shareExt / actionExt / friendShare
                              │  (each builds an IngestInput)
                              ▼
                 IngestPipeline.process(IngestInput) -> Outcome
   (unwrap → document/video/platform gate → product detect → resolve → classify)
                              │  ONE timeout wraps the whole thing
                              ▼
        ┌───────────┬───────────┬──────────┬───────────┬─────────┐
     .article   .product    .social    .video     .needsArchive  .failed
        │           │           │          │            │           │
        ▼           ▼           ▼          ▼            ▼           ▼
              each surface's OutcomePresenter renders its case
       (app: rich; extension: reader/saved/archive/error; intent/friend: silent+notify)
```

### Unified input + outcome

```swift
/// Everything a surface knows about an incoming save. The source drives
/// presentation policy (interactive vs silent) without per-surface branching.
struct IngestInput {
    let url: URL                      // already fbrpc/http-normalized at the edge
    let source: CaptureSource         // paste, manual, appIntent, shareSheet, friendShare, email
    let prefetchedHTML: String?       // share ext already fetched once
    let forceArticle: Bool            // "Read instead" override
}

/// THE single outcome every surface receives. Invalid states unrepresentable:
/// each case carries exactly what its presenter needs.
enum Outcome {
    case article(ArticleContent, html: String)
    case product(ProductInfo, html: String)       // → price tracker
    case social(ContentPlatform, itemID: String?) // X/Bluesky/Reddit/IG/TikTok/FB
    case video(youTubeVideoID: String)            // never article-extracted
    case audio(ContentPlatform, MediaItemKey)     // music / podcast
    case document(DocumentType)
    case needsArchive(title: String)              // paywall → archive CAPTCHA
    case failed                                    // genuine failure (real, retryable)
}
```

`Outcome` ABSORBS today's `NonTextualContent` (`.video`/`.social`/`.audio`) and the
document gate, so the decider classifies EVERYTHING and no surface re-derives it.
`PlatformClassifier` (already in ReaderKit, extension-safe) moves to the front of
the pipeline.

### The pipeline (shared core, dependency-free, extension-safe)

```swift
enum IngestPipeline {
    /// Runs the complete classification for `input`, ALWAYS within `timeout`
    /// (default e.g. 25 s). On timeout returns `.failed` — never hangs. The order
    /// is fixed and identical for every surface:
    ///   1. unwrap news-aggregator wrappers
    ///   2. document? video? social/audio? → return immediately (no extraction)
    ///   3. product detection (priced) → .product
    ///   4. ArticleResolver → .article / .needsArchive / .failed
    static func process(
        _ input: IngestInput,
        timeout: Duration = .seconds(25),
        deps: PipelineDeps = .live
    ) async -> Outcome
}
```

Crucially: steps 1–2 are pure/cheap and run BEFORE any WKWebView render or archive
fetch, so a YouTube/social URL returns in milliseconds and can never reach the
price renderer or the article extractor — killing both the hang and the
youtube-text-extraction bug at the source. The timeout is a hard `withTaskGroup`
ceiling around the whole call (the pattern already used in `PriceFetcher` and
`IntentIngestHelper` — lift it up one level so it covers the entire pipeline once).

### Per-surface presenter contract

Each surface implements ONE method; the switch lives in the presenter, not the
pipeline. The pipeline is called identically everywhere.

```swift
protocol OutcomePresenter {
    /// Render `outcome` for a saved `item`. Must handle ALL cases (compiler-checked,
    /// no `default`) including `.needsArchive` and `.failed`. Never leaves a spinner.
    func present(_ outcome: Outcome, for item: ReadingListItem)
}
```

- **`AppOutcomePresenter`** (foreground list/search): the existing
  `open(_:presenter:)` behavior — price UI, reader, archive reader, video/embed,
  media. The reference implementation.
- **`ExtensionReaderPresenter`** (action ext): `.article`→`ReaderViewController`,
  `.video`/`.social`/`.audio`→`SavedNonTextualViewController` (so the reader VC
  never even *sees* a video), `.product`→confirmation card, `.needsArchive`→archive
  reader, `.failed`→error card with a "Save anyway / retry in app" affordance.
- **`SilentSavePresenter`** (share ext): checkmark for terminal cases;
  `.needsArchive`→inline archive reader; `.failed`→explicit "couldn't read, saved
  to retry" (NOT a misleading "Saved" checkmark).
- **`HeadlessPresenter`** (intents, incoming friend share): persists + posts the
  notification; `.product` from an interactive source posts
  `.priceTrackerSavedInteractively` (the policy already in `postPriceTrackerSaved`
  becomes presenter policy keyed on `input.source`). No UI.

Result: `ReadingListIngestor.ingest`, `ShareViewController.finishArticleIngest`,
and `ShareReaderViewController.ingestAndPresent` all collapse to
`presenter.present(await IngestPipeline.process(input), for: item)`. The four
copies of archive-reader wiring and the two copies of "save tracker silently"
become one method each on the relevant presenter.

Fixes mapping: P1→pipeline owns the gate; P2→single mandatory timeout; P3→one
switch in presenters; P4→exhaustive `Outcome` enum, no surface omits a case;
P5→validate `input.url` at the edge (reject non-http after fbrpc normalize);
P6→dedup once inside the pipeline; P7→doc the real layering.

---

## 4. Testability

- **Parity tests (the headline guarantee):** for a fixed input table (a YouTube
  URL, an X post, an Amazon product, a WSJ paywall, a plain article, an `fbrpc://`
  wrapper, a `mailto:` junk URL), assert `IngestPipeline.process` returns the SAME
  `Outcome` regardless of `source`. Today `ArticleIngestDeciderTests` only covers the
  decider subset; extend to the full pipeline so the YouTube/platform gate parity is
  enforced (it currently is NOT — the gate lives outside the tested decider).
- **Timeout test:** inject a `PipelineDeps` whose fetcher/renderer never returns;
  assert `process` resolves to `.failed` within `timeout`. No surface can hang.
- **Outcome→UI mapping tests:** each `OutcomePresenter` is a protocol with a mock —
  feed every `Outcome` case and assert the right VC/notification is produced
  (e.g. `.video` → `SavedNonTextualViewController`, never `ReaderViewController`;
  `.failed` in share ext → error state, never the "Saved" checkmark).
- **Edge cases to lock in:** non-http typed paste rejected before save; incoming
  friend-share dedup happens exactly once; `.product` interactive-source policy
  (notification fires for paste/manual/appIntent, silent for shareSheet/friendShare/
  email).

---

## Recommended snippet — entry + outcome + presenter

```swift
// ── Shared core (ReaderKit, extension-safe) ──────────────────────────────
struct IngestInput { let url: URL; let source: CaptureSource
                     let prefetchedHTML: String?; let forceArticle: Bool }

enum Outcome {
    case article(ArticleContent, html: String)
    case product(ProductInfo, html: String)
    case social(ContentPlatform, itemID: String?)
    case video(youTubeVideoID: String)
    case audio(ContentPlatform, MediaItemKey)
    case document(DocumentType)
    case needsArchive(title: String)
    case failed
}

enum IngestPipeline {
    /// ALWAYS returns within `timeout`; classifies EVERYTHING (video/social/
    /// document gated before any render or extraction). Identical for all surfaces.
    static func process(_ input: IngestInput,
                        timeout: Duration = .seconds(25),
                        deps: PipelineDeps = .live) async -> Outcome { /* … */ }
}

// ── Per-surface presenter (thin) ─────────────────────────────────────────
protocol OutcomePresenter {
    /// Renders every Outcome case; never leaves a spinner. Exhaustive (no default).
    func present(_ outcome: Outcome, for item: ReadingListItem)
}

// ── Every surface, identical call ────────────────────────────────────────
let outcome = await IngestPipeline.process(input)   // bounded; same decision
presenter.present(outcome, for: item)               // surface differs ONLY here
```
