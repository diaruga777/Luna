# Alternative-seller price comparison

**What it is.** Given a product Luna knows about — one being saved, one already
tracked, one open in Safari — find the SAME product on other retailers' own
sites and read their prices. Not an aggregator lookup and not a scraped price
index: each answer is a real page on a real retailer, fetched now.

**Where the work lives.** `LunaLibraries/Sources/LunaPriceCompare` — a new,
deliberately lean SwiftPM target. Phase B1 ships the engine only; the surfaces
that call it (save-time spinner, App Intents summary document, the Safari pill)
are B2/B3.

---

## Why a separate module

The comparison has to run in four very different places: the app, the
share/action extensions, and the four Safari appexes. The Safari appex is the
binding constraint — `claudedocs/safari-extension.md` documents its ~80MB
ceiling, which is why `LunaMediaResolve` was split out of `LunaMediaDownload` in
the first place. So `LunaPriceCompare` depends on **LunaModels,
LunaURLClassification and LunaPriceMetadata and nothing else**, all
Foundation-only. No SwiftSoup, no UIKit, no LunaFetch.

Two consequences run through the whole design:

1. **Every network call is injected.** The module defines
   `SellerFanOut.Fetch`, `.WebSearch` and `.RichResolve` closures and makes no
   request itself. The app can fetch through `ArticleFetcher` and route
   candidate verification through the entire shared ingest pipeline; the appex
   passes a bare `URLSession` and gets the regex parser. One orchestration, two
   environments.
2. **Small helpers are re-implemented rather than imported.** The URL rule
   tables (`LeanProductURLRules`) are a hand-copy of `ProductPageRules` +
   `ProductPageDetector`'s two URL predicates, pinned by
   `LeanProductURLParityTests`. The identity primitives are NOT copied — they
   were moved DOWN into `LunaModels` as `ProductIdentityMatching`, which every
   tier can share, and `ComparisonMatchingParityTests` pins them to
   `ProductMatcher`/`SnapshotMatcher`'s long-standing copies.

`DuckDuckGoSearch` moved `LunaIntents` → `LunaFetch` for the same reachability
reason: only the four apps link LunaIntents, and the share/action extensions run
the same fan-out.

---

## Keyed identifiers

`PriceTracker.productID` and `ProductInfo.productID` are FLATTENED — one string,
with no record of which kind of id it is. The kinds have completely different
scopes, and a cross-retailer comparison depends on the difference:

| kind | scope | use in comparison |
| --- | --- | --- |
| GTIN / UPC / EAN / ISBN | global | the basis of the whole feature — matches across retailers |
| MPN | manufacturer | usable, but only with a compatible brand |
| SKU | one retailer | meaningless on another host |

So `ProductIdentifiers { gtin, mpn, sku, brand }` (LunaModels) is now carried
alongside the flattened value, from `ProductPageDetector` (JSON-LD **and**
microdata) through `ProductCandidate` → `ProductInfo` → `ProductMetadata` →
`PriceTracker`. The flattened fields are untouched — every persisted tracker has
one and nothing migrated — and `PriceTracker.identifiers` decodes as empty when
absent.

Two deliberate refusals in extraction:

- The unqualified JSON-LD/microdata `productID` key is **never** folded into the
  keyed GTIN slot. The page never states its scope, and promoting it would
  invent cross-retailer evidence.
- JSON-LD identifiers are read **independently of price**, because a per-host
  price rule (Amazon/Target/Walmart) can win the price while JSON-LD remains the
  only place the GTIN is stated.

`ProductMatcher.bestMatch` gained a tier above flattened-id equality: keyed
GTIN, zero-padded to 14 so the same number declared as GTIN-8/12/13/14 matches.

---

## The seller directory

`LunaPriceCompare/Resources/seller-directory.json` — 222 retailers across 9
English-speaking regions, bundled rather than fetched (a network round trip just
to learn *where* to look would spend most of the appex's budget before the first
real request).

```
{ version: 1,
  sellers: [{ id, name, region, domain, searchURL, acceptsGTIN, marketplace,
              categories, tier, verified, searchIsClientRendered? }] }
```

- `searchURL` carries exactly one `{query}` placeholder. It may sit in a query
  VALUE (`?k={query}`) or in the PATH (`/s/{query}` — 11 of them), and those
  escape differently: `+` means "space" only inside a query string. `Seller
  .searchRequestURL(forQuery:)` looks at where the placeholder actually is.
  Everything outside RFC 3986 unreserved is percent-escaped, so a product name
  containing `&`/`?`/`#`/`/` cannot break out of the template.
- `categories` draw from the fixed `SellerCategory` taxonomy; `general` marks a
  mass merchant.
- `tier` is 1 (household name) … 3 (niche).
- `searchIsClientRendered` (optional, additive — an entry written before it
  decodes as `nil`, which reads as "not known to be") marks a shop whose search
  RESULTS are drawn by JavaScript, so the served markup carries no product links
  at all. 31 entries carry it, and each was MEASURED: a live search that returned
  200, no bot wall, and zero extractable product links. Target's US search page is
  123KB and Walmart's 248KB, and neither contains a single product URL.

  Two consumers, and they want opposite things. A static-only context (the Safari
  appex) excludes them at SELECTION — its candidate budget is six, and a slot
  spent on a structurally empty page is one the run never gets back. The full
  profile KEEPS them, because it can render (below). The flag is an observation
  about markup, not a verdict on the retailer.

`SellerDirectory.validate()` returns every structural problem as a line, and
`SellerDirectoryTests` runs it against the SHIPPED file — a hand-edited entry
with a broken template, a duplicate id, an invented category or an off-domain
search host would otherwise just make one retailer silently unreachable.

---

## Candidate selection

`SellerCandidateSelector` — pure, total, deterministic. It runs identically in
the app, the extensions and the appex; a reshuffle between surfaces would make
the same product answer differently depending on where it was saved.

1. **Region.** The source retailer's own region when the directory knows it (an
   `amazon.co.uk` save is a UK shopping trip wherever the phone is), else the
   device region if any storefronts serve it, else `US`.
2. **Categories.** Keyword inference over the page's category hints, breadcrumbs
   and product name. Hints arrive as breadcrumb trails and JSON-LD `category`
   strings, so separators become spaces and every token is ALSO emitted
   de-pluralized — `containsWord` already let a singular keyword fire on a plural
   hint, but never the reverse, so `groceries` could not reach `grocery`. The
   keyword table carries the SHELF words a breadcrumb uses alongside the PRODUCT
   words a title uses; they are rarely the same word. Unioned with
   the source retailer's own directory categories minus `general`. **Empty ⇒
   mass merchants only** — the shops that sell everything, rather than a dozen
   specialists chosen at random.
3. **Score.** tier 1 `+30` / tier 2 `+18` / tier 3 `+8`; `+12` per category
   overlap capped at `+24`; `+10` when `acceptsGTIN` and we have a GTIN; `+4`
   when `verified`; `−8` for a marketplace when we have NO GTIN (third-party
   listings retitle the same product freely, so name matching there is the
   noisiest thing the fan-out can do); `−22` for a SPECIALIST that overlaps
   nothing when the product HAS a category. That last one is not a tiebreak — it
   is the difference between a book comparison and a live run that asked Chewy,
   AutoZone, CVS and Home Depot, because tier alone put four tier-1 specialists
   above every tier-2 bookshop. It never applies to a mass merchant, which has no
   specialism to mismatch.
4. **Order.** score desc → tier asc → id asc. The id tiebreak is the only thing
   standing between this and a directory-order dependency.
5. **Take** the profile's candidate limit. The constrained list is a strict
   PREFIX of the full one.

Excluded throughout: the source host and every store already on the tracker, by
retailer FAMILY (registrable domain), not exact host.

---

## The fan-out

`SellerFanOut.run(_:) -> SellerFanOutOutcome`. Two layers run concurrently.

**Layer 1 — the retailers' own searches.** For each candidate in rank order,
with the profile's concurrency: build the search URL, fetch it, extract up to
N plausible product links, resolve each, verify, take the first that is the same
product AND has a price. Any failure consumes the candidate — nothing is ever
retried.

### Which question each shop is asked

A seller is asked by IDENTIFIER first whenever the directory does not say it
refuses barcodes — including when `acceptsGTIN` is `nil`, which means unknown
rather than no. That is not optimism. When the source declares a GTIN, tier 4 is
refused outright, so a candidate reached by a NAME search can only be verified if
its page publishes structured identifiers — which most real pages do not. Asking
by identifier is what makes tier 3 available to it at all.

A shop of UNKNOWN barcode support gets the product NAME as a second question if
the first found nothing; one KNOWN to take barcodes does not. An empty answer
from a shop that indexes barcodes means "not stocked", and a second request is
itself how a bot wall gets tripped.

The name is always the CLEANED name (`ProductTitleHygiene`) — searching another
retailer for the string "Amazon.com" returns nothing on anyone's first page.

### Reading a search page

`LeanProductPageParser.productLinks` is where a fan-out most easily returns
nothing at all, and the first version did: measured against live captures it
found 0 of eBay's 99 `/itm/` URLs and 1 of Barnes & Noble's 79 — a Nook e-reader
SAMPLE on a different subdomain. Four rules, each from a measured failure:

1. **The whole document, not just `<a href="…">`.** eBay writes its search hrefs
   UNQUOTED (`href=https://…`), and product URLs sit in embedded JSON with
   escaped slashes at least as often as in anchors. One regex pass covers quoted,
   unquoted and bare absolute URLs, in document order, after JSON-unescaping.
2. **Each retailer's own shape.** `LeanProductURLRules.retailerRules` maps ~130
   registrable domains across all nine regions to their product paths (B&N's
   `/w/`, Walmart's `/ip/`, Target's `/-/A-`, Costco's `.product.<id>.html`,
   AbeBooks' `/<id>/bd`, …), plus per-retailer VETOES for shapes a shared pattern
   wrongly accepts — eBay seeds "Shop on eBay" promo cards at `/itm/123456`,
   which the shared `/itm/[0-9]{4,}` accepts and which ate every link slot.
   Entries are ADDITIVE: a URL matching neither list falls through to the shared
   tiers, so a guessed pattern costs nothing. That is why the table covers
   retailers nobody has measured.
3. **The retailer's own non-product pages are refused.** Reading the whole
   document means reading the whole document: bundle, API and asset URLs match
   `/products/[^/]+` as happily as products do (`gdx-api.costco.com/…/products/
   summary` was a live candidate), and a search page links help, cart, careers,
   gift cards and the store locator long before its first result. Excluded by
   subdomain label, path segment and file extension.
4. **Ranking.** Links carrying the SEARCHED identifier first — a retailer that
   puts the id in the URL has already said which of its fifty results is right —
   then retailer-shaped, then the shared strict patterns, then generic slugs,
   with document order preserved inside each tier. Amazon URLs canonicalize to
   `/dp/<ASIN>` so one product cannot fill three link slots under three slugs.

### Rendering a search page

The full profile carries a `renderSearch` closure. When a candidate's static
markup yields ZERO links, the search page is re-read through an off-screen
WebView and re-extracted — at most `renderedSearchLimit` times per run, claimed
inside the state actor so three concurrent candidates cannot each decide they are
first. `LunaPriceCompare` may not link WebKit, so the app supplies it
(`WebViewPriceRenderer.renderedSearchHTML`), whose readiness test is "the
rendered DOM yields a product link" rather than a fixed settle window. The
constrained profile has no renderer and a budget of zero.

The lean parser also reads the app-state JSON price tier (`current_retail`,
`currentPrice.price`) that `TargetPriceRule`/`WalmartPriceRule` already read with
SwiftSoup, with the storefront's REGION supplying the currency the bare number
lacks (`SellerDirectory.currencies`) — a `.com` is not evidence of a country.

**Layer 2 — keyless web search.** `DuckDuckGoSearch.results` (injected), which
reaches retailers the directory has never heard of. Same verification, same
merge rule; it is a second opinion, not a replacement. Off in the constrained
profile.

**Merge rule** (`ComparableResultMerger`): results are keyed by registrable
domain — one price per retailer, never two. A new domain appends. A domain
already claimed is SUPPLANTED only by a more strongly verified result (a GTIN
match beating a name match); otherwise the first to complete stands, because
concurrency makes "first completed" the only stable notion of priority and
confidence is the only reason worth overriding it for.

**Stopping**: `reachedTarget`, `exhausted`, or `budgetExpired` (wall clock,
checked between candidates — a single hung fetch is the injected fetcher's
problem to time out).

### Diagnostics

A run that finds nothing used to leave no trace: twelve candidates, zero results,
and nothing anywhere to say which retailer refused, which served a shell, and
which simply had the wrong product. "Nothing in the diagnostic logs" was how it
was reported, and it was literally true.

`SellerFanOutOutcome.attempts` carries one `SellerFanOutAttempt` per candidate —
the query actually used, the HTTP status, the bytes, the links extracted, whether
a render was needed, and either the `SellerMatchConfidence` it was ACCEPTED at or
the `SellerFanOutRejection` that ended it:

| rejection | means |
| --- | --- |
| `searchUnreachable` | the search page could not be fetched at all |
| `searchBotWalled` | a refusal status, or a challenge served as a 200 |
| `searchBadStatus` | a non-2xx that was not a refusal (an ordinary 404 miss) |
| `clientRenderedSearchSkipped` | flagged shop, and this profile cannot render |
| `noProductLinks` | fetched, and no recognizable product URL on it |
| `noPriceOnAnyLink` | every link led to a page with no price |
| `noVerifiedMatch` | pages were priced; none was the same product |
| `runEndedFirst` | the target was reached or the budget spent first |

The formatting lives on the value (`logLine`, `logSummary`, `compactLogLine`), not
at the call sites, so the app and the appex say the same thing about the same run.
`SellerComparisonRunner` writes each attempt AND the run summary to the app's
shareable `DiagnosticLog` under the `SellerComparison` category; the Safari finder
logs the one compact line an appex with a hard memory ceiling can afford. Tests
assert on the rejections rather than on log text.

**Bot walls are expected, not exceptional.** 401/403/405/429/503, or a
challenge interstitial served with a 200, marks the whole host out for the run —
following its product links would just collect more refusals. 404 is an ordinary
miss and does not poison the host. This is precisely why candidates are
over-provisioned relative to the result target in BOTH profiles.

### Profiles

| | `.full` | `.constrained` |
| --- | --- | --- |
| where | app + share/action extensions | Safari appex |
| candidates | 12 | 6 |
| result target | 6 | 3 |
| concurrency | 3 | 2 |
| product URLs per candidate | 3 | 2 |
| total budget | 35s | 15s (inside the appex's 20s native budget) |
| per-fetch timeout | 10s | 8s |
| name-only match | allowed | **refused** |
| `.gtinInPage` match | allowed | **allowed** (it is identifier evidence) |
| client-rendered sellers | asked, with a render fallback | skipped at selection |
| rendered searches per run | 3 | 0 |
| web-search layer | on | off |

---

## Match verification

`ComparisonMatching.verify` — the one decision the feature's credibility rests
on. A wrong "$9.50 at Amazon" is worse than no answer.

1. **GTIN equality** (normalized, zero-padded to 14) → `.gtin`. Two GTINs that
   DIFFER are a refusal, not a fall-through: both sides named the product
   globally and named different products.
2. **MPN equality + compatible brand** → `.mpn`.
3. **The page STATES the GTIN without declaring it** → `.gtinInPage`. Three
   conditions, all required: the page was reached by asking THIS retailer's own
   search for the GTIN's digits, the page (or its URL) contains those digits, and
   the name similarity in tier 4 already passes.
4. **Name similarity ≥ 0.6 (Jaccard) + compatible brand** → `.name`, but only
   when the profile allows it AND **the source declared no GTIN or MPN**. If the
   source has a strong id and the candidate does not present the same one, a name
   coincidence is not evidence — it is the case, the older model, or the
   two-pack. (A retailer SKU is not a cross-host identifier, so it does not block
   this tier.)

### Why tier 3 exists

Tiers 1 and 2 are unreachable on most of the real web. The measured case: an
Amazon `/dp/` page, found by searching amazon.com for the exact GTIN, whose
markup and whose URL both carry that GTIN, with a matching title — refused,
because Amazon publishes no JSON-LD and lean parsing therefore found
`gtin == nil`. Demanding a STRUCTURED identifier is demanding something most
retailers do not ship.

The two halves of the evidence do different jobs and neither is sufficient. The
SEARCH half — this page came back from asking this shop for these exact digits —
is what makes the containment meaningful rather than coincidental. The
CONTAINMENT half is what stops a shop's "related items" rail from being taken as
an answer. Because it is identifier evidence and cheap string containment, the
**constrained profile accepts it** while still refusing tier 4.

Every written form is tried (`GTINForms.variants`): GTIN-14, EAN-13, UPC-12, and
for books the ISBN-10 — which is how Amazon's `/dp/<isbn10>` counts, since a book
ASIN IS the ISBN-10. A separator-tolerant second pass catches
`978-0-7352-1129-2`. The obvious trap is pinned by a test: the AUDIOBOOK edition
of a title matches by name and does not carry the paperback's ISBN, so it is
refused.

`requiresPageEvidence` is the same question asked cheaply, so the orchestrator
can tell whether fetching a page's markup would change the answer before spending
a request on it — which matters because the rich resolver returns a parse and no
HTML.

---

## Amazon

Amazon needed its own reader, in both directions, and did not have one.

**It publishes no structured data.** No JSON-LD `Product`, no
`product:price:amount`, no microdata. So a saved Amazon page produced NO keyed
identifiers — leaving its own fan-out nothing to verify anybody against — and an
Amazon CANDIDATE parsed with `price == nil`, so the lean profile could never
price the retailer the whole feature most needs.

`AmazonProductDetails` (LunaPriceMetadata — Foundation-only, and a dependency of
both `LunaPriceIngest` and `LunaPriceCompare`, so the SwiftSoup tier and the lean
tier read Amazon with the SAME code and cannot disagree) supplies:

- **Identifiers** — ISBN-13/ISBN-10, UPC/EAN, "Item model number", brand — read
  as plain text out of the product-details table. Wired into the rich save path
  through `ProductMetadataExtractor`, which fills only what structured extraction
  left empty, and into the lean path through `LeanProductPageParser.parse`.
- **The buy-box price**, anchored on the buy box rather than on "the first price
  on the page" (an Amazon page carries twenty-odd), including the current layout
  that serves an EMPTY `a-offscreen` and splits the number across
  `a-price-whole` / `a-price-fraction`. Currency comes from the markup, else from
  `AmazonStorefronts`.

Two details are what make label-window reading safe rather than approximate, and
both were bugs first:

- It **narrows to the detail containers** (`prodDetTable`,
  `productOverview_feature_div`, `richProductInformation`, `detailBullets…`)
  before looking for a label. The warranty paragraph contains the word
  "Manufacturer" long before the details table does, and the first plausible text
  after it is not a brand. Narrowing also took the extraction from ~1.5 s to
  ~10 ms, which matters inside a 15 s appex budget.
- It **refuses labels that sit inside markup**. The product-overview grid tags
  its row `class="po-brand"`, and the first text node after that occurrence is
  the word "Brand" — so without the check, the brand of every such page was the
  string `Brand`.

**ASIN ↔ ISBN.** For books, Amazon's ASIN *is* the ISBN-10, so `/dp/0735211299`
states the product's global identifier even on a page whose details table did not
load. `GTINForms.isbn13(fromISBN10:)` derives the ISBN-13 (978 prefix, recomputed
EAN check digit), and `isValidISBN10` — a real checksum — is the whole safety
margin: `B09XS7JWHH` fails it, so an ordinary ASIN is never promoted to a book
number. The same fact serves as candidate-URL evidence in tier 3.

**Titles.** `ProductTitleHygiene` strips storefront chrome (`Amazon.com: …`,
`… - Walmart.com`, a trailing `(Paperback)`) before a title becomes a search query
or one side of a name-similarity check. Searching another retailer for the string
"Amazon.com" returns nothing on anyone's first page, and Jaccard overlap was
docking the source for words that describe the SHOP. It is generic title hygiene,
applied to every source. It is deliberately conservative — `(Anniversary Edition)`
distinguishes products and survives; a title that is ONLY chrome keeps its
original text rather than becoming empty.

---

## The median baseline

A save-time fan-out attaches N stores at once, all priced "right now". If the
alert baseline stayed at the lowest store — what the multi-store initializer
does — then finding a cheaper seller would read as a price DROP, and every later
real drop would look flat against it.

`PriceTracker.medianStorePrice` + `seedComparisonBaseline` fix that: the
baseline becomes the MEDIAN across stores priced in the display currency (odd
count → the middle value; even → the average of the middle two). Foreign-currency
and price-less stores are excluded — there is no FX source (see
`PriceDaySnapshot.fxRate`), so they would contribute a meaningless number.

Seeding also stamps `alertAcknowledgedAt`, so a cheapest-seller-below-threshold
state cannot badge the row (`hasUnviewedAlert`). The notification side needs
nothing: `PriceRefreshOutcome.newlyAlerting` fires only on a TRANSITION, and a
seeded tracker is already alerting before its first refresh.

## Whose baseline it is

All of that reasoning describes the DEFAULT path — the user saved a product and
left the alert alone. It stops the moment they touch the alert configuration
themselves, and since the fan-out now runs in the background behind an open
editor, they can do that while it is still out.

`PriceTracker.PendingSellerComparison` records `thresholdFractionAtStart`, and
`completePendingComparison` seeds the median **only if the tracker's threshold
still equals it**. If they moved the slider, cleared the alert, or set one where
there was none:

- their threshold stands;
- `initialPrice` stands — they chose a number against the price they could SEE,
  and re-basing under them would silently retune it;
- nothing is pre-acknowledged, so a cheaper seller arriving from the fan-out is
  allowed to cross the line and fire a real alert. That is the intended
  behaviour, not an accident: the alert-suppression stamp exists to keep the
  DEFAULT from crying wolf, and they are not on the default.

The marker is cleared either way — a finished run is a finished run.

---

## The surfaces (B2)

The engine makes no request and knows no surface. `LunaPriceUI` supplies both
halves of the app side.

**`SellerComparisonRunner`** is the wiring: `ArticleFetcher` for pages (its
`FetchError.badResponse(status:)` is what carries a bot wall's status back into
the engine, so a refusal stays a RESULT rather than becoming an error),
`DuckDuckGoSearch.results` for Layer 2, and `ProductPageSuggestion.resolve` — the
whole `IngestPipeline`, WKWebView render tier included — as the rich resolver, so
a seller whose price only exists after client-side rendering still counts. The
resolver is raced against twice the profile's per-fetch allowance, because it may
spend `IngestPipeline.processTimeout` (28 s) on one URL, which is most of the
run's entire budget; losing that race costs a page, not the run. The whole run is
capped at `profile.totalBudget + hardCapGrace`.

It is **installed** by `ProductKindComposition.install()`, not called. A process
that did not compose the product kind has `installed == nil` and every surface
skips the comparison — which is deliberately indistinguishable from a comparison
that found nothing, because the save lands either way.

**`SellerComparison`** owns the request and what happens to results. The ordering
is the load-bearing part and it is not the obvious one:

1. the tracker is created from the SOURCE page alone and persisted;
2. each verified seller is `upsertStore`d with a live price and a recorded day
   sample;
3. `seedComparisonBaseline` runs last.

Building every store up front instead would go through `PriceTracker`'s
multi-store initializer, which takes the CHEAPEST store's currency as
`initialCurrency` — so a single foreign-currency listing that happens to be
numerically lowest would silently redenominate the tracker and make the median
meaningless. `apply` also refuses a seller on a registrable domain the tracker
already holds: the engine keys its own results per domain but cannot know what
the tracker was already carrying.

**Nobody waits for it except the intents.** A fan-out is up to 35 s of other
people's web servers. It used to sit between the save and the UI: a share sheet
that looked stuck, and an editor that opened half a minute after the tap. The
save now lands immediately with the one seller the user was actually looking at,
and the run goes out behind it.

| surface | where | what the user sees |
| --- | --- | --- |
| app (paste / manual) | `ProductTrackerIngestor.ingest`, new-tracker branch, started before the save announcement | the card appears at once with its one seller and a "Checking for other sellers…" row; retailers fill in under it |
| share / action extensions | `ExtensionProductPresenter.presentPriceEditor`, started before presenting | the editor, immediately, with the same waiting row in its seller list |
| Action Button intents | `ProductIntentHandoff.document` joins the run before rendering | the system progress bar, `Stage.findingSellers` — this ONE surface still waits, because its answer is the comparison |

The merge path is never compared: that tracker has already been through a
fan-out, and re-running would spend a dozen candidates re-finding the stores it
is excluding.

### The pending marker

`PriceTracker.pendingComparison` is the whole of the asynchronous machinery, and
it is on the MODEL — on disk — because the process that starts a run is routinely
gone before it ends: a share extension is torn down the moment the user is done
with it, by design. The marker carries only what the tracker does not already
know (the source URL, the start time, the threshold at the start); the request
itself is reconstructible, and a resumed run excludes whatever the dead process
had already attached.

One fact, three readers:

- the seller list's waiting row, in both product surfaces
  (`PriceTrackingViewController`'s table and the deck card's `storesStack`);
- `SellerComparison.completePending`, swept at app launch (the product
  `KindWiring`s' `appDidLaunch`) and at the head of every background refresh
  cycle — before the refresh, so the sellers it attaches arrive already priced
  and the baseline it settles is what that cycle's alert decisions are made
  against;
- the intents, which join a run rather than start a second one.

A run that FINISHES always clears the marker, even having found nothing — a
marker that outlives its run is a spinner that never stops. A process with no
runner installed leaves it alone, because nothing ran.

`SellerComparisonTasks` is the in-process rendezvous: a second caller for the
same tracker awaits the first rather than fanning out across the same dozen
retailers again.

### Streaming

`SellerFanOut.OnResult` fires the moment a verified seller ENTERS the merged
list — inside the actor that applies the merge rule, which is what makes "as it
lands" true rather than aspirational. `SellerComparison` attaches and persists
each one immediately, and `.readingListChanged` carries it to whichever list is
open.

## The summary document

`SellerComparisonDocument` (LunaPriceUI) renders ONE self-contained HTML file:
inline CSS, the product photo and every favicon as `data:` URIs, and the price
graph as inline SVG built from `PriceHistory.dailySeries` — the FULL day-
resolution record rather than the on-screen graph's span-coarsened view, because
this renderer is 640 points wide, read at any size, and a year of pruned history
is at most 365 points. (The per-day dots retire past 60 points, where they merge
into a bar and the line already carries the shape.) The y-domain is padded below
the minimum so a low reads as a low rather than as a clipped line, and the price
axis labels exactly three numbers — the high, the low and TODAY, deduplicated
when they coincide, with today folded into the domain so a price below the
record still lands inside the plot. Self-containment is the whole requirement — a Shortcut result is Quick
Looked, saved to Files, AirDropped and mailed, all with no network, no base URL
and no cache — and `SellerComparisonDocumentTests` asserts it directly (no
`src="http`, no `<link`, no `<script`).

Favicons are fetched CONCURRENTLY with a per-seller deadline
(`faviconTimeout`). Sequentially and unbounded — three well-known icon paths per
host, an 8 s timeout each, six sellers — is minutes of wall clock inside an
intent that gives up first, which is the actual reason a document can come out
iconless. A seller whose icon does not arrive gets an initial-letter badge, never
an empty square.

Two deliberate departures from the rest of Luna:

- **It renders in the READER's appearance**, as a plain `prefers-color-scheme`
  pair, not `LunaSkyTrait`. This is the only thing Luna ships that is read
  outside Luna, and forcing black onto a light Quick Look looks broken rather
  than considered.
- **It leads with the sellers, not the graph.** The file answers one question —
  where is this cheapest right now — so the answer is the first row as well as
  the badged one. History is context for that answer. Unpriced stores are shown
  last rather than dropped: a seller Luna is watching and currently cannot read
  is a fact about the comparison.

`html(_:)` is pure over an assembled `Content`, so structure is assertable
without the network the assets come from. `write(for:articlesDirectory:)` returns
nil for a single-store tracker — one price is not a comparison.

Reachability note: the price kind cannot use `ArticleExportService`, because
`LunaSend` is article-kind and `LunaPriceTracker` does not link it. Hence a
renderer of its own rather than a shared document builder.

## In Safari (B3)

The constrained profile's one caller today. `LunaSafari/ComparableSellerFinder
.swift` answers the extension's `comparableSellers` message: stored prices from
the App Group first (the app-written history index + the passive snapshot file,
matched by the extension's existing tiers), then — only if those have nothing —
the fan-out, fetched through a bare ephemeral `URLSession` carrying
`WebFetchConstants.safariUserAgent`. Results are written back as passive
snapshots (`ComparableSellerResult.snapshotPayload`), so a price found for a pill
feeds everything snapshots already feed.

`FreshComparablePrices` is the answer rule, and every part of it is a refusal:
older than **24h**, a different currency (there is no FX source), not strictly
cheaper than the page, or the page's own retailer. It lives in this module rather
than the appex because the appex is not compiled into `LunaTests` — the Safari
sources are pinned by source-text parity tests, and this is the one piece of the
feature worth executing (`FreshComparablePricesTests`).

Two Safari-specific consequences of the profile: a page declaring **no GTIN and
no MPN skips the live leg entirely** (with name-only matching off, the run could
only end in refusals), and the budgets nest — 15s fan-out inside an 18s finder
inside the handler's 20s inside the page's 25s backstop. Pill behaviour and the
fallback contract are in `claudedocs/safari-extension.md`.

## Link set

`LunaPriceCompare` is linked by: `Luna`, `LunaPriceTracker`, `LunaShare`,
`LunaAction`, `LunaPriceTrackerShare`, `LunaPriceTrackerAction`, all four
`*Safari` appexes, and `LunaTests`. Added by
`scripts/add_price_compare_links.rb` (idempotent; re-run
`scripts/hide_generated_schemes.rb` afterwards).

All four Safari appexes link it, not just the Price-Tracker one, because the
appex sources are shared and `hostHandlesProducts` is a runtime gate — the
central Luna app's Safari extension handles products too.

---

## Tests

All in `LunaTests/`:

| file | what it pins |
| --- | --- |
| `SellerDirectoryTests` | the SHIPPED json (validation, regions, per-region mass merchants), `{query}` substitution in both contexts |
| `SellerCandidateSelectorTests` | ordering determinism, directory-order independence, bounds, prefix property, exclusions, each scoring weight, region resolution, per-seller query |
| `LeanProductPageParserTests` | JSON-LD/OG/microdata extraction, stable `@graph` node choice, refusals, search-link extraction |
| `LeanProductURLParityTests` | the copied rule tables + both predicates vs `ProductPageRules`/`ProductPageDetector` |
| `ComparisonMatchingTests` | the three verification tiers and their refusals |
| `ComparisonMatchingParityTests` | `ProductIdentityMatching` vs `ProductMatcher`/`SnapshotMatcher` |
| `BotWallDetectionTests` | blocked statuses, 200-served challenges, no false positive on a large page |
| `SellerFanOutTests` | rank order, stop-at-target, budget expiry, bot-wall skip, verification refusals, exclusions, rich resolver, Layer 2 |
| `RealWorldSearchLinkExtractionTests` | the captured eBay/B&N/Target search pages that returned nothing, the promo-card veto, asset/API and furniture refusals, JSON-escaped URLs, ASIN collapsing |
| `AmazonProductDetailsTests` | identifiers and the buy box off two captured Amazon PDPs, the `po-brand` and warranty-prose false positives, the split-price layout, the lean parser end to end |
| `GTINFormsTests` | ISBN-10 ↔ ISBN-13, UPC/EAN/GTIN-14 forms, and that an ordinary ASIN fails the checksum |
| `ProductTitleHygieneTests` | storefront prefixes/suffixes and format tails, and what must survive |
| `GTINInPageMatchingTests` | the evidence tier's three conditions and its five refusals, including the audiobook trap |
| `SellerFanOutDiagnosticsTests` | every rejection reason, attempt streaming, the run summary, the client-rendered skip, the render fallback and its cap, the identifier-then-name questions |
| `SellerCategoryRelevanceTests` | a book outranking unrelated specialists, and hint normalization |
| `ComparableResultMergerTests` | the merge/supplant rule |
| `PriceComparisonBaselineTests` | median semantics, no badge at seeding, no `newlyAlerting` on the first refresh |
| `ProductIdentifiersTests` | the keyed value type and its normalization |
| `FreshComparablePricesTests` | the 24h window and the four refusals; a result's snapshot payload |
| `ProductPageDetectorTests` / `ProductMatcherTests` | keyed extraction and the keyed-GTIN match tier |
| `SellerComparisonTests` | the request, the pending marker's life, per-seller streaming, the median/no-badge seeding, the touched-threshold rule, the per-family refusal, the new-tracker-only rule, the launch/refresh sweeps, the rendezvous, and the two no-op states |
| `LiveNetworkPolicyTests` | that the installed fan-out — and every other live fetcher — refuses to leave the machine from a test process |
| `SellerComparisonDocumentTests` | the document's self-containment, ordering, flat-series graph and escaping |
| `ProductComparisonIntentTests` | the `comparison` checkpoint, v1-decodes/v+1-refused, the seam's absence in non-product apps, the freshness rule |
| `ShareSurfaceDriverTests` | the extension editor opens IMMEDIATELY and leaves the fan-out running behind it |
| `PriceTrackingScreenTests` | the waiting row's presence and its removal, in both product surfaces |
