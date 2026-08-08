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

`LunaPriceCompare/Resources/seller-directory.json` — 218 retailers across 9
English-speaking regions, bundled rather than fetched (a network round trip just
to learn *where* to look would spend most of the appex's budget before the first
real request).

```
{ version: 1,
  sellers: [{ id, name, region, domain, searchURL, acceptsGTIN, marketplace,
              categories, tier, verified }] }
```

- `searchURL` carries exactly one `{query}` placeholder. It may sit in a query
  VALUE (`?k={query}`) or in the PATH (`/s/{query}` — 11 of the 218), and those
  escape differently: `+` means "space" only inside a query string. `Seller
  .searchRequestURL(forQuery:)` looks at where the placeholder actually is.
  Everything outside RFC 3986 unreserved is percent-escaped, so a product name
  containing `&`/`?`/`#`/`/` cannot break out of the template.
- `categories` draw from the fixed `SellerCategory` taxonomy; `general` marks a
  mass merchant.
- `tier` is 1 (household name) … 3 (niche).

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
   and product name (word-boundary matching, plural "s" allowed), unioned with
   the source retailer's own directory categories minus `general`. **Empty ⇒
   mass merchants only** — the shops that sell everything, rather than a dozen
   specialists chosen at random.
3. **Score.** tier 1 `+30` / tier 2 `+18` / tier 3 `+8`; `+12` per category
   overlap capped at `+24`; `+10` when `acceptsGTIN` and we have a GTIN; `+4`
   when `verified`; `−8` for a marketplace when we have NO GTIN (third-party
   listings retitle the same product freely, so name matching there is the
   noisiest thing the fan-out can do).
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
with the profile's concurrency: build the search URL (raw GTIN digits when the
seller is known to accept them, else the product name), fetch it, extract up to
N plausible product links, resolve each, verify, take the first that is the same
product AND has a price. Any failure consumes the candidate — nothing is ever
retried.

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
| web-search layer | on | off |

---

## Match verification

`ComparisonMatching.verify` — the one decision the feature's credibility rests
on. A wrong "$9.50 at Amazon" is worse than no answer.

1. **GTIN equality** (normalized, zero-padded to 14) → `.gtin`. Two GTINs that
   DIFFER are a refusal, not a fall-through: both sides named the product
   globally and named different products.
2. **MPN equality + compatible brand** → `.mpn`.
3. **Name similarity ≥ 0.6 (Jaccard) + compatible brand** → `.name`, but only
   when the profile allows it AND **the source declared no GTIN or MPN**. If the
   source has a strong id and the candidate does not present the same one, a name
   coincidence is not evidence — it is the case, the older model, or the
   two-pack. (A retailer SKU is not a cross-host identifier, so it does not block
   this tier.)

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

---

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
| `ComparableResultMergerTests` | the merge/supplant rule |
| `PriceComparisonBaselineTests` | median semantics, no badge at seeding, no `newlyAlerting` on the first refresh |
| `ProductIdentifiersTests` | the keyed value type and its normalization |
| `FreshComparablePricesTests` | the 24h window and the four refusals; a result's snapshot payload |
| `ProductPageDetectorTests` / `ProductMatcherTests` | keyed extraction and the keyed-GTIN match tier |

---

## Still to come (B2 / B3)

- **B2** — `SellerComparisonRunner` in `LunaPriceUI` (feeds the engine
  `ArticleFetcher`, `DuckDuckGoSearch.results` and `ProductPageSuggestion
  .resolve`), installed via `ProductKindComposition.install()`;
  `ProductTrackerIngestor` seeding; the "Finding other sellers…" spinner phase in
  the extensions and the main app; App Intents participation + the self-contained
  HTML summary document.
B3 has landed — see "In Safari" above.
