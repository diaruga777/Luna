# Failed saves — the error card

When a saved URL can't be ingested it lands in `.failed`. It used to render as an
empty reader card headed by whatever title the store happened to hold, with one
line of apology ("Couldn't fetch this article") and a long-press menu offering
Archive. Now it gets a card that explains itself and offers every way forward.

## What the card shows

`FailedSaveCardViewController` (`LunaReadingListUI`), assembled by
`FailedSaveCardFactory` (`Luna/ReadingList/`, universal — compiled into all four
app targets):

1. **Favicon + title + site name.** A failed page has no title *by construction*:
   `ArticleResolver` only returns `.unreadable` when it couldn't get even a
   `<title>`, so anything with one parks in `.needsCaptcha` instead. The title
   therefore comes from a fallback chain (`FailedSaveNaming.displayTitle`):
   a title recovered by a light head-only read → the stored title (never the
   `"Untitled"` placeholder) → `ArticleFetcher.articleTitleGuess` on the URL slug
   → the bare host. Site name is `og:site_name` → host without `www.`. The icon is
   `SourceIconCache` (the same cache the mini-card badges use); a site with no
   reachable icon shows a **question mark**, not a blank box.
2. **The URL that failed**, in full, scheme stripped — path and query kept,
   because *which* link broke is the point.
3. **Why**, from `SaveFailureReason.headline`, plus a `suggestion` line where
   there's something to suggest ("Opening it in the browser often works where a
   background fetch can't").
4. **Attempt provenance** — "Tried 3 times · last 2 hours ago" once there's been
   more than one attempt (the retry sweep runs on every launch/foreground, so this
   climbs on its own).
5. **Four actions**: Try with Apple Intelligence (the LLM rescue), Open in Browser,
   Share Link, and Try Again — the last only for a reason where retrying the same
   background fetch could plausibly differ (`isWorthRetrying`: offline, timeout,
   transport, 429, 5xx — never a 403 or an unreadable page).
6. **A subtle red rim** (`CardSurfaceView.setEdgeGlow`, tint
   `LunaColors.errorAccent`), supplied per card through the
   `CardCarouselDataSource.edgeGlowColorForCardAt` hook. `CardSurfaceView` clips
   (the letterbox tone and corner radius both need it), so an outward
   `layer.shadow` would be swallowed — the glow is a tinted ring stroked just
   INSIDE the edge whose shadow blooms inward, reading as a lit rim.

While a rescue is in flight the card says "Trying harder with Apple
Intelligence…" with a spinner and hides every button that would start another;
`URLRescueCoordinator` posts `.readingListChanged` on start and finish, which
both roots already observe.

**No Archive.** Filing an empty shell away where the user can't act on it is
worse than nothing, so the card menus on both roots offer only **Share Link** and
destructive **Delete** — matching what the list row's failed-item menu already
did (`ReadingListRowMenuFactory`).

## The rescue hint

Implied by the running app: Reader → `.article`, Downloader → `.media`, Price
Tracker → `.product` (`URLRescueWiring.defaultHint(for:)`), so those apps show
one button and no picker. The **central Luna app** handles all three kinds and
therefore has a real question to ask — it shows a segmented `RescueHint` picker,
and the button renames itself to match ("Extract as Price Tracker").

## Why the reason exists at all

`Outcome.failed` used to carry no payload and `markFailed` wrote only the state,
so no surface could say anything specific. Now:

- **`SaveFailureReason`** (`LunaModels`) — coarse and actionable, one case per
  sentence a reader can do something about: `offline`, `timedOut`,
  `httpStatus(Int)`, `network(String)`, `notReadable`, `notHTML`, `tooLarge`,
  `unsupportedDocument(String)`, `noMediaFound`, `couldNotSave`, `unknown`. Each
  owns its `headline`, `suggestion`, and `isWorthRetrying`.
- **The plumbing.** `ArticleFetcher.FetchError.badResponse` carries the status
  code; `ArticleExtraction.fetchAndExtract` gained a defaulted `onFetchError`
  hook (the only place the swallowed fetch error still exists);
  `ArticleResolution.unreadable(SaveFailureReason?)` and
  `Outcome.failed(SaveFailureReason?)` carry it to the presenter. `case .failed`
  still matches without binding, so pattern-matching call sites were untouched.
  A **reached-but-empty** page always reports `.notReadable` and never inherits a
  stale transport error; only a page that never came back carries the fetch's own
  reason.
- **`SaveFailureStore`** (`saveFailures.json`, App Group) — reason, failure count,
  last failure date, and the recovered title/site name. A **sidecar**, never new
  `ReadingListItem` fields: an older sibling app decoding and re-encoding the
  shared `readingList.json` would silently drop unknown keys (the same reasoning
  as `RescueLedgerStore` and the imageRefs / preloads sidecars). Cleared whenever
  an item reaches `.ready` or `.needsCaptcha`, so a later failure starts from a
  clean count.

## Failed saves surface in EVERY app

A `.failed` item has no kind — `Outcome.failed.owningApp` is nil, which is why the
surface gate never drops it. It was nonetheless only *visible* in the Reader,
because `rendersAsReader` is true for anything with no platform and no tracker.
So a Downloader link that failed was stored and invisible.

`ReadingListSectioning.ListFilter.includes` now short-circuits on
`isFailedSave(_:)` and every filter shows it. The app the user saved the link in
is where they expect to see it break, and any app can offer the rescue that gives
it a kind — after which it classifies and settles into its own app. On the
Downloader root, failed saves occupy the carousel slots after the media cards
(`failedIndex(forCarouselIndex:)`); a `.failed` platform item is excluded, since
it kept its kind and has its own download-failure UI.

## Open in Browser

`WebPageViewController` (`LunaDesignSystem`) — a plain full-screen `WKWebView`
with the unlock flow's chrome: **Done** top-left, **Open in Safari** top-right,
presented in its own navigation controller via `present(url:from:)`. Distinct from
`InAppBrowser` (an `SFSafariViewController` sheet) on purpose: a real web view
using the user's own cookie store frequently renders what a background
`URLSession` fetch could not — a JS-gated page, a bot-blocked front door, a wall
the user is already through — so seeing the page is often the whole answer to
"why did this fail".

## Tests

`LunaTests/FailedSaveTests.swift` — reason classification, the copy contract,
the naming chain, `<head>` metadata parsing, the sidecar's accumulation rules,
surface inclusion, and the hint-picker policy. The `.unreadable` reason rule is
pinned in `ArticleResolverTests`.
