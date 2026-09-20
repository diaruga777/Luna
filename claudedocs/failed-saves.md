# Failed saves — the error card

When a saved URL can't be ingested it lands in `.failed`. The card that stands in
for it doesn't describe the page Luna couldn't read — it **shows** the page, in a
real web view, and offers the one thing that might still work.

## What the card shows

`FailedSaveCardViewController` (`LunaSavesUI`), assembled by
`FailedSaveCardFactory` (`Luna/Saves/`, universal — compiled into all four
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
   There IS one other thing, when the save left a trace behind: the button becomes
   a two-item menu, **Share Link…** plus **Share Diagnostics…**, the latter
   exporting the whole story of the attempt — every request and status, every
   classification decision, every bypass strategy — as a `.txt`
   (`claudedocs/save-diagnostics.md`). It appears only when
   `SaveDiagnosticsStore.hasDiagnostics(for:)`, so an item that failed before
   per-save capture shipped keeps the plain button.
3. **The chin** — the chat hand-off row (`LLMHandoffRowView`): a caption, a glass
   button per provider, and a hint line under them. It is the one thing the user
   can still do about the failure, and it is the same row the extension failure
   card and the Downloader's no-media card show
   (`claudedocs/llm-handoff.md`). Delete sits under it.
4. **A red glass border.** `CardSurfaceView.setEdgeGlow` (tint
   `LunaColors.errorAccent`), supplied per card through the
   `CardCarouselDataSource.edgeGlowColorForCardAt` hook. The rim STROKE takes the
   tint and its shadow blooms inward — `CardSurfaceView` clips, so an outward
   `layer.shadow` would be swallowed. A failed card reads as a card with a red
   border, not a white-bordered card lit red from inside.

There is **no content-type picker in any app**, central Luna included, and no
Apple Intelligence button anywhere: the automatic attempt is already spent or
running by the time anyone reads the card. There is no title, favicon, failure
sentence, suggestion, or attempt count either — the live page says more than any
of them did. `FailedSaveNaming.displayTitle` still feeds the
carousel's chrome and scrub preview through `FailedSaveCardFactory.displayTitle`,
so a light head-only metadata read is still worth doing.

## The four states

`FailedSaveCardModel.RescueState` is where the save is in its recovery, and
`FailedSaveCardFactory.rescueState` reads it from three places in that order:

| State | When | What the card does |
| --- | --- | --- |
| `.running(progress:)` | `URLRescueCoordinator.isRescuing` | The automatic Apple Intelligence attempt is in flight: the page goes under a 40% black overlay with a `MoonHorizonProgressBar`, and the row stands down. |
| `.applying(progress:)` | `RecoveryFileApplier.isApplying` | A Luna file is being applied. The same overlay and bar, because it is the same recovery finishing. |
| `.waiting(provider)` | `LLMHandoffStore` has a live record with no refusal on it | The user opened a provider and the reply has not come back. The row stays, with the line naming the file to tap. |
| `.offer` | otherwise | The row, and — when a file for this save was refused — one line under it saying why. |

Under the overlay the **URL bar stays uncovered and live** (the overlay is a
subview of the web container only), so share still works, and **reload is
disabled** — reloading the page under a running extraction would pull the ground
out from under it.

**Progress is real**, not a timer. `URLRescueEngine.rescue` takes an `onProgress`
callback and reports a `RescueStage` as it crosses each of its own boundaries
(`queued → replayingRule → fetching → digesting → thinking → reading → applying →
finished`); the app shell's engine bridge forwards each one to
`URLRescueCoordinator.reportProgress`. The stage fractions are deliberately NOT
evenly spaced — the model call dominates a 90-second budget — and
`rescueProgress(_:)` interpolates within a stage (ease-out, capped short of the
next stage's fraction) so a 22-second model call creeps instead of freezing. An
apply posts on the same notification, so the card animates both without knowing
which is running. The card watches `.rescueProgressChanged` filtered on its own
item id, plus a 0.3s ticker to render the interpolation; that notification is
separate from `.savesChanged` because progress fires many times per rescue and
`.savesChanged` reloads every deck and list.

**There is no terminal state and no apology.** The card used to end at "Sorry,
Luna was unable to save this page." plus Delete, because the one thing it could
offer was spent. It now always has something to offer — the hand-off row — so a
Luna file that will not apply simply brings `.offer` back with one line under the
row saying why, and the file is not retried.

**The reason outlives the process.** A file that answers a recorded hand-off
files its refusal on the RECORD (`LLMHandoffStore.markRefused`, App Group), so
the card still explains itself on the next launch instead of quietly going back
to the plain offer; the record is replaced on the next provider tap and cleared
by a successful apply. Only a file that arrived with no hand-off behind it falls
back to `RecoveryFileApplier.lastFailure(forURL:)`, which lives in the process
that read it — long enough for the card to say it once.

**A guardrail is not a budget.** When a content-safety guardrail or a flat
refusal rejects the prompt, that is a verdict on the PAGE — the prompt is derived
from it — so it holds forever. `RescueLedgerEntry.guardrailedAt` records it and
`shouldAutoRescue` refuses first, so no sweep and no queued extension hand-off
reaches the item again. It changes nothing the user sees: the card offers the
chat hand-off either way, which is the route a guardrail does not block.

## The third ending: hand it to the browser

A 401/403/429 is the server saying "not you" to a *background fetch*.
`SaveFailureReason.browserMayRecover` documents the measurement: a real
`WKWebView` presents a browser's TLS fingerprint and runs the challenge JS, and
routinely gets a 200 and the full article for a page `URLSession` cannot touch.
So instead of a dead card, rescue can move the item to the interactive
archive-unlock tier — `.needsCaptcha`, a live card with a tap-to-unlock
affordance — via `SavesStore.markNeedsCaptcha`, which clears the failure
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

Either way the item leaves `.failed` for somewhere the user can still act.

**No Archive.** Filing an empty shell away where the user can't act on it is worse
than nothing, so the card menus on both roots offer only **Share Link**,
**Share Diagnostics…** when a trace exists, and destructive **Delete**.

## One design across every error surface

Apple Intelligence used to be offered under three labels ("Try with Apple
Intelligence", "Try Apple Intelligence", "Ask Apple Intelligence") and two icons,
on five surfaces. All five are gone, and so is the shared styling that held them
together (`GlassStyle.retryWithAIConfiguration`). What every error surface shares
now is the chat hand-off row, and the shared words in `FailedSaveCopy`
(LunaModels).

| Surface | What it shows |
| --- | --- |
| **In-app card** (`FailedSaveCardViewController`) | The full design: red rim, web view, URL bar, the hand-off row, the eclipse overlay while anything runs. |
| **Extension failure card** (`RescueFailureViewController`) | The SAME card — red rim, web view, URL bar, the same row. One honest difference: an extension may only ASK its host to open a provider, so a refused open falls back to the containing app (`claudedocs/llm-handoff.md`), and there is no progress overlay to show. |
| **Downloader's failed-download card** | Carries the red rim too, and shows the same row for the one failure a model can answer: `.noMedia`. |
| **Price editor's no-price alert** | Just the alert now. A page with no price is a page the user can hand to a chat model from its own card. |

## Why the reason exists at all

The card no longer prints a failure sentence, but the reason still drives the
retry policy and both prompts' diagnostic line, so the plumbing stands:

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
  page has no article to find and a rescue would spend the item's one attempt
  proving it. `SavesIngestor`'s trigger consults it, so the automatic attempt
  never runs for one.
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
  last failure date, and the recovered title/site name. A **sidecar**, never new
  `SavedItem` fields: a new field on the shared save is a schema change four
  independently-updated apps have to agree on, where a sidecar is one writer's
  own file (the same reasoning as `RescueLedgerStore` and the preloads sidecar).
  Cleared whenever an item reaches `.ready` or `.needsCaptcha`, so a later
  failure starts from a clean count. A record written by an older build also
  carries `aiAttemptVersion`, the one-attempt-per-app-version gate the card used
  to read; the decoder drops it.
- **`SaveDiagnosticsStore`** (`saveDiagnostics/<UUID>.log`, App Group) — the
  second sidecar, and the one with the DETAIL the reason above only summarizes:
  the complete timestamped trace of every attempt this item has made. Written
  only on failure (a save that works flushes nothing and deletes what an earlier
  attempt left), appended to by each retry, exported by the card's share menu,
  and read back by the URL-rescue engine as failure evidence. Dropped alongside
  the failure record by `SavesStore.clearFailureRecords`. Full detail in
  `claudedocs/save-diagnostics.md`.
- One gap that closed with it: the share/action extensions' failure leg called
  `store.markFailed` WITHOUT `SaveFailureStore.recordFailure`, so an extension
  failure was the one path with no reason and no count — the card had nothing to
  explain itself with and the rescue's failure-kind mapping had nothing to read.
  Both are written now, as everywhere else.

## Failed saves surface in EVERY app

A `.failed` item has no kind — `Outcome.failed.owningApp` is nil, which is why the
surface gate never drops it. It was nonetheless only *visible* in the Reader,
because `rendersAsReader` is true for anything with no platform and no tracker.
So a Downloader link that failed was stored and invisible.

`LunaApp.includes` short-circuits on `SavesSectioning.isFailedSave(_:)`, so every
app's deck shows it. The app the user saved the link in is where they expect to
see it break, and any app can run the recovery that gives it a kind — after which
it classifies and settles into its own app. On the Downloader root, failed saves
occupy the carousel slots after the media cards
(`failedIndex(forCarouselIndex:)`); a `.failed` platform item is excluded, since
it kept its kind and has its own download-failure UI (a separate card — see
`claudedocs/media-download.md`).

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
the sidecar's accumulation rules, surface inclusion, and the card's state table.
`LunaTests/URLRescueCoordinatorTests.swift` — that a failure runs exactly one
automatic attempt and no more, that a queued extension hand-off runs without a
tap, the guardrail's permanence, and the stage-progress notification.
`LunaTests/URLRescueTests.swift` — that the failure leg queues the hand-off with
no tap on either extension, and that a refused provider open falls back to the
containing app. `LunaTests/RecoveryFileApplierTests.swift` — what an arriving
Luna file becomes. The `.unreadable` reason rule is pinned in
`ArticleResolverTests`.
