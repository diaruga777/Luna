# Audit 03 — Article Text Extraction

Scope: the processing step that turns a URL already classified as a readable article
into clean `ArticleContent`. Files:
`ReaderKit/ArticleResolver.swift`, `ArticleExtractor.swift`, `ArticleContent.swift`,
`ArticleFetcher.swift`, plus the supporting `PaywallDetector`, `BypassRunner`,
`BypassStrategySelector`, `BypassStrategy`, `BypassGate`. Tests:
`ArticleExtractorTests`, `ArticleResolverTests`, `ArticleContentPaywallTests`.

READ-ONLY audit. No code was changed.

---

## 1. Current-state map

### Pipeline entry points (the "run identically across surfaces" claim)

`ArticleIngestDecider.decide(...)` is the single shared routine. It is called by the
main-app ingestor, `ReplayPlayer`, and the share extensions. Order:

1. **Product detection** (`ProductPageDetector` + `PriceFetcher`) → `.priceTracker`, else fall through.
2. **`ArticleResolver.resolve(...)`** → `ArticleResolution`.
3. **Map** resolution → `ArticleIngestDecision` (`.article` / `.needsArchive` / `.failed`).

So the *classifier* (is this a product / platform / article) lives partly in the
decider and partly in `BypassGate`; the *extraction + bypass* live in the resolver.

### `ArticleResolver.resolve` flow (the focus)

```
resolve(url, prefetchedHTML?, fetcher, extractor, runner?, replayLog?)
 ├─ direct = extractedContent( prefetchedHTML ?? fetcher.fetchHTML(url) )   # fetch + extract
 ├─ if isReadable(direct)  → .readable                                       # early exit
 ├─ strategies = BypassStrategySelector.strategies(for: url, directHTML)     # pure policy
 ├─ for strategy where runsSilently:                                         # bypass loop
 │     pair = BypassRunner.run(strategy, url, directHTML)                    #   fetch + extract
 │     if isReadable(pair) → .readable                                       #   first win returns
 ├─ archived = extractedContent( fetcher.fetchArchivedHTML(url) )            # legacy last silent attempt
 └─ resolution(direct, archived)                                             # pure: readable / paywalled(title) / unreadable
```

`isReadable(pair)` = `pair.0.hasReadableBody && !PaywallDetector.htmlDeclaresLocked(pair.1)`.

### The UA fallback chain (`ArticleFetcher.fetchHTML(from:)`)

`fetchHTML(from:)` tries **Googlebot UA first**, then on *any* error (except
`tooLarge`/`notHTML`) retries once as **Safari**. `Referer` defaults to
`https://www.google.com/` on every request. Per-strategy fetches
(`userAgent`, `referer`, `freshSession`, `trailingDotHost`, …) bypass this chain and
use a single explicit UA. So there are effectively two UA policies:
the implicit Googlebot→Safari chain for the *direct* read, and explicit single-UA
fetches inside the bypass strategies.

### Extraction (`ArticleExtractor.extract`) — three layers + JSON-LD + raw

1. **refined** — strip chrome by tag/role + ~30 junk-class substrings + visually-hidden
   (clip/1px) elements → `bestContainer` scoring → `extractBlocks` → `trimTrailingJunk`.
2. **basic** — strip structural tags only → `bestContainer` → `extractBlocks`.
3. Layer arbitration: refined chosen if `len≥600` **or** (`len≥350 && refined*3≥basic`);
   else basic; else refined.
4. **JSON-LD** `articleBody` override if it is `> 2×` the chosen text.
5. **raw** — body `.text()` capped at 40k if everything else empty; else throw `.noContent`.

`bestContainer` prefers explicit `articleBody`/CMS-body selectors (≥400 chars), else
Readability-style ancestor scoring with depth≤3 decay, then widens upward until coverage
≥0.6 of document paragraph text. `paragraphLikeElements` treats inline-only
`<div>`/`<section>` as paragraphs (archive.today / React DOMs).

### Readable-vs-paywalled judgment — split across THREE places

| Predicate | Lives in | Inputs |
|---|---|---|
| `hasReadableBody` | `ArticleContent` | `bodyTextLength ≥ 600 && !looksPaywalled` (text only) |
| `looksPaywalled` (text) | `ArticleContent` → `PaywallDetector.textLooksPaywalled` | gate markers any length; weak markers if `< 2500` |
| `htmlDeclaresLocked` | `PaywallDetector` | schema.org `isAccessibleForFree:false`, `content_tier` meta |
| `isReadable(pair)` | `ArticleResolver` (private) | `hasReadableBody && !htmlDeclaresLocked(html)` |

The resolver's `isReadable` is the *real* "is this the article" predicate (it adds the
HTML lock signal), but it is private and duplicated in spirit by `BypassGate` step (3)
(`extracted.hasReadableBody && !htmlDeclaresLocked`).

---

## 2. Problems

### P1 — Extraction is NOT a separate component from bypass (the headline issue)

`ArticleResolver` does four jobs: (a) fetch direct HTML, (b) extract, (c) orchestrate the
silent bypass strategy loop, (d) classify into readable/paywalled/unreadable. Vision
wants extraction to be a pure `HTML → ArticleContent` unit, with bypass as a *separate*
stage that merely supplies candidate HTMLs. Today extraction is reachable only *through*
the resolver and the runner — there is no callable "extract this HTML" entry that also
applies the readable/locked judgment. Both `ArticleResolver.extractedContent` and
`BypassRunner.extracted` are byte-identical private helpers (`fetch → extract → pair`)
— the same fetch+extract+pair logic is written twice.

### P2 — The readable/locked predicate is duplicated and partly private

`isReadable(pair)` (resolver, private) and `BypassGate` step (3) both compute
`hasReadableBody && !htmlDeclaresLocked(html)`. `hasReadableBody` itself bakes in
`!looksPaywalled` but *without* the HTML signal, so callers that have the HTML must
remember to AND in `htmlDeclaresLocked` themselves. There is no single public
`isReadableArticle(content, html)` predicate — it is reinvented at each call site. This
is exactly the "one well-tested pure predicate" the vision asks for, currently absent.

### P3 — Two `looksPaywalled` surfaces with different power

`ArticleContent.looksPaywalled` is text-only and silently weaker than
`PaywallDetector.looksPaywalled(content:html:)`. A caller holding the HTML who reaches
for the convenience `content.looksPaywalled` gets the weaker check and a potential false
negative (a wall whose CTA text the extractor stripped, but whose schema.org lock is
present). The doc comment warns about this, but the type does not enforce it — invalid
usage is representable.

### P4 — Googlebot-UA-first is a non-determinism / correctness risk

The direct read sends a Googlebot UA first and only falls back to Safari on error. This
means the *bytes the extractor sees depend on what the server decides to serve a bot*,
which can differ run-to-run (A/B, geo, bot-verification, rate limits) and differs from
what a logged-in/normal reader sees. Consequences:

- The "is this paywalled" judgment is computed over crawler-served HTML, not
  reader-served HTML — a soft paywall that serves crawlers full text reads as
  `.readable` for us but as walled for the user, and vice-versa.
- `tooLarge`/`notHTML` are special-cased to *not* retry "for determinism", which is an
  admission that the rest of the chain is non-deterministic.
- The same Googlebot string is hardcoded in two places: `ArticleFetcher.googlebotUserAgent`
  and `CrawlerAgent.googlebotDesktop.userAgent` (duplication, can drift).

### P5 — Extractor layer arbitration is magic-number heavy and hard to reason about

The thresholds `600`, `350`, `refined*3 >= basic`, `ldBody > 2 × chosen`,
`paragraphTextLength ≥ 400`, `coverage < 0.6`, depth `< 3`, `>20`-char gates,
`linkDensity > 0.7 && <400`, `<200` junk-phrase length, image `<140`px, `40_000` cap,
`>200` JSON-LD body — none are named constants. They are individually defensible (and
the comments justify them well) but collectively they make the layer choice a black box
that only the comment explains. `readableBodyThreshold = 600` is a named constant in
`ArticleContent` yet the *same* 600 appears un-named in `ArticleExtractor` line 46 — a
coincidental coupling that will drift.

### P6 — `fetchArchivedHTML` is a legacy fifth wheel beside the strategy list

The strategy list already contains `.waybackRaw` and (WKWebView) `.archiveToday`, yet
`resolve` runs a *separate* `fetchArchivedHTML` (Wayback-available-API then
archive.ph/newest) after the loop. This is a second, older archive path that overlaps the
strategy-driven one. Its comment even calls it "legacy". It is dead-ish weight: another
fetch+extract that duplicates what `.waybackRaw` already attempted, on a different
Wayback endpoint.

### P7 — `ArticleResolution.==` is hand-written and lossy

Equality compares only `title`, `bodyTextLength`, and `html` for the `.readable` case —
two different block arrays with the same title+length+html compare equal. Tests rely on
this, but it means the `Equatable` conformance silently isn't structural. `ArticleContent`
is already `Equatable`; the custom operator exists only because the tuple carries `html`.
A small struct (below) makes the synthesized `==` correct and removes the hand-written one.

### P8 — `(ArticleContent, String)` tuple is passed everywhere

The "content + winning HTML" pair is an unnamed tuple in the resolver, the runner, and
`BypassRunning.run`'s return type. It is exactly the "two optionals always present
together" case the project's own type-safety rule says to wrap in a struct. A named
`ExtractedArticle { content; sourceHTML }` would document intent and let `isReadable`
hang off it as a property.

### P9 — `hasReadableBody`'s false-negative window

`looksPaywalled` flags a **gate marker at any length**. A legitimately long article that
quotes a paywall notice ("the site told readers to *subscribe to continue*…") is flagged
as a wall regardless of length. The weak-marker list is length-gated (`< 2500`) but the
gate-marker list is not. This is a deliberate precision/recall trade, but it is
untested for the long-article-quoting-a-gate-phrase case — the only long-body test
(`testLongArticleMentioningSubscribe…`) uses the word "subscribe", not a full gate
phrase, so the risk is unguarded.

---

## 3. Proposed simplified design

Split the resolver's four jobs into composable stages. Extraction becomes a pure unit;
bypass becomes an orchestrator that *feeds* it candidate HTMLs.

### Stage boundaries

```
classify (BypassGate / decider)  →  .article
        │
        ▼
Stage 3: ArticleExtraction        HTML(+baseURL) → ExtractedArticle?      (pure, no I/O)
        │  (also the readable/locked predicate)
        ▼
Stage 4: BypassOrchestrator       supplies candidate HTMLs (direct, then  (I/O; SEPARATE)
                                  silent strategies, then archive), each
                                  handed to Stage 3 until one is readable
```

Key inversion: **Stage 4 owns "where HTML comes from", Stage 3 owns "HTML → content +
is-it-readable".** The resolver shrinks to a thin driver that asks Stage 4 for the next
candidate and Stage 3 whether it's good enough.

### A. The pure extraction component (Stage 3)

```swift
/// content + the source HTML it came from, always present together.
struct ExtractedArticle: Equatable {
    let content: ArticleContent
    let sourceHTML: String
}

/// Pure HTML → ArticleContent. No network. The ONLY place that turns markup into blocks.
struct ArticleExtraction {
    /// Parse `html` into structured content. Throws `.noContent` only when truly empty.
    func extract(html: String, baseURL: URL) throws -> ArticleContent      // = today's extract
    /// JSON-LD-only path (for the `.jsonLDBody` strategy). Pure.
    func extractFromJSONLD(html: String, baseURL: URL) -> ArticleContent?  // unchanged

    /// THE single readable predicate (replaces resolver.isReadable + BypassGate step 3 +
    /// the implicit !looksPaywalled inside hasReadableBody). One well-tested pure func.
    static func isReadableArticle(_ content: ArticleContent, html: String?) -> Bool {
        content.bodyTextLength >= ArticleContent.readableBodyThreshold
            && !PaywallDetector.looksPaywalled(content: content, html: html)
    }
}
```

Move `hasReadableBody`/`looksPaywalled` *out* of `ArticleContent` (leave only
`bodyTextLength`/`wholeText` data accessors) so there is exactly one place — and one
HTML-aware signature — that judges readability. `BypassGate` step (3) and the resolver
both call `ArticleExtraction.isReadableArticle`.

### B. A deterministic, thin fetch

```swift
protocol HTMLFetching {
    /// Single consistent UA (Safari), one Referer policy. Deterministic.
    func fetchHTML(from url: URL) async throws -> String
    // explicit-variant fetches (userAgent/referer/freshSession/wayback/jina) stay —
    // they are EXPLICIT bypass moves, owned by Stage 4, not the default read.
}
```

Make the default `fetchHTML(from:)` use **one** UA (Safari) deterministically. The
Googlebot trick is not lost — it becomes an explicit `.userAgent(.googlebotDesktop)`
*bypass strategy*, which already exists. The direct read then reflects what a normal
reader sees, so the paywall judgment is computed over the right bytes, and re-runs are
reproducible. Collapse the duplicated Googlebot string to `CrawlerAgent`'s copy.

### C. Bypass orchestration as a separate stage (Stage 4)

```swift
/// Yields candidate source HTMLs to try, in order, for a paywalled/unreadable page.
/// Pure policy (BypassStrategySelector) + I/O (BypassRunner) — but it NEVER decides
/// "readable"; it only produces HTML. Stage 3 judges each candidate.
struct BypassOrchestrator {
    let selector = BypassStrategySelector.self
    let runner: BypassRunning

    /// Run silent strategies in order; for each, hand its HTML to `accept` and stop at
    /// the first the extractor accepts. `accept` is ArticleExtraction.isReadableArticle.
    func firstReadable(
        url: URL, directHTML: String?,
        extract: (String, URL) -> ArticleContent?,
        accept: (ArticleContent, String) -> Bool,
        log: ((EventKind) async -> Void)?
    ) async -> ExtractedArticle?
}
```

`BypassRunner` already maps a strategy to an `HTMLFetching` call and extracts; the only
change is that it should return *candidate HTML* and let the orchestrator apply the
shared `accept` predicate, instead of re-implementing extraction (kills P1's duplicate
`extracted` helper). Fold the legacy `fetchArchivedHTML` (P6) into the strategy list as
it already nearly is — `.waybackRaw` + a `.archiveTodayURLSession` case — so there is one
archive path, not two.

### D. The shrunken resolver (driver only)

```swift
enum ArticleResolver {
    static func resolve(url: URL, prefetchedHTML: String? = nil, …) async -> ArticleResolution {
        let extraction = ArticleExtraction()
        let directHTML = prefetchedHTML ?? (try? await fetcher.fetchHTML(from: url))
        // Stage 3 on the direct candidate.
        if let html = directHTML, let c = try? extraction.extract(html: html, baseURL: url),
           ArticleExtraction.isReadableArticle(c, html: html) {
            return .readable(ExtractedArticle(content: c, sourceHTML: html))
        }
        // Stage 4 supplies candidates; Stage 3 judges each.
        if let win = await orchestrator.firstReadable(
            url: url, directHTML: directHTML,
            extract: { try? extraction.extract(html: $0, baseURL: $1) },
            accept: ArticleExtraction.isReadableArticle, log: replayLog) {
            return .readable(win)
        }
        // Pure title-preservation classification (unchanged `resolution(...)`).
        return ArticleResolver.classify(direct: directHTML, lastSeenTitle: …)
    }
}
```

`ArticleResolution.readable` now carries `ExtractedArticle` (P8), making the
hand-written `==` (P7) unnecessary — `ExtractedArticle: Equatable` synthesizes correctly.

### The readable/paywalled judgment as ONE predicate

`ArticleExtraction.isReadableArticle(_:html:)` is the single, pure, HTML-aware predicate.
Everything else (`hasReadableBody`, resolver `isReadable`, BypassGate step 3) routes
through it. Name the magic `600` once (`ArticleContent.readableBodyThreshold`, already
exists) and have the extractor reference it instead of its own literal `600` (P5).

---

## 4. Testability

Existing tests are good on the *pure* edges (`resolution(...)`, paywall predicates, the
strategy loop via `StubRunner`/`MockArticleFetcher`). Gaps and additions:

### Fixtures — per-site, readable + paywalled-stub variants

Add committed fixtures under `LunaTests/Fixtures/` (the current real-page test reads from
`/tmp` and silently skips when absent — non-deterministic CI coverage, P4-adjacent):

| Site | `…-readable.html` | `…-paywalled.html` |
|---|---|---|
| nytimes.com | full body, server-rendered | lede + `isAccessibleForFree:false` |
| washingtonpost.com | full body | `content_tier=locked` meta + teaser |
| wsj.com | Wayback snapshot w/ comments (already modeled in `testArchivedArticleBeats…`) | personal-non-commercial-use stub |
| smh.com.au | full body | "Subscribe to continue" gate marker |

Each fixture drives two assertions: (1) `ArticleExtraction.extract` yields the right body
(readable variant) and (2) `ArticleExtraction.isReadableArticle` returns the expected
bool for both variants. This is the table that proves the predicate is right per-site.

### Extraction correctness (extend `ArticleExtractorTests`)

- Keep the div-based-body + player-chrome and comment-thread-vs-articleBody tests — they
  exercise the hardest real cases. Re-point them at `ArticleExtraction`.
- Add: long article that *quotes a gate phrase* must stay readable IF length-gated (P9) —
  decide and lock the policy with a test either way.

### The readable predicate (consolidate `ArticleContentPaywallTests`)

- Move the FT-marketing-stub and WSJ-Wayback-teaser cases to assert
  `ArticleExtraction.isReadableArticle(content, html:)` directly (with and without the
  HTML lock signal) so the *one* predicate is the unit under test, not the convenience
  accessors.
- Add the false-negative guard: HTML with `isAccessibleForFree:false` but a long
  stripped body → still not readable (proves the HTML signal can't be bypassed by reaching
  for the text-only path, P3).

### Determinism

With a single-UA direct fetch, a fetcher test can assert the *same* request headers are
sent every call (no Googlebot-first branch), making the direct read reproducible.

---

## Recommended extraction API

```swift
/// Content + the HTML it was extracted from — always present together.
struct ExtractedArticle: Equatable {
    let content: ArticleContent
    let sourceHTML: String
}

/// Stage 3: the ONLY HTML → ArticleContent component. Pure, no I/O, deterministic.
struct ArticleExtraction {
    enum ExtractError: Error { case noContent }

    /// Parse HTML into ordered, link-annotated blocks. Throws `.noContent` only when
    /// the document holds no usable text at all.
    func extract(html: String, baseURL: URL) throws -> ArticleContent

    /// JSON-LD `articleBody`-only extraction, for the `.jsonLDBody` bypass strategy.
    func extractFromJSONLD(html: String, baseURL: URL) -> ArticleContent?

    /// THE single readable-vs-paywall-stub predicate. `html` adds the publisher-declared
    /// schema.org lock signal; pass it whenever the source HTML is available. Pure.
    static func isReadableArticle(_ content: ArticleContent, html: String?) -> Bool {
        content.bodyTextLength >= ArticleContent.readableBodyThreshold
            && !PaywallDetector.looksPaywalled(content: content, html: html)
    }
}
```

Composition: classifier says `.article` → resolver runs `ArticleExtraction.extract` on
the direct HTML and checks `isReadableArticle`; on failure, the **separate**
`BypassOrchestrator` (Stage 4) supplies candidate HTMLs (silent strategies, then one
unified archive path), each judged by the *same* `isReadableArticle`. First acceptance
wins; otherwise the pure `resolution(...)` preserves the best title for the archive
reader. Extraction never knows bypass exists; bypass never judges readability.
