# URL Pipeline — Unified Simplification Plan

Synthesis of the seven stage audits (`01`–`07` in this folder). Goal: one simple,
deterministic-first, composable pipeline; the SAME components on every input surface;
no dead/duplicate code; everything bounded so nothing hangs. This is a **staged
refactor** guarded by the existing 786-test suite + new fixtures — not a greenfield
rewrite.

## Target architecture: 4 stages, run identically on every surface

```
incoming (url + source)
  │
  ├─ STAGE 1  Unwrap        URLUnwrapper           (deterministic / offline-first)
  ├─ STAGE 2  Classify      Classifier → ContentKind   (deterministic list FIRST, heuristics only if undetermined; NO I/O beyond the one page fetch)
  ├─ STAGE 3  Process       one component per kind  (separate from determination)
  │     .article          → ArticleExtraction
  │     .paywalledArticle → BypassPlan → ArticleExtraction
  │     .product          → ProductMetadataExtractor
  │     .social/.video/.audio → PlatformRecognizer (+ best-effort metadata)
  │     .document         → DocumentParser
  └─ STAGE 4  Surface      IngestPipeline.process(IngestInput) → Outcome  (ONE overall timeout)
                            thin per-surface OutcomePresenter (exhaustive; never leaves a spinner)
```

### Stage 1 — `URLUnwrapper` (was `NewsAggregatorUnwrapper`)
- Extensible `[WrapperHandler]` registry: `matcher(url) → .immediate(URL)` (fb/google-classic, offline/sync) or `.fetch(async)` (apple.news, google new-style, shorteners).
- ONE app-wide async `unwrap` + an `unwrapOffline` fast path for input gates. Run **once** per incoming URL at the single shared entry (fixes: paste happy-path `saveNewWithContent` and friend-share that skip unwrap today; the 6 sprinkled fbrpc call-sites collapse to one).
- Strip tracking params (`fbclid`/`utm_*`) here so dedupe/display/share all see clean URLs (was archive-only).

### Stage 2 — `Classifier.classify(url:html?:documentType?:) -> ContentKind`  (pure, ReaderKit)
- Exhaustive `ContentKind`: `.article / .paywalledArticle / .product / .social(Platform) / .video / .audio / .document / .undetermined`.
- Heuristics (HTML words/phrases/structure) run **only** when the table says `.undetermined`.
- Determination does **no** price-fetch / bypass / WebView. Fix `ProductPageDetector`'s loose substring scan (require a structured product signal, not "addToCart" anywhere) to stop false-positive trackers.

### Stage 3 — processing components (each: pure core + bounded I/O, independently tested)
- **`ArticleExtraction`**: `HTML(+baseURL) → ArticleContent`; ONE public `isReadableArticle(content:html:)` predicate (consolidate the 3 duplicate readable/locked checks; pick the strong HTML-aware one). Deterministic single-UA fetch; Googlebot demoted to an explicit bypass strategy (removes run-to-run variance).
- **`ProductMetadataExtractor`**: extensible per-host `ProductPriceRule` table — Amazon (buy-box `priceAmount`/`displayPrice`, NOT the first `.a-offscreen` strikethrough; tighten `isAmazonHost`; TLD→currency), Target/Walmart (`__NEXT_DATA__`), generic JSON-LD/OG/microdata fallback. **Single** price source (kill the detect-then-refetch double parse = "sometimes saves"). Mandatory price in the type; currency per-rule (no silent USD default). **WebView render tier structurally unreachable in extensions** (`render == nil`) — this is the action-extension "spins forever".
- **`PlatformRecognizer`** + best-effort metadata fetch: one `[PlatformRule]` table; recognition separate from the (optional) metadata/thumbnail fetch; **delete the dead per-module `classify`** (modules keep rendering + `metadataFetcher`).
- **`BypassPlan`** orchestrator: build ONE plan `{silent, webPreStages, allowsArchiveToday}` from the per-host rule table; trailing-dot is the FIRST silent strategy; **bounded aggregate deadline**; `benefitsFromJSRetry=false` for trailing-dot so it's never repeated as a ~9s WebView pre-stage; drop the redundant pre-loop Googlebot+Safari fetch, the legacy `fetchArchivedHTML`, and the duplicate Wayback hit (the NYT slowness). Bypass only **supplies candidate HTML** to `ArticleExtraction`; archive.today WKWebView is the bounded last resort. Fold `hardPaywallHosts` into the rule table (single source).

### Stage 4 — `IngestPipeline.process(IngestInput) -> Outcome`
- `IngestInput` carries the `source` (paste/typedURL/actionExtension/shareExtension/appIntent/friendShare). Unified exhaustive `Outcome` (absorbs `NonTextualContent`).
- **ONE mandatory overall timeout** (`withTaskGroup`/`withTimeout`) wrapping the whole call ⇒ nothing can ever hang (action-extension fix). Video/social/document are decided before any render/extraction.
- Thin per-surface `OutcomePresenter` protocol — exhaustive `switch` (no `default`), every case shows real UI, failure/timeout shows an error, **never an infinite spinner**. All 6 surfaces become thin presenters over the same `Outcome`. Fix: typed-input `https://` blind-prefix (validate scheme), double dedup, "Saved" shown on `.failed`, archive-reader wiring copied 3×.

## How this resolves the reported bugs
- **Action-extension spinner-forever** → Stage-4 overall timeout + Stage-3 WebView-unreachable-in-extension + exhaustive presenter.
- **Amazon never a tracker** → buy-box price rule + amazonStaticPrice in detection + single price source + extension-safe static path.
- **NYT too slow** → trailing-dot first silent, no WebView repeat, drop redundant fetches, bounded deadline.
- **Facebook fbrpc** → single shared unwrap entry (offline) on every surface.
- **"3 pastes, 3 results"** → single deterministic price source + sorted traversal (already) + no WebView race in the decision.

## Staged implementation order (serial; verify Debug+Release between) — ALL STAGES DONE
1. **[DONE] Foundation (new pure files):** `ContentKind`, `KnownSite` table, `Classifier`; `URLUnwrapper` registry; `PlatformRecognizer` + `[PlatformRule]`. Keep old types as thin shims temporarily.
2. **[DONE] Processing:** `ArticleExtraction` + single readable predicate; `ProductMetadataExtractor` + `ProductPriceRule` table; `BypassPlan`. Migrate `ArticleResolver` to consume them; delete duplicates.
3. **[DONE] Pipeline + surfaces:** `IngestPipeline` + `Outcome` + `OutcomePresenter`; migrate ingestor, both extensions, intents, friend-share, in-app paste; delete `ArticleIngestDecider`/old gating tangle and dead module `classify`.

## Test matrix (named sites)
- Price: amazon (.com/.com.au), target, walmart → `.product` + buy-box price/currency.
- News: nytimes, washingtonpost, wsj, smh.com.au → `.article`/`.paywalledArticle`; bypass plan ordering; readable predicate on readable + stub fixtures.
- Unwrap: fbrpc Messenger link, apple.news, google news, l.facebook shim, shorteners.
- Parity: every source produces the identical `Outcome` for the same input.
