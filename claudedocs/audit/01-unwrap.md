# Audit 01 — Wrapper Unwrapping (Pipeline Stage 1)

Read-only audit of the URL-unwrapping stage: turning a wrapper/redirect URL into
the real underlying article URL, ideally offline & deterministically, as the
first thing that runs on any incoming URL.

**Files in scope**
- `ReaderKit/NewsAggregatorUnwrapper.swift` — the unwrapper (sole logic)
- `Lune/ReadingList/ReadingListIngestor.swift` — `ingest` (async unwrap choke point)
- `ShareKit/ShareViewController.swift` — share/action extension entry points
- `Lune/ReadingList/ReadingListViewController.swift` — in-app "Save a Link" alert + paste row
- `Lune/Intents/LuneSafariPageIntent.swift` — `IntentIngestHelper.handleSavePressWithTimeout`
- `ReaderKit/ArticleFetcher.swift` — `canonicalForArchiving` (tracking-param stripping; tightly coupled to unwrap output)
- `LuneTests/NewsAggregatorUnwrapperTests.swift` — tests
- `claudedocs/reading-list.md` — docs

---

## 1. Current-state map

`NewsAggregatorUnwrapper` is a stateless `enum` with two public entry shapes:

| Entry | Signature | Sync/async | Purpose |
|---|---|---|---|
| `unwrap(_:session:)` | `(URL) async -> URL?` | **async** | Full unwrap. Returns nil for non-wrappers (cheap host check, no network) and for unrecoverable wrappers. |
| `normalizedIncomingURL(_:)` | `(URL) -> URL` | **sync/pure** | Facebook-only offline unwrap; returns original on miss. |
| `normalizedIncomingURLString(_:)` | `(String) -> String` | **sync/pure** | String overload of the above. |
| `facebookRedirectTarget(_:)` | `(URL) -> URL?` | **sync/pure** | Underlying primitive both of the above call; also called directly. |

### Wrapper types handled

| Wrapper | Host/scheme gate | Sync/async | Mechanism |
|---|---|---|---|
| **Facebook deep link** | scheme `fbrpc` | **sync** | Read `target_url` query param; must be http(s) on non-FB host. |
| **Facebook link shim** | `l./lm./m./www./facebook.com` + path `/l.php` | **sync** | Read `u` query param. |
| **Apple News** | `apple.news`, `*.apple.news` | **async** (fetch) | GET page, regex `redirectToUrlAfterTimeout("<url>")`. nil for News+ exclusives. |
| **Google News classic** | `news.google.com`, `news.url.google.com` | **sync after fetch-of-nothing** | base64url-decode `CBMi…` id → scan decoded bytes for embedded `http(s)://…`. Offline. |
| **Google News new-style** | same | **async** (2 round-trips) | `batchexecute` RPC: GET page for `data-n-a-sg`/`data-n-a-ts`, POST `f.req` envelope, regex `garturlres` URL out of response. |
| **Google share** | `share.google`, `*.share.google` | **async** (GET) | Follow redirects with a GET (the on-Google interstitial only emits its onward hop on GET, not HEAD) → final cross-host URL (e.g. a `…/search?ibp=oshop&…&prds=…` Google Shopping product page). Matches the host generically, never a specific id. |
| **Link shorteners** | hardcoded `Set` (`t.co`, `nyti.ms`, `flip.it`, …) | **async** (HEAD) | Follow redirects, return final URL only if host changed. |

Tracking-param stripping is **not** in the unwrapper — it lives in
`ArticleFetcher.canonicalForArchiving` (drops fragment + a hardcoded
`trackingParams` set incl. `fbclid`). It runs later, only on the archive path,
not as part of unwrap output.

### Invocation per surface

The vision is "a SINGLE shared unwrap step run identically on EVERY surface." In
reality unwrap is split into **two half-steps** (sync FB-only normalize at the
input gate, async full unwrap deeper in), and surfaces invoke them inconsistently:

| Surface | sync `normalize*` at gate? | async `unwrap` later? | Notes |
|---|---|---|---|
| In-app **Save a Link** alert (`ReadingListViewController:683`) | ✅ string | ✅ via `handleSavePress`→`ingest` | OK |
| **App intents** (`IntentIngestHelper:74`) | ✅ string | ✅ via `handleSavePress`→`ingest` | OK |
| Share ext **handleURL** (`ShareViewController:222`) | ✅ URL | ✅ via `presentSavedOrReader` | OK |
| Share ext **handleJavaScriptResult** / action ext (`:200`) | ✅ string | ✅ via `presentSavedOrReader` | OK |
| Share ext **handleText** (`:325`) | ✅ via `facebookTargetIfPresent` (a 4th FB call site) | ✅ | OK but bespoke |
| Share ext **handleFriendShare** (`:375`) | ✅ URL | ❌ **never** — writes straight to `PendingFriendShareWriter`, no async unwrap | **DIVERGENCE** |
| **Paste row → save** with prefetched content (`ReadingListViewController:239` → `saveNewWithContent`) | ❌ | ❌ **`saveNewWithContent` does NOT call `ingest`** (adds + `saveContent` directly, lines 533–544) | **DIVERGENCE/BUG** |
| Paste row → save **without** content (`:244` → `handleSavePress`) | ❌ | ✅ | inconsistent with the sibling branch above |
| `saveAsArticle` (price-tracker "Read instead", `:524`) | ❌ | ✅ via `ingest` | depends on already-saved URL |
| **Friend-share consumption** (app side, reads `PendingFriendShareStore`) | — | depends on whether it routes through `ingest` (not re-verified here) | the FB-normalized URL was already written by the extension; an `apple.news`/shortener friend-shared link is only unwrapped if the consumer hits `ingest` |

**Key bugs / divergences:**

1. **`saveNewWithContent` skips unwrap entirely.** The paste row's "happy path"
   (content already prefetched) bypasses `ingest`, so an Apple News / Google
   News / shortener / **even Facebook** link pasted with a prefetched preview is
   saved as the wrapper URL. (The FB sync normalize is also absent on both paste
   branches.) This is the clearest correctness gap.
2. **`handleFriendShare` runs only the sync FB normalize**, never async
   `unwrap`. A friend sharing an `apple.news` or `nyti.ms` link enqueues the
   wrapper. Whether it ever gets unwrapped depends on the consumer path.
3. **The historical fbrpc http-gate bug** (documented in `reading-list.md`) was
   patched by sprinkling `normalizedIncoming*` in front of every
   `hasPrefix("http")` gate. That's 6 call sites of the same FB-only half-step —
   correct today, but fragile: a *new* surface (or the two paste branches above)
   silently regresses to the original bug.

---

## 2. Problems

**A. The unwrap step is not single or uniform.**
There is no one function the whole app calls. Instead: a sync FB-only half-step
at input gates (4 named call sites + 2 string/URL helper variants) and an async
full-step at two deeper choke points (`ingest`, `presentSavedOrReader`), each
re-implementing the "did it change? repoint the store, log, record replay"
dance. Facebook is special-cased to run twice (once sync up front, once again
inside async `unwrap` line 27). Surfaces that don't pass through one of the two
async choke points get partial or no unwrapping (see §1 bugs).

**B. Sync vs async split is by *wrapper type*, not by *need*.**
The owner's model is "sync fast path, async only when a fetch is truly
required." The code half-honors this: FB + Google-classic are pure/offline,
Apple News + Google-new + shorteners need network. But the *API* exposes the
split as "FB-only sync normalize" vs "everything async," so callers can't ask
for "do all the offline unwrapping you can, synchronously." Google-classic
(offline-decodable) is only reachable through the async entry, so an input gate
can't resolve a classic Google News link without going async.

**C. Not list-driven / not extensible.**
Dispatch is a hand-written `if/else` ladder in `unwrap` (lines 28–34) plus a
parallel ladder in `facebookRedirectTarget`. Host predicates are scattered
(`isAppleNews`, `isGoogleNews`, `isFacebookLinkShimHost`, `isFacebookHost`,
`redirectShorteners` Set). Adding a new wrapper (e.g. Reddit `out` links,
LinkedIn `lnkd.in`, `news.google` regional hosts) means editing the ladder, not
appending to a registry. The only list-driven part is `redirectShorteners`.

**D. Fragile internals (acceptable but undocumented as such in API).**
- `googleNewsBatchExecute` is an undocumented Google internal RPC with a
  hand-built `f.req` string and two regexes (`data-n-a-sg`, `garturlres`). High
  breakage risk; correctly falls back to nil, but there's no telemetry to know
  when it silently stops working.
- `appleNewsPublisherURL` depends on a single JS function name
  (`redirectToUrlAfterTimeout`). One Apple page-template change breaks it
  silently.
- `firstEmbeddedHTTPURL` relies on ISO-Latin-1 byte→scalar mapping and protobuf
  framing heuristics — clever and tested, but a maintenance hazard.

**E. Tracking-param stripping is decoupled from unwrap.**
`canonicalForArchiving` (the `fbclid`/`utm_*` stripper) lives in `ArticleFetcher`
and only runs on the archive path. The unwrapper returns URLs *with* tracking
params (the verbatim Messenger test asserts the `fbclid` survives unwrap). So
the row title, dedupe key (`store.updateURL`/`item(forURLString:)`), and sharing
all see the dirty URL; only archiving sees the clean one. The vision wants
unwrap to return the canonical underlying URL (+ stripped params) so dedupe and
display are consistent.

**F. Duplicated "repoint + log + replay" orchestration.**
`ingest` (lines 66–87) and `presentSavedOrReader` (lines 255–264) each do:
`unwrap` → compare → `store.updateURL`/`item(forURLString:)` → diagnostic log →
(ingest also) replay record. Two copies, slightly different (ingest handles the
"already saved → drop" case; share doesn't). Should be one composed step.

**G. No dead code, but redundant surface area.**
`normalizedIncomingURL` and `normalizedIncomingURLString` are near-duplicates;
`facebookTargetIfPresent` in `ShareViewController` is a third trivial wrapper
over `facebookRedirectTarget`. All thin, but they exist only because there's no
single entry that does "offline-normalize this incoming value."

---

## 3. Proposed simplified design

A single `URLUnwrapper` with an **extensible registry** of handlers keyed by a
matcher, one app-wide entry point, and an explicit sync-fast-path / async-fetch
split returned to the caller.

### Types

```swift
/// The canonical result of unwrapping one incoming URL. `url` is always the best
/// URL to use downstream (the original if nothing matched), already tracking-
/// stripped. `didUnwrap` lets callers log/repoint only on a real change.
struct UnwrapResult {
    let url: URL
    let didUnwrap: Bool
    let wrapper: WrapperKind?   // which handler fired, for telemetry/replay
}

/// How a handler resolves a matched URL.
enum UnwrapResolution {
    case immediate(URL?)               // pure, offline (Facebook, Google-classic)
    case fetch((URLSession) async -> URL?)  // network required (AppleNews, Google-new, shorteners)
}

/// One wrapper definition. New wrappers are added by appending a value here.
struct WrapperHandler {
    let kind: WrapperKind
    /// Matches incoming URL by scheme and/or host (host-suffix aware).
    let matches: (_ scheme: String?, _ host: String?) -> Bool
    /// Given a match, return how to resolve it.
    let resolve: (URL) -> UnwrapResolution
}

enum WrapperKind: String { case facebookDeepLink, facebookShim, appleNews,
                                 googleNewsClassic, googleNewsNew, shortener }
```

### The registry (list-driven, the only place you extend)

```swift
enum URLUnwrapper {
    /// EXTEND HERE. Order matters only for overlap; matchers are otherwise disjoint.
    static let handlers: [WrapperHandler] = [
        .facebook,        // fbrpc:// + */l.php — immediate
        .googleNews,      // classic→immediate, new→fetch (decided inside resolve)
        .appleNews,       // fetch
        .shorteners(redirectShortenerHosts),  // fetch
    ]
}
```

Each handler factory (`.facebook`, `.appleNews`, …) wraps the existing pure
parsers (`facebookRedirectTarget`, `appleNewsPublisherURL`,
`googleNewsURL(fromArticleID:)`, `googleBatchExecuteURL`, `firstEmbeddedHTTPURL`)
— **keep all of those, they're well-tested**. Only the dispatch changes.

### Single entry points

```swift
extension URLUnwrapper {
    /// THE app-wide entry. Run once per incoming URL on EVERY surface (paste,
    /// typed, action ext, share ext, intent, friend-share consume). Does the
    /// offline fast path inline; performs network only when a matched handler
    /// requires it. Always returns a usable, tracking-stripped URL.
    static func unwrap(_ url: URL, session: URLSession = .shared) async -> UnwrapResult

    /// Offline-only fast path for INPUT GATES that can't await / must not block,
    /// and that need a real http(s) URL before a `hasPrefix("http")` check
    /// (kills the fbrpc gate bug for ALL current and future surfaces, not just FB).
    /// Resolves every `.immediate` handler; leaves `.fetch` wrappers untouched
    /// (the async `unwrap` finishes them at the choke point). Pure.
    static func unwrapOffline(_ url: URL) -> UnwrapResult
}
```

`unwrapOffline` replaces all of `normalizedIncomingURL`,
`normalizedIncomingURLString` (add one tiny `String` convenience that re-parses),
and `facebookTargetIfPresent` — and crucially it also resolves Google-classic
offline, which today's FB-only normalize can't.

### Tracking stripping folded in

`UnwrapResult.url` is passed through a single canonicalizer (move/share
`ArticleFetcher.canonicalForArchiving`'s param-stripping into a small
`URLCanonicalizer.strip(_:)` that both unwrap and archiving call) so dedupe,
display, and archive all agree on one canonical URL.

### Composition as stage 1 → stage 2 (classifier)

```
incoming URL/string
   └─ stage 1: URLUnwrapper.unwrap(url)         // wrapper → real article (+ strip)
        └─ UnwrapResult.url
             └─ stage 2: classifier(url)        // document? youtube? platform? product? article?
```

Input gates call `unwrapOffline` first (so the http gate sees a real URL), then
the *single* choke point (`ingest`) calls async `unwrap` once, repoints the
store once (the dedupe/"already saved" logic lives there, not duplicated in the
share extension), and hands `UnwrapResult.url` to the classifier. The share
extension's `presentSavedOrReader` and `handleFriendShare`, and the paste
`saveNewWithContent` branch, all route through that same async `unwrap` instead
of re-implementing it — closing the §1 divergences.

---

## 4. Testability

**Pure / unit-testable today (keep):**
- `facebookRedirectTarget` — fbrpc target_url, l.php `u`, mobile host, non-http
  target rejection, FB-target rejection, the verbatim Messenger link.
- `appleNewsPublisherURL(inHTML:)` — redirect-call extraction, News+ nil,
  self-referential nil.
- `googleNewsArticleID(from:)` — rss/articles/read paths, non-article nil.
- `googleNewsURL(fromArticleID:)` + `firstEmbeddedHTTPURL` — classic decode,
  framing-byte stop, new-style nil.
- `googleBatchExecuteURL(fromResponse:)` — envelope parse, no-URL nil.
- host classifiers; `base64URLDecode`.

**Needs mocked `URLSession` / fixtures (currently untested):**
- `unwrap(_:session:)` end-to-end per wrapper (only the non-wrapper-returns-nil
  case is tested today).
- `unwrapAppleNews` (fetch + parse), `resolveFinalRedirect` (HEAD redirect host
  change vs same-host), `googleNewsBatchExecute` (two round-trips). All need a
  `URLProtocol` stub or injected mock session.

**Concrete test cases for the new design:**
- `unwrapOffline` resolves a real fbrpc Messenger link → TechCrunch http target
  (port the verbatim test) **and** a `CBMi…` Google-classic link offline, and
  leaves `apple.news` / `nyti.ms` untouched (those are `.fetch`).
- `unwrapOffline` on an ordinary `nytimes.com` URL → `didUnwrap == false`,
  same URL.
- `unwrap` (mock session): `apple.news/<id>` page → publisher URL; News+ page →
  unchanged. `news.google.com/rss/articles/<classic>` → offline publisher (no
  network hit asserted). `news.google.com/read/<new>` → batchexecute fixture →
  publisher. `https://t.co/x` → final cross-host URL; `t.co` that resolves back
  to `t.co` → unchanged (didUnwrap false).
- `l.facebook.com/l.php?u=…theverge…` and `m.facebook.com/l.php?u=…` → targets;
  `l.facebook.com/l.php?u=…facebook.com…` → unchanged.
- **Result is tracking-stripped:** fbrpc target with `fbclid` → `UnwrapResult.url`
  has no `fbclid` (today that only happens later in `canonicalForArchiving`).
- **Surface-parity regression tests:** assert the paste-with-content path and
  the friend-share path produce an unwrapped URL (these are the current bugs).

---

## Recommended target API

```swift
struct UnwrapResult { let url: URL; let didUnwrap: Bool; let wrapper: WrapperKind? }

enum UnwrapResolution { case immediate(URL?); case fetch((URLSession) async -> URL?) }

struct WrapperHandler {
    let kind: WrapperKind
    let matches: (_ scheme: String?, _ host: String?) -> Bool
    let resolve: (URL) -> UnwrapResolution
}

enum URLUnwrapper {
    /// EXTEND HERE: add a wrapper by appending a handler.
    static let handlers: [WrapperHandler] = [.facebook, .googleNews, .appleNews, .shorteners]

    /// THE one entry every surface calls once per incoming URL. Offline fast path
    /// inline; network only when a matched handler requires it. Tracking-stripped.
    static func unwrap(_ url: URL, session: URLSession = .shared) async -> UnwrapResult

    /// Offline-only, for input gates needing a real http(s) URL before their
    /// `hasPrefix("http")` check. Resolves `.immediate` handlers (FB, Google-classic);
    /// passes `.fetch` wrappers through for the async choke point to finish.
    static func unwrapOffline(_ url: URL) -> UnwrapResult
    static func unwrapOffline(_ string: String) -> String   // convenience for string gates
}
```

Migration: keep every pure parser as-is; replace the `if/else` ladder in
`unwrap` and the two FB normalize helpers with the registry + the two entries;
route `saveNewWithContent`, `handleFriendShare`, and both paste branches through
the single async `unwrap`; fold tracking-strip into the result.
