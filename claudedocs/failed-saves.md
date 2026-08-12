# Failed saves — the error card

When a saved URL can't be ingested it lands in `.failed`. The card that stands in
for it doesn't describe the page Luna couldn't read — it **shows** the page, in a
real web view, and offers the one thing that might still work.

## What the card shows

`FailedSaveCardViewController` (`LunaReadingListUI`), assembled by
`FailedSaveCardFactory` (`Luna/ReadingList/`, universal — compiled into all four
app targets), top to bottom:

1. **The page itself**, in a `WKWebView` inset 8pt from the card's edges (almost
   full bleed; just enough to clear the 22pt corner radius). It uses
   `WebJunkBlocker.makeConfiguration()` and the **default** website data store —
   the user's own cookies — because that is exactly the case where a background
   `URLSession` fetch failed and a real web view renders fine: a JS-gated page, a
   bot-blocked front door, a wall the user is already through. Seeing the page is
   both the explanation and the consolation prize.
   Link taps are **refused** and re-presented full screen in
   `WebPageViewController`: the card is a window onto ONE page, and a tapped link
   navigating in place would make the URL bar below it a lie.
2. **A URL bar** — reload on the left, the URL (scheme stripped, middle-truncated
   so the identifying slug survives) in the middle, share on the right. Share goes
   straight to the system sheet with the **raw URL**: a failed save has no content,
   nothing to export, no media, so there is nothing else to share, and the reader's richer
   share ladder isn't compiled into the Downloader/Price Tracker targets anyway.
3. **The chin** — a full-width prominent glass capsule, **"Retry with AI"** with
   the Apple Intelligence glyph trailing the words as a sigil rather than leading
   as an icon. `apple.intelligence` arrived in SF Symbols 6.2 (iOS 18.4) and the
   deployment target is 18.0, so `sparkles` is a real fallback, not
   belt-and-braces.
4. **A red glass border.** `CardSurfaceView.setEdgeGlow` (tint
   `LunaColors.errorAccent`), supplied per card through the
   `CardCarouselDataSource.edgeGlowColorForCardAt` hook. The rim STROKE takes the
   tint and its shadow blooms inward — `CardSurfaceView` clips, so an outward
   `layer.shadow` would be swallowed. A failed card reads as a card with a red
   border, not a white-bordered card lit red from inside.

There is **no hint picker in any app**, central Luna included: the model
classifies the page itself (see below). There is no title, favicon, failure
sentence, suggestion, or attempt count on the card either — the live page says
more than any of them did. `FailedSaveNaming.displayTitle` still feeds the
carousel's chrome and scrub preview through `FailedSaveCardFactory.displayTitle`,
so a light head-only metadata read is still worth doing.

## Retrying: overlay, progress, terminal state

Tapping **Retry with AI** immediately covers the web view with a 40%-opacity black
overlay carrying a `MoonHorizonProgressBar` — on the tap, not on the first progress
report, because the coordinator's work starts on a background executor and the
press has to land visibly. Under the overlay:

- the **URL bar stays uncovered and live** (the overlay is a subview of the web
  container only), so share still works;
- **reload is disabled** — reloading the page under a running extraction would
  pull the ground out from under it;
- the AI button stays in place, disabled and dimmed, rather than disappearing.
  Hiding it would collapse the chin and resize the web view mid-rescue, which
  reads as the card breaking rather than working.

**Progress is real**, not a timer. `URLRescueEngine.rescue` takes an `onProgress`
callback and reports a `RescueStage` as it crosses each of its own boundaries
(`queued → replayingRule → fetching → digesting → thinking → reading → applying →
finished`); the app shell's engine bridge forwards each one to
`URLRescueCoordinator.reportProgress`. The stage fractions are deliberately NOT
evenly spaced — the model call dominates a 90-second budget — and
`rescueProgress(_:)` interpolates within a stage (ease-out, capped short of the
next stage's fraction) so a 22-second model call creeps instead of freezing. The
card watches `.rescueProgressChanged` filtered on its own item id, plus a 0.3s
ticker to render the interpolation; that notification is separate from
`.readingListChanged` because progress fires many times per rescue and
`.readingListChanged` reloads every deck and list.

On completion the card either becomes an ordinary card (the item advanced) or
returns to the error state — and that state is **terminal**: the AI button is
replaced by "Sorry, Luna was unable to save this page." and a **Delete** button.

**Terminal is scoped to the app version**, one attempt per shipped build.
`SaveFailureRecord.aiAttemptVersion` records `AppConfig.appVersion` (short version
*and* build — a TestFlight bump carries new extraction code too) when a
user-initiated rescue finishes without recovering the item. While that equals the
running version the card is terminal; after an update it doesn't match, so the
item is eligible again, and `URLRescueCoordinator.reopenStaleVersionAttempts()`
clears its ledger budget at install so the launch sweep retries it automatically.
`ReadingListIngestor.ingestAllPending` already re-runs ordinary ingestion for
every `.failed` item on launch, so an update gets **both** paths with no extra
scheduling. Storing the version rather than a bool is what makes that automatic —
no migration, no "clear all" pass to remember to run.

Only **user-initiated** rescues spend the attempt (`requestManualRescue`). The
background sweep must not burn the one thing the card has left to offer. An
unavailable engine (`canRescue == false`) shows the same terminal chin, since
there is genuinely nothing to offer.

**And only a real verdict spends it.** `Engine.perform` returns a
`URLRescueCoordinator.RescueRunResult`, not a Bool, precisely because three
different not-recovered endings used to be one: `.notRecovered` (the model looked
and couldn't) spends the attempt; `.transient` (assets unavailable, another
request holding the session, no model at all, a quota wall — the model never saw
the page) and `.surfaceDropped` (it DID recover the content and this app doesn't
show that kind) spend nothing.

**A guardrail is not a budget.** When a content-safety guardrail or a flat
refusal rejects the prompt, that is a verdict on the PAGE — the prompt is derived
from it — so it holds forever, not for a version. `RescueLedgerEntry
.guardrailedAt` records it, `shouldAutoRescue` refuses first, `requestManualRescue`
and `rescueAndWait` return immediately, and it deliberately survives
`resetAttempts(for:)`: an app update changes Luna's extraction code, not Apple's
safety model. The card shows `.unavailable` rather than `.spent`, which renders
identically but promises nothing about the next update.

## The third ending: hand it to the browser

A 401/403/429 is the server saying "not you" to a *background fetch*.
`SaveFailureReason.browserMayRecover` documents the measurement: a real
`WKWebView` presents a browser's TLS fingerprint and runs the challenge JS, and
routinely gets a 200 and the full article for a page `URLSession` cannot touch.
So instead of a dead card, rescue can move the item to the interactive
archive-unlock tier — `.needsCaptcha`, a live card with a tap-to-unlock
affordance — via `ReadingListStore.markNeedsCaptcha`, which clears the failure
sidecar itself.

Two routes reach it:

- **Deterministic**, and it runs FIRST — ahead of the model call *and* the model
  availability gate. When the recorded reason is browser-recoverable and the
  handoff hasn't been offered yet (`RescueLedgerEntry.browserHandoffAt`), the
  engine returns `.needsBrowser` without spending 30 seconds arriving at an
  answer it already has, and without needing Apple Intelligence at all.
- **Model-chosen**, the `open_in_browser` directive, for the cases evidence
  argues for but no status code proves.

The handoff is **once per item**: a second one would just re-park a card the user
already chose not to unlock, so a repeat failure falls through to the model.

It is also **gated to apps that have the tier**. `.needsCaptcha` is rendered by
the article deck, which the Downloader and Price Tracker don't compile, so
parking an item there would hide it in a state their decks have no card for.
The gate is `LinkImportRunner.articleUnlocker != nil` — the seam the two
article-handling `KindWiring`s already install for exactly this question, rather
than a second one that could disagree with it.

Neither route spends the version attempt: the item left `.failed` for somewhere
the user can still act.

**No Archive.** Filing an empty shell away where the user can't act on it is worse
than nothing, so the card menus on both roots offer only **Share Link** and
destructive **Delete**.

## The rescue hint: there isn't one, anywhere

Every app used to imply a hint (Reader → `.article`, Downloader → `.media`, Price
Tracker → `.product`), the central Luna app showed a segmented picker on the card,
the list row's tap opened a three-way action sheet, the row's long-press menu
opened a three-child submenu, and the extension's failure card had its own
segmented control. **All four are gone.** `RescueRequest.ContentHint.auto` is what
an **absent** hint means, and every user-facing surface sends nil: the plan
instructions offer every payload option and open by telling the model that
classifying the page is its job, while the prompt states what already failed as a
*diagnostic fact* instead of naming a content type. See
`claudedocs/url-rescue.md`.

`RescueHint` survives, but is **never user-facing** — no `displayName` exists,
because nothing displays it. It remains for the two PROGRAMMATIC callers that
genuinely know the kind from where the user pressed: the price editor's no-price
retry (`.product`) and the media card's no-assets retry (`.media`). A concrete
hint still constrains the validator.

## One design across every error surface

The offer used to appear under three labels ("Try with Apple Intelligence", "Try
Apple Intelligence", "Ask Apple Intelligence") and two icons. A user who meets it
twice shouldn't have to work out whether it's the same offer, so there is now ONE
definition — `GlassStyle.retryWithAIConfiguration` (label "Retry with AI", the
`apple.intelligence` glyph trailing as a sigil) — and one place for the shared
words, `FailedSaveCopy` in LunaModels.

| Surface | What it shows |
| --- | --- |
| **In-app card** (`FailedSaveCardViewController`) | The full design: red rim, web view, URL bar, Retry with AI, eclipse overlay, terminal apology + Delete. |
| **Extension failure card** (`RescueFailureViewController`) | The SAME card — red rim, web view, URL bar, Retry with AI. One honest difference: an extension links no rescue engine, so the button queues a `PendingRescueRequest` (hint nil) and opens the app, and there is no progress overlay to show. |
| **Downloader's failed-download card** | Now carries the red rim too (it didn't, so two failures in one deck looked unrelated), and its rescue button takes the shared styling. |
| **Failed list row** | Tap → a single "Retry with AI" confirm; long-press → one flat action + Delete. Once the version's attempt is spent, both become the card's terminal state: the apology and Delete. It stays a *confirm* rather than rescuing on the bare tap because the attempt is rationed — a mis-tap would spend the only thing the item has left. |
| **Price editor's no-price alert** | An alert can't carry card chrome, but it calls the same thing the same name. |

## Why the reason exists at all

The card no longer prints a failure sentence, but the reason still drives the retry
policy, the list rows, and the prompt's diagnostic line, so the plumbing stands:

- **`SaveFailureReason`** (`LunaModels`) — coarse and actionable, one case per
  sentence a reader can do something about: `offline`, `timedOut`,
  `httpStatus(Int)`, `network(String)`, `notReadable`, `notHTML`, `tooLarge`,
  `unsupportedDocument(String)`, `noMediaFound`, `couldNotSave`,
  `subscribeRedirect`, `notContent`, `unknown`. Each owns its `headline`,
  `suggestion`, and `isWorthRetrying`.
  `notContent` is the page not being a piece of content at all — a search-results
  page, a homepage, a section index (`ListingPage`, see
  `claudedocs/url-pipeline.md`). It is the **one reason the AI rescue stands down
  for**, via `isWorthRescuing`: every other failure means "we couldn't GET the
  article", which a model reading the page can sometimes fix, whereas a search
  page has no article to find and a rescue would spend the version's single
  attempt proving it. Both the trigger (`ReadingListIngestor`) and the card's
  chin (`FailedSaveCardFactory`'s `canRescue`) consult it, so the card shows the
  terminal apology instead of an offer it can't keep.
  `subscribeRedirect` is the site answering an article request
  with its own subscribe page (`ArticleFetcher.FetchError.subscribeRedirect` — see
  `claudedocs/url-pipeline.md`); it is not worth retrying, and a hard-paywall host
  parks for the archive tier rather than failing at all.
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
  last failure date, the recovered title/site name, and the AI-attempt version. A
  **sidecar**, never new `ReadingListItem` fields: an older sibling app decoding
  and re-encoding the shared `readingList.json` would silently drop unknown keys
  (the same reasoning as `RescueLedgerStore` and the imageRefs / preloads
  sidecars). Cleared whenever an item reaches `.ready` or `.needsCaptcha`, so a
  later failure starts from a clean count *and* a fresh AI attempt.

## Failed saves surface in EVERY app

A `.failed` item has no kind — `Outcome.failed.owningApp` is nil, which is why the
surface gate never drops it. It was nonetheless only *visible* in the Reader,
because `rendersAsReader` is true for anything with no platform and no tracker.
So a Downloader link that failed was stored and invisible.

`ReadingListSectioning.ListFilter.includes` short-circuits on `isFailedSave(_:)`
and every filter shows it. The app the user saved the link in is where they expect
to see it break, and any app can offer the rescue that gives it a kind — after
which it classifies and settles into its own app. On the Downloader root, failed
saves occupy the carousel slots after the media cards
(`failedIndex(forCarouselIndex:)`); a `.failed` platform item is excluded, since it
kept its kind and has its own download-failure UI (a separate card, untouched by
this design — see `claudedocs/media-download.md`).

## Cost of a web view per card

The carousel mounts the centered card plus its two peeks, so up to three
`WKWebView`s exist at once. Each is created **lazily** on `viewWillAppear` and
loaded once; a rescue-driven rebuild reloads the page *behind* the overlay, where
it's dimmed anyway. `scrollView.alwaysBounceHorizontal` is off so the web view's
scrolling doesn't fight the carousel's horizontal paging, `allowsCardTap` is false
so a stray tap can't page or toggle playback, and `longPressSelectsContent` is true
over the page so link previews and text selection belong to the web view while the
card's own Share/Delete menu stays on its chrome.

## Tests

`LunaTests/FailedSaveTests.swift` — the naming chain, `<head>` metadata parsing,
the sidecar's accumulation rules, surface inclusion, the version-scoped terminal
state, and the ledger reset. `LunaTests/URLRescueCoordinatorTests.swift` — stage
progress, its notification, the monotonic fraction table, and which rescues spend
the version's attempt. `LunaTests/URLRescueEngineTests.swift` — that progress
always opens `.queued` and closes `.finished`, and never claims a fetch it didn't
perform. `LunaTests/RescueDirectiveValidatorTests.swift` — the `.auto` payload
policy. `LunaTests/ShareSurfaceDriverRescueTests.swift` — that the queued extension
request carries no hint. The `.unreadable` reason rule is pinned in
`ArticleResolverTests`.
