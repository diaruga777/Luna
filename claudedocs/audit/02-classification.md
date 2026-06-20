# Audit 02 — Determination / Classification Stage

**Scope:** After a URL is unwrapped (Apple News / Google News / shorteners → real
publisher URL), decide **WHAT it is** — article, product, social/platform link,
video, music/podcast, document — and whether it's paywalled. This is *determination*.
Text/price/social extraction and paywall *bypass* are later *processing* stages and
are deliberately out of scope here.

**Verdict:** There is **no single classifier**. Classification is split across ~6
types and re-assembled differently at each input surface. The piece named "the
decider" (`ArticleIngestDecider`) only distinguishes **article / product / paywall**
— it *cannot name* video, platform, music, podcast, or document. Those three kinds
(document → youtube → platform) are gated **before** the decider, by hand, in the
main-app ingestor, and re-gated (partially, differently) in the share controller.
Determination is also tangled with processing: the decider **fetches HTML**, **runs
the price fetcher** (network + WKWebView), and **runs the silent bypass strategies**
before it will return a kind.

---

## 1. Current-state map

### 1a. The classifiers that exist

| Classifier | File | Pure? | Returns | Kind(s) it can name |
|---|---|---|---|---|
| `YouTubeURL.videoID` | `ReaderKit/YouTubeURL.swift` | ✅ pure | `String?` (video id) | youtube only |
| `PlatformClassifier.classify` | `ReaderKit/PlatformClassifier.swift` | ✅ pure | `PlatformClassification?` | youtube, x, bluesky, reddit, tiktok, instagram, facebook, music, podcast |
| `NonTextualContent.detect` | `ReaderKit/NonTextualContent.swift` | ✅ pure (wraps `PlatformClassifier`) | `NonTextualContent?` | youtube + platform (rendering-oriented wrapper) |
| `PlatformRegistry.detect` | `Clip/Platforms/PlatformRegistry.swift` ⚠️ **main-app only** | ✅ pure (wraps `PlatformClassifier`) | `PlatformMatch?` | same as `PlatformClassifier` |
| `ReadingListItem.isDocument` | `ReaderKit/ReadingListItem.swift` | ✅ pure (flag) | `Bool` | document (set at save time, not URL-derived) |
| `ProductPageDetector.detect` | `ReaderKit/ProductPageDetector.swift` | ✅ pure (HTML in) | `ProductCandidate?` | product (Tier-1 structured + Tier-2 heuristic) |
| `PaywallDetector` | `ReaderKit/PaywallDetector.swift` | ✅ pure (text/HTML in) | `Bool` | paywall (content markers + schema.org lock) |
| `ArticleFetcher.isHardPaywallHost` / `.isArchiveTodayURL` | `ReaderKit/ArticleFetcher.swift` | ✅ pure | `Bool` | hard-paywall host list (22 hosts) / archive snapshot |
| `BypassGate.decision` | `ReaderKit/BypassGate.swift` | ✅ pure (HTML+extracted in) | `Decision` | re-derives platform/product/article/paywall to *gate bypass* |
| `ArticleIngestDecider.decide` | `ReaderKit/ArticleIngestDecider.swift` | ❌ **impure** (fetch + price + bypass) | `ArticleIngestDecision` | article / priceTracker / needsArchive / failed |

Note the **fan-out**: `PlatformClassifier` is the actual authority, but it's reached
through three different wrappers (`NonTextualContent`, `PlatformRegistry`, and direct
calls), and a *fourth* re-derivation lives inside `BypassGate`.

### 1b. The order, and WHERE it runs

There is no shared ordering. Each surface re-implements the sequence:

**Main app — `ReadingListIngestor.ingest`** (`Clip/ReadingList/ReadingListIngestor.swift:37`):
```
unwrap aggregator (NewsAggregatorUnwrapper)         line 66
1. document?      item.isDocument        → ingestDocument        line 89   ← gated HERE, not in decider
2. youtube?       YouTubeURL.videoID     → ingestYouTubeVideo    line 101  ← gated HERE, not in decider
3. platform?      PlatformRegistry.detect→ ingestPlatformItem    line 110  ← gated HERE, not in decider
   (re-save dedup short-circuit for already-tracked URLs)        line 125
4. ArticleIngestDecider.decide(...)                              line 151
      ├ product detection (fetch HTML + price fetch)  → .priceTracker
      ├ ArticleResolver.resolve (direct + gated bypass) → .article
      └ paywall/host → .needsArchive / .failed
```

**Share / Action extensions — `ShareViewController.routeSavedOrReader`** (`ShareKit/ShareViewController.swift:273`):
```
unwrap aggregator                                                line ~262
NonTextualContent.detect (youtube + platform, NO document, NO product) line 279/288
   ├ non-textual → autoDownload (share) / SavedNonTextualVC (action)
   └ else → ingestArticleThenComplete (share)  OR  ShareReaderViewController (action)
              └ ArticleIngestDecider.decide(...)                 ReaderVC line 82
```

**Action-extension in-sheet reader — `ShareReaderViewController.ingestAndPresent`** (`ShareKit/ShareReaderViewController.swift:82`):
```
ArticleIngestDecider.decide(...)   ← article/product/paywall ONLY
```

**Action extension entry** (`Clip Action Extension/`): contains **no Swift
classification** — only `GetURL.js` (a JS preprocessing file that hands Safari's page
URL to `ShareViewController`). All its classification is inherited from
`ShareViewController` / `ShareReaderViewController`.

### 1c. The divergences (where surfaces disagree)

1. **The "decider" is not a classifier of kinds.** `ArticleIngestDecider` only
   emits `article / priceTracker / needsArchive / failed`. Video, platform, music,
   podcast, and document are **invisible to it**. They only get classified because
   each caller manually checks for them *first*.

2. **Document classification exists in exactly one place.** Only
   `ReadingListIngestor` (line 89) checks `item.isDocument`. The share controller's
   `NonTextualContent.detect` does **not** know about documents (it wraps
   `PlatformClassifier`, which is URL-only). Documents arrive through a separate
   `handleDocument` provider path in the share extension, so this happens to work —
   but the **kind** "document" is not part of any unified classification result.

3. **Platform gating uses two different wrappers.** Main app uses
   `PlatformRegistry.detect`; the share controller uses `NonTextualContent.detect`.
   Both delegate to `PlatformClassifier`, so they agree *today* — but
   `PlatformRegistry` lives in **`Clip/` (main-app target only)** and violates the
   dependency rule that shared classification should live in `ReaderKit/`. The
   extensions literally **cannot** use `PlatformRegistry`.

4. **Product is classified differently per surface.** Main app + both reader paths
   run product detection *inside* `ArticleIngestDecider`. The zero-UI **share
   extension's** `routeSavedOrReader` (line 279) checks only `NonTextualContent` then
   calls `ingestArticleThenComplete` — product detection happens later, again inside
   the decider. The header comment in `ShareReaderViewController` (line 80) explicitly
   documents that the action-extension reader *used to skip the gate entirely* — a
   bug that unification of the decider fixed, evidence this surface has drifted before.

5. **`BypassGate` re-derives everything a fourth time.** To decide whether a bypass
   may run it independently calls `PlatformClassifier.classify`,
   `ProductPageDetector().detect`, `extracted.hasReadableBody`,
   `PaywallDetector.htmlDeclaresLocked`, `isHardPaywallHost`, `isArchiveTodayURL`
   (`BypassGate.swift:82-136`). This is the *same* classification logic the decider
   needs, computed again in a different order, for a different purpose.

6. **Paywall determination is smeared across 3 types.** `PaywallDetector` (markers +
   schema lock) + `ArticleContent.hasReadableBody`/`looksPaywalled` (length + paywall
   text) + `ArticleFetcher.hardPaywallHosts` (a 22-host allowlist). "Is this
   paywalled?" has no single entry point.

---

## 2. Problems

**P1 — No single source of truth for "what is this?"** Five+ classifiers, three
wrappers over one of them, and a sixth re-derivation in `BypassGate`. A new surface
(e.g. incoming mail, app-intent save) must re-assemble the order by hand and *will*
miss a kind (documents already missing from the share path; only saved by luck of the
provider routing).

**P2 — Determination is fused with processing & I/O.** `ArticleIngestDecider.decide`
fetches HTML, runs the **price fetcher** (static → embedded JSON → **WKWebView
render**), and runs **silent bypass strategies** before it returns. You cannot ask
"what kind is this URL/HTML?" without paying for a full network + render pipeline.
This is why classification can't be unit-tested as a pure function and why the
extensions (memory-limited) run a heavyweight path just to *name* the content.

**P3 — Kind coverage is asymmetric.** The decider knows article/product/paywall;
the callers know video/platform/document. No type in the system can return *all*
kinds. The result type `ArticleIngestDecision` can't even represent "this is a
YouTube video" — so video can never flow through the unified path.

**P4 — Ordering is implicit and duplicated.** The "document → youtube → platform →
(dedup) → resolve" order is encoded as a sequence of `if`/`guard return` statements
in `ingest` (lines 89-151) and a *different* sequence in `routeSavedOrReader`. Order
correctness (e.g. youtube before generic platform; product before paywall) is not
expressed anywhere as data — it's load-bearing control flow in two files.

**P5 — Non-extensible hardcoded checks scattered by host.** "Known sites" are
fragmented:
- hard-paywall hosts: a 22-entry `Set<String>` in `ArticleFetcher` (`:160`)
- archive.today hosts: a `Set<String>` in `ArticleFetcher` (`:91`)
- youtube hosts: a `Set<String>` in `YouTubeURL` (`:11`)
- per-platform host matching: inlined `matches(host, "x.com", "twitter.com")` etc.
  in `PlatformClassifier` (`:40-107`)
- amazon TLD→currency: a tuple list in `ProductPageDetector` (`:221`)

There is **no shop/news host list at all** — Amazon/Target/Walmart and NYT/WaPo/WSJ
are only caught *heuristically* (product score, or hard-paywall set), never by a
fast deterministic "this host is a shop / this host is a news site" lookup. Adding a
new known shop means editing detector scoring; adding a news site means editing the
paywall set. None of it is a single extensible table.

**P6 — False-positive surface.** `ProductPageDetector.hasAddToCartAffordance` scans
raw HTML for the substring `"addToCart"` *anywhere* (`:284`) and `hasRatingSignal`
scans for `"ratingValue"`/`"out of 5"` anywhere (`:294`) — an article *about*
shopping, or a page with a reviews widget, can score 2 and be misclassified a
product. Because product detection runs *before* article resolution in the decider,
a false product positive **silently suppresses the article** and creates a bogus
price tracker. A deterministic shop-host list would let real shops bypass the fuzzy
scorer entirely (fewer heuristic calls = fewer false positives).

**P7 — `PlatformRegistry` in the wrong target.** It's in `Clip/`, unusable by
`ReaderKit/` consumers and extensions, directly contradicting CLAUDE.md's
"`shared/` must not import from `clipper/`; extensions must not import from `clipper/`."

---

## 3. Proposed simplified design

### Principle

**Determination = a pure function `(URL, HTML?) → ContentKind`.** It returns the kind
plus the minimal evidence that named it, and **does no fetching, no price resolution,
no bypass, no WKWebView**. Processing (text extraction, price fetch, social media
resolve, paywall bypass/archive) reads the kind and runs *afterward*, in a separate
stage. One classifier; every surface calls it identically.

### Two phases, in strict order

1. **Deterministic list match (fast, URL-only, no HTML required).** Match the final
   (already-unwrapped) URL against an **extensible `[KnownSite]` table** mapping host
   patterns → kind. Longer lists are strictly better here. This catches the bulk of
   real-world saves with zero network and zero heuristics:
   - shops: `amazon.*`, `target.com`, `walmart.com`, `bestbuy.com`, `ebay.*`,
     `etsy.com`, `wayfair.com`, `homedepot.com`, `lowes.com`, `costco.com`,
     `ikea.com`, `shopify`-pattern `/products/`, `bunnings.com.au`, …
   - news: `nytimes.com`, `washingtonpost.com`, `wsj.com`, `ft.com`, `economist.com`,
     `bloomberg.com`, `smh.com.au`, `theage.com.au`, `theguardian.com`,
     `bbc.com`, `reuters.com`, `apnews.com`, … (carrying a `paywall:` flag for the
     hard-paywall subset)
   - social/video/audio: youtube/x/twitter/instagram/tiktok/facebook/bluesky/reddit/
     spotify/music.apple/podcasts.apple (this *replaces* the inlined `if` ladder in
     `PlatformClassifier` with table rows).

2. **Heuristics (only when the table is undetermined).** Parse HTML
   words/phrases/structure/JSON/async: `ProductPageDetector` Tier-2 scoring,
   `PaywallDetector` markers + schema lock, `ArticleContent.hasReadableBody`. These
   run **only** for hosts not already named by the table, sharply shrinking the
   false-positive surface (P6) and the work the memory-limited extensions do.

### Swift types

```swift
/// The single classification result. Exhaustive over every kind a saved URL can be.
/// Carries only the *minimal evidence* that named the kind — never extracted content,
/// never a fetched price, never bypass state (those belong to the processing stage).
enum ContentKind: Equatable {
    case article                                  // ordinary readable web article
    case paywalledArticle(hardHost: Bool)         // known-locked; hardHost ⇒ archive-CAPTCHA route
    case product(ProductSignal)                   // shop page; signal = how it was named
    case social(ContentPlatform, itemID: String?) // x / bluesky / reddit / tiktok / instagram / facebook
    case video(ContentPlatform, itemID: String)   // youtube (today; vimeo/… later)
    case audio(ContentPlatform, MusicProvider?, itemID: String?) // music / podcast
    case document(type: String)                   // imported file (pdf/epub/…)
    case undetermined                             // table miss + heuristics inconclusive
}

/// How a product page was named — deterministic table hit vs. fuzzy heuristic score.
/// Lets the processing stage trust a table hit and re-confirm a heuristic hit.
enum ProductSignal: Equatable { case knownShopHost, structuredData, heuristicScore(Int) }

/// One row of the EXTENSIBLE deterministic table. Adding a site = appending a row.
/// `match` is host-suffix based (so subdomains and `www.` are covered); an optional
/// `path` predicate handles `/products/<slug>` (Shopify) or `/r/<sub>/comments/` (Reddit).
struct KnownSite {
    let hosts: [String]                      // e.g. ["nytimes.com"], ["amazon."], ["x.com","twitter.com"]
    let path: ((/* segments */ [String]) -> Bool)?   // nil ⇒ host alone decides
    let kind: (URL) -> ContentKind           // closure so it can pull the itemID from the URL
}

/// THE classifier. Pure, dependency-free, lives in ReaderKit so the main app AND
/// every extension share one implementation. Optional `html` enables the heuristic
/// phase; with html == nil only the deterministic table runs (URL-only classification,
/// e.g. for the share extension's first-glance routing before any fetch).
enum Classifier {
    /// Deterministic table FIRST, then HTML heuristics only when undetermined.
    static func classify(url: URL, html: String? = nil, documentType: String? = nil) -> ContentKind {
        if let type = documentType { return .document(type: type) }     // explicit save-time flag wins
        if let hit = knownSites.first(where: { $0.matches(url) }) {       // ① deterministic
            return hit.kind(url)
        }
        guard let html else { return .undetermined }                     // URL-only caller stops here
        return heuristicKind(url: url, html: html)                       // ② heuristics
    }

    /// The extensible table. APPEND rows to teach the classifier a new site — no
    /// control-flow edits, no detector changes. Ordered: video/social/audio first
    /// (most specific), then shops, then news (paywall flag), so overlaps resolve
    /// deterministically.
    static let knownSites: [KnownSite] = youTubeSites + socialSites + audioSites
                                        + shopSites + newsSites
}
```

`heuristicKind` is where today's `ProductPageDetector` (Tier-2),
`PaywallDetector`, and `hasReadableBody` get called — *unchanged logic*, just moved
behind the table and returning a `ContentKind` instead of three separate booleans.

### How the table is extended

Adding *target.com* as a shop, *smh.com.au* as a paywalled news site, or *vimeo* as
a video platform is a one-line append to the relevant `…Sites` array:

```swift
let shopSites: [KnownSite] = [
    .init(hosts: ["amazon."],  path: nil, kind: { _ in .product(.knownShopHost) }),
    .init(hosts: ["target.com","walmart.com","bestbuy.com","ikea.com"], path: nil,
          kind: { _ in .product(.knownShopHost) }),
    // append here ↑
]
let newsSites: [KnownSite] = [
    .init(hosts: ["wsj.com","ft.com","nytimes.com","economist.com","smh.com.au"],
          path: nil, kind: { _ in .paywalledArticle(hardHost: true) }),
    .init(hosts: ["theguardian.com","bbc.com","reuters.com","apnews.com"],
          path: nil, kind: { _ in .article }),    // free news → fast-path to article, skip heuristics
]
```

This **subsumes** the four scattered host sets (P5): `hardPaywallHosts`,
`archiveTodayHosts`, `youtubeHosts`, and the inlined platform `matches(...)` calls all
become rows in one table.

### One classifier, used identically by every surface

```swift
// Main-app ingestor (replaces lines 89–151):
switch Classifier.classify(url: url, documentType: item.documentType) {
case .document(let t):                 await ingestDocument(item, type: t)
case .video(_, let id):                await ingestYouTubeVideo(item, videoID: id)
case .social(let p, let id), .audio(let p, _, let id):
                                       await ingestPlatformItem(item, platform: p, id: id)
case .product, .article, .paywalledArticle, .undetermined:
    // PROCESSING stage: only NOW do we fetch HTML, re-classify with html for
    // undetermined/product confirmation, fetch price, resolve article, run bypass.
    await runWebProcessing(item, url: url, forceArticle: forceArticle)
}

// Share extension & action-extension reader: identical first switch. The only
// difference stays where it belongs — PRESENTATION (save-and-close vs in-sheet reader
// vs SavedNonTextualVC vs archive CAPTCHA), driven off the same ContentKind.
```

The heavyweight `ArticleIngestDecider` shrinks to the **processing** half:
"given a URL the classifier marked article/product/paywall/undetermined, fetch +
resolve + price + gate and return what to persist." Determination no longer fetches.

---

## 4. Testability

Classification becomes a **pure function over fixtures** — `(url, html?) →
ContentKind` — with no mocks, no network, no WKWebView, no actor hops. The existing
pure detectors (`PlatformClassifier`, `ProductPageDetector`, `PaywallDetector`,
`YouTubeURL`) already prove the inputs are fixture-friendly; the win is one table of
assertions instead of testing five types and re-asserting their orchestration per
surface.

**Deterministic-phase cases (URL only, no HTML):**

| Input | Expected `ContentKind` |
|---|---|
| `amazon.com/dp/B09…`, `amazon.com.au/…`, `target.com/p/…`, `walmart.com/ip/…` | `.product(.knownShopHost)` |
| `nytimes.com/2026/…`, `washingtonpost.com/…`, `wsj.com/articles/…`, `ft.com/content/…`, `smh.com.au/…` | `.paywalledArticle(hardHost: true)` |
| `theguardian.com/…`, `bbc.com/news/…`, `reuters.com/…` | `.article` (free-news fast path) |
| `youtube.com/watch?v=ID`, `youtu.be/ID`, `m.youtube.com/shorts/ID` | `.video(.youtube, itemID: "ID")` |
| `x.com/u/status/123`, `twitter.com/u/status/123` | `.social(.x, itemID: "123")` |
| `instagram.com/reel/abc`, `tiktok.com/@u/video/123`, `bsky.app/profile/a/post/x`, `reddit.com/r/s/comments/id` | `.social(.instagram/.tiktok/.bluesky/.reddit, …)` |
| `open.spotify.com/track/…`, `music.apple.com/…` | `.audio(.music, .spotify/.apple, …)` |
| `open.spotify.com/episode/…`, `podcasts.apple.com/…` | `.audio(.podcast, …)` |
| unknown blog host, URL only | `.undetermined` (defers to heuristics) |

**Heuristic-phase cases (HTML required, host not in table):**

| Fixture | Expected |
|---|---|
| unknown-shop HTML with JSON-LD `Product` + `offers.price` | `.product(.structuredData)` |
| unknown-shop SPA, no structured price, `og:type=product` + `/products/slug` + `addToCart` | `.product(.heuristicScore(≥2))` |
| article that merely *mentions* shopping (single stray `addToCart`, no other signal) | `.article` — **regression guard for P6** |
| HTML with `"isAccessibleForFree":false` or `article:content_tier=locked` | `.paywalledArticle(hardHost: false)` |
| long readable body, no markers | `.article` |
| short body + "subscribe to continue" gate marker | `.paywalledArticle(hardHost: false)` |

**Parity guard:** one test asserting `Classifier.classify` returns the *same*
`ContentKind` regardless of the calling surface (the bug class that
`ArticleIngestDeciderTests` partially covers today, generalized to all kinds).

---

## Recommended `ContentKind` + classifier API

```swift
/// The one classification result for a saved URL. Exhaustive over every kind, so
/// no surface can "forget" a kind (the compiler forces the switch to handle each).
/// Carries minimal evidence only — extraction/price/bypass are a later stage.
enum ContentKind: Equatable {
    case article
    case paywalledArticle(hardHost: Bool)
    case product(ProductSignal)
    case social(ContentPlatform, itemID: String?)
    case video(ContentPlatform, itemID: String)
    case audio(ContentPlatform, MusicProvider?, itemID: String?)
    case document(type: String)
    case undetermined
}

enum ProductSignal: Equatable { case knownShopHost, structuredData, heuristicScore(Int) }

/// One extensible row: append to teach the classifier a new site. Host-suffix match
/// (covers subdomains + www); optional path predicate for /products/, /r/…/comments/, etc.
struct KnownSite {
    let hosts: [String]
    let path: (([String]) -> Bool)?
    let kind: (URL) -> ContentKind
    func matches(_ url: URL) -> Bool { /* host-suffix + optional path */ }
}

/// THE classifier — pure, dependency-free, in ReaderKit, used identically by the
/// main app + share + action extensions. Deterministic table FIRST, heuristics only
/// when undetermined. No fetch, no price, no bypass, no WKWebView.
enum Classifier {
    static func classify(url: URL, html: String? = nil, documentType: String? = nil) -> ContentKind
    static let knownSites: [KnownSite]   // youTube + social + audio + shop + news rows
}
```

**Migration shape:** keep `PlatformClassifier`, `ProductPageDetector`,
`PaywallDetector`, `YouTubeURL` as the *implementation* of table rows + the heuristic
phase (don't rewrite their logic). Collapse the four scattered host sets
(`hardPaywallHosts`, `archiveTodayHosts`, `youtubeHosts`, inlined platform `matches`)
into `knownSites`. Move `PlatformRegistry`'s classification half into `ReaderKit`
(P7); leave its *rendering* `module(for:)` in `Clip/`. Strip fetch/price/bypass out of
`ArticleIngestDecider`, leaving it as the **processing** stage that consumes a
`ContentKind` — restoring the determination ⟂ processing separation the owner wants.
