# Per-save diagnostics

A save that fails carries a complete, shareable record of the attempt: every
network request and what came back, every classification decision, every bypass
strategy tried and what it got. The failed-save card can hand that record over as
a `.txt`, and the URL-rescue engine can read it back as evidence.

Before this existed, the pipeline logged **nothing**. `DiagnosticLog` /
`SharedDiagnosticLog` had lines from the mail, push and CloudKit layers, and not
one from LunaFetch, LunaPaywallBypass, LunaHTMLClassification, LunaIngest,
LunaMediaResolve or LunaPriceIngest — so "why did this link fail" had no answer
beyond the one coarse `SaveFailureReason` the outcome carried. There was also no
correlation id anywhere, so two concurrent saves would have interleaved
indistinguishably even if they had logged.

## The three pieces

| Piece | Lives in | Does |
| --- | --- | --- |
| `SaveDiagnosticsRecorder` | LunaModels | Buffers ONE save's lines under the item's UUID; mirrors each to the general stream |
| `SaveDiagnostics` | LunaModels | The `@TaskLocal` binding + the `record` / `snippet` / `url` / `formatLine` helpers |
| `SaveDiagnosticsStore` | LunaStorage | The per-item file `<AppGroup>/saveDiagnostics/<UUID>.log`, plus export/delete/prune |

**Why the recorder is in LunaModels and the store is not.** Every tier worth
instrumenting already depends on LunaModels and none of them depends on
LunaStorage. Putting the recording seam at the bottom is what lets
`LunaMediaResolve` and `LunaPriceCompare` stay on their Foundation-only floors —
no new dependency edge was added anywhere for this feature. Only the two layers
that already own persistence (`ReadingListIngestor`, `ShareSurfaceDriver`) touch
the store.

## Call sites: unconditional, and free when nobody is listening

Instrumentation never asks whether it should log:

```swift
SaveDiagnostics.record("pipeline: classified \(kind)", category: "ingest")
```

`record` takes its message as an `@autoclosure`, so outside a save the string is
not even built. A preload, a metadata refresh, a price sweep and the onboarding
demo all run this same code and write nothing — which is the reason those paths
deliberately bind no recorder.

**Never pass a response body.** Shapes, sizes, statuses and decisions only.
`SaveDiagnostics.snippet(_:limit:)` clamps a quoted fragment (default 200 chars)
and flattens newlines so one record stays one line; `SaveDiagnostics.url(_:)`
clamps a URL. Request identity is logged as header NAMES plus a user-agent LABEL
(`ArticleFetcher.userAgentLabel` — `Googlebot`, `safari`, `custom(…)`), never as
header values.

## Line format and the tag

A buffered line is exactly the shape `clip-diagnostics.log` uses:

```
2026-08-13T09:41:22.184Z [fetch] GET https://example.com/a ua=safari referer=set → 403, declared 1840B, read 1840B, 0ch in 412ms
```

The mirrored copy going to the general stream is the same message prefixed with
`[save <first 8 of the item UUID>]` — the `[category]` slot is already taken, so
the correlation id rides the message. The mirror stamps its own timestamp
microseconds later, so the two files interleave rather than match byte for byte.

Categories in use: `ingest`, `fetch`, `bypass`, `media`, `price`.

## Who binds, who flushes

- **`ReadingListIngestor.ingest`** creates the recorder for the placeholder
  item's UUID and binds it around BOTH the pipeline call and `applyResult`
  (the media leg only discovers a dead link while its handler runs). Mirror:
  `DiagnosticLog.shared.record`.
- **`ShareSurfaceDriver.ingestAndPresent`** does the same for the share/action
  extensions, mirroring through `SharedDiagnosticLog.record` — the SYNCHRONOUS
  one, because an extension can be jetsammed the instant a save finishes.
- **Nothing else binds.** Not `PreloadCoordinator`, not the reader clip, not a
  metadata refresh, not the onboarding demo. Those are not user saves.

At the end of a save the buffer is either committed or thrown away:

- outcome `.failed` (or the recorder was marked terminal — see below) **and** the
  surface gate said `.supported` ⇒ `appendLines` under a separator line,
  `— attempt N via <source>, <reason> —`, where N is the `SaveFailureStore`
  failure count;
- anything else ⇒ drain and `delete(for:)`, so an item that has since worked
  stops carrying last week's story.

Launch-sweep retries re-enter the same path, so the file accumulates
`attempt 1 …`, `attempt 2 …` and a shared export shows whether the failure is
stable or intermittent.

### The media exception

A media save is the odd one out: the pipeline classifies the post successfully
(`.video` / `.social`), the row is stored `.ready`, and only the download that
follows discovers there is nothing playable behind the link. Recognized platform
items never enter `.failed` — by design, since they still render from a logo and
a deep link.

So `SaveFailureReason.noMediaFound` had **no writer at all**, which made
`URLRescueWiring`'s `mediaNoAssets` branch unreachable. `MediaSaveFailureRecording
.recordNoMedia` is now that one writer, called from `LiveMediaDownloadManager
.failJob` (the durable background transfer) and from `MediaAutoDownloader`'s
awaited path. When a recorder is bound it also calls
`SaveDiagnostics.markTerminalFailure(.noMediaFound)`, which is what makes the
ingestor keep the trace instead of dropping it as the success the `Outcome`
claims. When none is — the background job fails minutes later in a delegate
callback, with no task tree left — it appends one line straight to the store via
`SaveDiagnostics.formatLine`.

## Instrumented sites

| Where | What it records |
| --- | --- |
| `ArticleFetcher.fetch` | The choke point behind six of seven `HTMLFetching` methods: URL, UA label, referer/XFF presence, status, declared vs read bytes, chars, elapsed ms; on throw, which `FetchError` |
| `ArticleFetcher` archive indexes | archive.today TimeMap, Wayback availability, Wayback CDX — the three lookups that bypass `fetch` |
| `ArticleExtraction.fetchAndExtract` | Extracted body length + title presence, or the swallowed fetch error |
| `ArticleResolver.resolve` | Direct read shape, the `BypassPlan` (silent list, web pre-stages, archive.today allowed?), the silent-tier verdict, the final resolution |
| `BypassRunner.run` | ONE line per strategy via `BypassAttempt.logLine` — name, chars extracted, whether it cleared the readable gate, elapsed |
| `IngestPipeline` | Unwrap, classification verdict, both non-content vetoes, direct-HTML size, product path + price, article path, the timeout leg |
| `SocialMediaResolver` | Every ladder step (its injected `fetch` is wrapped once, so X/TikTok/Instagram/Facebook/Reddit/YouTube are all covered), then platform + asset count/kinds |
| `ProductIngestProcessor` / `ProductMetadataExtractor` | Static markup price, render-tier price, Safari-snapshot fallback consulted/answered |
| `PriceFetcher` / `WebViewPriceRenderer` | Static vs rendered DOM price, and the off-screen render boundary |

**The delegate-callback caveat.** A task-local does not survive into a WKWebView
navigation callback. Components that log from one (`WebViewPriceRenderer`'s
`Renderer`, snapshot renderers) must either capture the recorder at creation or —
as `WebViewPriceRenderer` does — record at the boundary, which is still on the
save's own task. `TimeLimit.run` is fine: it uses an unstructured `Task {}`, which
inherits task-locals (`Task.detached` would not).

## Sharing it

The failed-save card's URL-bar share control grows a menu — "Share Link…" plus
"Share Diagnostics…" — and the deck's long-press menu gains the same verb. Both
appear ONLY when `SaveDiagnosticsStore.hasDiagnostics(for:)`, so an item that
failed before this shipped shows the plain button it always had.
`FailedSaveCardFactory.diagnosticsHeader` prepends build/OS/export context plus
what the failure sidecar concluded (reason headline, attempt count, last failure
date, spent AI-rescue version), and `SaveDiagnosticsStore.exportFile` writes
header + trace to a `.txt` for a `UIActivityViewController`.

## Lifecycle

- `ReadingListStore.clearFailureRecords` drops the sidecar record AND the trace
  together, at all four points where an item stops being failed.
- `ReadingListStore.delete` drops the trace with the item.
- `ReadingListIngestor.ingestAllPending` prunes trace files whose item is gone —
  it already holds the whole list, which is the one thing a prune needs.
- The file itself is capped at 256 KB and trimmed from the FRONT (the inverse of
  `DiagnosticLog`, which keeps its tail for a different reason): retries append
  forever, and the newest attempt is the one worth sharing. The in-memory buffer
  is capped at 2000 lines the same way, and says so when it drops any.
