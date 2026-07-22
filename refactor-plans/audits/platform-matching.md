# Platform / URL-matching consolidation audit

Read-only investigation, no code changed. Follows on from
`refactor-plans/audits/ingest-pipeline.md` §2.2 A (host-suffix/domain matching
duplication + confirmed `PlatformRecognizer` vs. `LunaPlatforms` drift) and the
Wave-2 commit `66a9f069` ("Consolidate exact host-suffix and www-strip host
matching") that introduced `HostMatching` and left the `PlatformRecognizer` vs.
`XLink`/`RedditLink`/`InstagramLink` drift in place with pointer comments. This
report goes one level up the stack: not "how is a host suffix matched" but "which
implementation decides what platform/kind a URL is," across both Swift and the
Safari extension's JavaScript, and what it would take to get to exactly one Swift
implementation + one JS implementation (or zero JS, if native messaging can carry
the load).

**Bottom line up front:** Swift already has one canonical matcher —
`PlatformRecognizer` (`LunaURLClassification`) — and every real classification
decision in the app (ingest, media-download gating, paywall-bypass gating,
pasteboard suggestions) already goes through it or through `Classifier`/
`MediaDownloadablePlatform`, which themselves call it. The `XLink`/`RedditLink`/
`InstagramLink`/`TikTokLink`/`FacebookLink`/`BlueskyLink` types in `LunaPlatforms`
are NOT a second classification system — they're presentation-layer parsers
(subtitle text, deep-link construction, JSON-metadata URLs) that duplicate a
narrower version of the recognizer's host predicate as a side effect. Three of
the six have zero production callers today (see §1). The real second
implementation is the Safari extension's `content.js`, which reimplements
platform recognition, article/paywall/product detection, and Reddit
post-vs-feed gating from scratch in JS, cannot call the native handler
synchronously or per-DOM-mutation, and even recognizes three platforms
(Spotify, Apple Music, Apple Podcasts) that don't exist anywhere on the Swift
side at all — a live, concrete drift, not a hypothetical one.

---

## 1. Complete inventory

### 1.1 Swift — the canonical layer

**`PlatformRecognizer`** (`LunaLibraries/Sources/LunaURLClassification/PlatformRecognizer.swift`)
— the one declarative `[PlatformRule]` table, pure (no network/UIKit, compiles in
extensions). `recognize(_:)` (line 87) lowercases the host, builds
`PlatformURLParts` (host/segments/query/url), and returns the first rule whose
`hosts` suffix-match (via `HostMatching.hostSuffixMatches`, added in `66a9f069`)
AND whose `recognizes` closure accepts the URL. Rules (all lines in this file):

| Platform | Hosts (suffix-matched) | Path/id requirement | itemID when absent |
|---|---|---|---|
| `.x` (line 109) | `x.com`, `twitter.com` (+ any subdomain, e.g. `mobile.twitter.com`) | none — host match alone recognizes; `/status\|statuses/<numeric>` extracts an id | platform still recognized, `itemID: nil` |
| `.bluesky` (121) | `bsky.app` (+ subdomain) | **required**: `/profile/<author>/post/<rkey>` — a bare profile does NOT classify | n/a (unrecognized without a post) |
| `.reddit` (138) | `reddit.com`, `redd.it` (+ any subdomain, e.g. `i.redd.it`) | **required**: `/comments/<id>`, `/r\|user\|u/<name>/comments/<id>`, `/gallery/<id>`, `redd.it/<id>`, or app-native share `/r/<name>/s/<token>` — a bare subreddit/feed does NOT classify | share-token URLs recognize with `itemID: nil` (needs a redirect to resolve) |
| `.tiktok` (179) | `tiktok.com` (+ any subdomain, e.g. `vm.tiktok.com`, `vt.tiktok.com`) | none — `/video/<numeric>` extracts an id | recognized, `itemID: nil` |
| `.instagram` (189) | `instagram.com`, `instagr.am` (+ any subdomain) | none — `/(p\|reel\|reels\|tv)/<shortcode>` extracts an id | recognized, `itemID: nil` |
| `.facebook` (200) | `facebook.com`, `fb.watch`, `fb.com` (+ any subdomain) | none — `?v=` or `/reel\|videos/<id>` extracts an id | recognized, `itemID: nil` |

Callers of `PlatformRecognizer.recognize`/`.rules` (every production site, grep
`PlatformRecognizer\.` repo-wide):
- `LunaPlatforms/PlatformRegistry.swift:34` — `detect(_:)`, the UI-facing classify entry point.
- `LunaHTMLClassification/Classifier.swift:62,82` — the one platform row in
  `Classifier.knownSites` (maps `RecognizedPlatform` → `ContentKind.video`/`.social`);
  `platformHosts` (82) derives the row's host gate from `PlatformRecognizer.rules` directly.
- `LunaPaywallBypass/BypassGate.swift:92` — platform links are never
  paywall-bypassed (`.block(.platformLink)`).
- `LunaURLClassification/NonTextualContent.swift:14` — `NonTextualContent.detect`.
- `LunaMediaDownload/MediaDownload.swift:69` — `MediaDownloadablePlatform.supports`.
- `LunaMediaDownload/MediaAutoDownloader.swift:20,70,165` — auto-download
  enablement gate, App-Intent download gate, filename stem fallback.
- `LunaMediaDownload/SocialMediaResolver.swift:27,181,471,479` — dispatch to
  per-platform media resolution; Facebook plugin/canonical-URL re-checks; Reddit
  share-link redirect resolution.
- `LunaMediaDownload/LiveMediaDownloadManager.swift:554,621` — background
  download job resolution and Reddit share-link canonicalization.
- `LunaMediaDownload/SavedMediaStore.swift:332,352,404` — saved-media-library bookkeeping.
- `LunaReadingList/PasteboardSuggester.swift:123` — pre-save "this looks like a
  post" suggestion.
- `LunaTests/PlatformParsersTests.swift`, `SocialMediaResolverTests.swift` — pin exact behavior.

**`Classifier`** (`LunaHTMLClassification/Classifier.swift`) — the URL+HTML → `ContentKind`
decision used identically by ingest and every extension. Platform/video/social
rows run FIRST (before shop/news rows), deferring entirely to `PlatformRecognizer`
(no independent host logic of its own for platforms).

**`KnownSite`** (`LunaURLClassification/KnownSite.swift`) — declarative host(+path)→`ContentKind`
row type `Classifier.knownSites` is built from; `.matches` now calls
`HostMatching.hostSuffixMatches` (post-`66a9f069`). Not platform-specific — also
backs the shop/news rows.

**`MediaDownloadablePlatform`** (`LunaMediaDownload/MediaDownload.swift:63-72`) —
`supported: Set<ContentPlatform> = [.x, .instagram, .tiktok, .facebook, .reddit]`
(bluesky excluded — no downloadable media). `.supports(_:)` is a thin wrapper:
`PlatformRecognizer.recognize(urlString)?.platform` membership test. Callers:
`MediaDownloadService.swift:27,58,111`, `LiveMediaDownloadManager.swift:193`,
`MediaAutoDownloader.swift:21,72`, `LunaShareSurface/ShareSurfaceDriver.swift:303`,
`LunaShareSurface/SavedNonTextualViewController.swift:172,321`.

**`SocialMediaResolver`** (`LunaMediaDownload/SocialMediaResolver.swift`) — resolves
media assets. Its `resolveAssets(for:)` (line 26) dispatches purely on
`PlatformRecognizer.recognize(url.absoluteString)?.platform` — **no independent
platform predicate of its own**. The only host-substring checks in this file/its
siblings are for HTTP mechanics, not classification, and use yet a different,
looser algorithm (`.contains(...)`, not suffix-anchored):
  - `MediaDownloadService.referer(for:)` (`MediaDownloadService.swift:141-146`):
    `host.contains("tiktok")`, `host.contains("reddit") || host == "redd.it"` — picks
    a `Referer` header, not a classification decision.
  - `LiveMediaDownloadManager.swift:576`: `sourceURL.host?.contains("tiktok")` for
    the same Referer purpose.
  - `MediaAutoDownloader.swift:186-193` (`hostStem`): generic last-two-labels stem
    for a filename fallback, not platform-specific.
  These three are a **7th independent host-substring algorithm** (looser than
  `HostMatching`'s anchored-suffix match — `"faketiktok.com"` would false-positive
  `.contains("tiktok")`), but low-risk: they only pick an HTTP header/filename, never
  a routing/classification outcome, and only run after `PlatformRecognizer` has
  already classified the URL. Worth folding into `HostMatching` for
  consistency, not for correctness.

**Per-platform `LunaPlatforms` types — presentation helpers, not a second classifier:**

| Type | Production callers | What it actually does in prod | Own predicate vs. `PlatformRecognizer` |
|---|---|---|---|
| `XLink` (`XPlatform.swift:11-43`) | `XPlatform.subtitle` (52, via `.handle`), `.appDeepLink` (56, via `.appURL(tweetID:)`) | Extracts `@handle` for the subtitle line; builds `twitter://status?id=` deep link from an itemID already produced by `PlatformRecognizer` | **DRIFTS**: fixed 5-host `Set` (`x.com`,`www.x.com`,`twitter.com`,`www.twitter.com`,`mobile.twitter.com`), no suffix fallback, gates `.handle(from:)`. `PlatformRecognizer.x` suffix-matches ANY `x.com`/`twitter.com` subdomain. An accepted-by-ingest subdomain (e.g. some other `*.twitter.com`) would classify as X but show no author subtitle. `.appURL(tweetID:)` takes an id, not a URL — no host check, no drift. |
| `RedditLink` (`RedditPlatform.swift:11-48`) | `RedditPlatform.subtitle` (57, via `.subreddit`, which does **not** call `.isReddit` at all — pure path parse), `RedditMetadataFetcher.fetchMetadata` (68, via `.jsonURL`, which also does **not** call `.isReddit`) | Subreddit name for subtitle; builds the `.json` metadata URL | `.isReddit` (12-17) matches `redd.it` **exactly**, not its subdomains (`i.redd.it`) — drifts from `PlatformRecognizer.reddit`'s suffix match — but **neither production caller actually calls `.isReddit`**, so this drift is currently inert in prod. `.postID(from:)` (29, which DOES gate on `.isReddit`) has **zero production callers** (test-only). |
| `InstagramLink` (`InstagramPlatform.swift:10-27`) | **none** — `InstagramPlatform.subtitle`/`.appDeepLink`/`.embed` never call it | n/a today | `.isInstagram` (13-17) is `instagram.com`-only, explicitly narrower than `PlatformRecognizer.instagram` (also accepts `instagr.am`) per its own comment — but since nothing in production calls `InstagramLink` at all, this drift is dormant, exercised only by `LunaTests/PlatformParsersTests.swift`. |
| `TikTokLink` (`TikTokPlatform.swift:12-34`) | `TikTokPlatform.subtitle` (43, via `.handle`, which internally gates on `.isTikTok`) | Creator handle for subtitle | **No drift** — `.isTikTok` (`host == "tiktok.com" \|\| host.hasSuffix(".tiktok.com")`) is behaviorally identical to `PlatformRecognizer.tiktok`'s suffix match. |
| `FacebookLink` (`FacebookPlatform.swift:12-34`) | **none** — `FacebookPlatform.subtitle`/`.appDeepLink`/`.embed` never call it | n/a today | `.isFacebook`/`.itemID` duplicate `PlatformRecognizer.facebook`'s host set and id logic near-exactly (test-only today; no drift found, but redundant code). |
| `BlueskyLink` (`BlueskyLink.swift`) | `BlueskyPlatform.subtitle`/`.metadataFetcher` (author fallback), `BlueskySearchClient.swift:46` (`.webURL(fromATURI:authorHandle:)`) | Parses `/profile/<author>/post/<rkey>`; builds canonical web URLs both directions | Host set `{"bsky.app","www.bsky.app"}` — `PlatformRecognizer.bluesky` suffix-matches `bsky.app` (covers `www.` and beyond). Structurally same shape as the post-id extraction (`profile`/`post` segment check), independently written. Not called out as "confirmed drift" in the prior audit because behaviorally the two additional `www.` cases are covered either way, but it's the same duplicated-idiom pattern. |

`PlatformRegistry` (`LunaPlatforms/PlatformRegistry.swift`) is the module registry:
`detect(_:)` (33) delegates 100% to `PlatformRecognizer`; `module(for:)` (39) just
looks up the rendering module for a platform enum case — no matching logic.

`SocialPostFinder` (`LunaPlatforms/SocialPostFinder.swift`) — a DuckDuckGo-backed
best-match finder for a platform post given a handle/phrase, used by intents/UI
that need to locate a *specific* post (not classify an arbitrary URL). Its own
`Platform` enum (15-47) is a **third, independent host+path-marker table**
(`hosts`, `postMarkers`, `searchDomain`) covering only 4 platforms (x, tiktok,
instagram, facebook — no reddit/bluesky) with its own host list (e.g.
`instagram: ["instagram.com"]` — no `instagr.am`; `facebook: [...,"m.facebook.com"]`
— a host `PlatformRecognizer.facebook` doesn't suffix-match unless it happens to
be a `facebook.com` subdomain, which `m.facebook.com` is not). `bestMatch`
(98-107) does use `HostMatching.hostSuffixMatches` (post-`66a9f069`) for the
suffix test itself, but the host LIST and post-marker LIST are hand-maintained
separately from both `PlatformRecognizer` and the `LunaPlatforms` per-platform
`Link` types. This is a real, if low-traffic, fourth table.

**`LunaIngest.IngestPipeline`** does no platform matching of its own — it calls
`Classifier.classify`, which calls `PlatformRecognizer` (see `IngestPipeline.swift`
around the `.video`/`.social` outcome cases, 217-226).

### 1.2 JavaScript / native — `LunaSafari/`

Full inventory of every file in `LunaSafari/`:

- **`Resources/content.js`** (1160 lines) — the only file that does platform/kind
  matching. Runs as a `content_scripts` injection is NOT declared in
  `manifest.json` (only `annoyances.js`/`annoyances.css` are `document_start`
  content scripts); `content.js` + the generated `news_hosts.generated.js` are
  injected programmatically by `background.js`'s `injectContentScript`
  (`browser.scripting.executeScript`, `tabs.onUpdated` with `status === "complete"`),
  i.e. once per fully-loaded page, into the page's own JS world.
  - `recognizedPlatformPage()` (876-898) — **a full second platform-URL table**,
    independent of `PlatformRecognizer`: `x` (`x.com`/`twitter.com`), `bluesky`
    (`bsky.app` + `/post/` segment), `reddit` (`reddit.com`/`redd.it` +
    `currentRedditPostID()` gate — mirrors `PlatformRecognizer.reddit`'s
    `recognizes` gate per its own comment at 884-887), `tiktok`, `instagram`
    (+ `instagr.am`), `facebook` (+ `fb.com`, `fb.watch`) — **plus `spotify`,
    `appleMusic` (`music.apple.com`), `applePodcasts` (`podcasts.apple.com`),
    which have NO Swift counterpart anywhere** (see §2, this is the single
    concrete new finding of this audit).
  - `hostMatches(host, roots)` (1120-1125) — its own from-scratch reimplementation
    of the exact `HostMatching.hostSuffixMatches` idiom (`host === root ||
    host.slice(-("." + root).length) === "." + root`), the **8th** independent
    implementation of this idiom counting the Swift side's now-consolidated one.
  - `redditPostID(segments)`/`currentRedditPostID()`/`isRedditHost()`
    (981-1013) — a JS port of `PlatformRecognizer.redditPostID`'s structural
    path-segment matching (comments/r/user/u/gallery), independently written,
    explicitly commented as mirroring it.
  - `isKnownArticleHost()`/`isKnownHardPaywallHost()` (298-310) — reads
    `self.__LUNA_NEWS_HOSTS`, populated by the **generated, checked-in**
    `news_hosts.generated.js` (see §4 precedent) — this one IS kept in lockstep
    today, via `NewsSitesJSParityTests`.
  - `looksLikeArticle()`/`isArticlePage()`/`looksLikeNonArticleIndex()`
    (227-397) — an independent Readability-style DOM scorer; no Swift
    equivalent runs client-side in Safari (the real `ArticleExtractor` only runs
    after the URL is saved into the app), so this isn't "drift" against a Swift
    twin so much as a parallel, JS-only heuristic explicitly documented as a
    *fallback* ("On save the app re-classifies properly via LunaIngest").
  - `looksPaywalled()` (525-542) + `GATE_MARKERS` (18-30) — **explicitly
    commented "Mirrors PaywallDetector.gateMarkers (Swift) — keep in sync"** —
    a hand-copied literal array of ~24 gate phrases, not generated, not tested
    for parity.
  - `looksLikeProductPage()` + `urlIsMultiProductListing()` +
    `urlLooksLikeProduct()` + JSON-LD walkers (544-734) — **explicitly commented
    "Mirrors ProductPageDetector (Swift) — keep in sync"** — a hand-copied,
    independently-written subset of `ProductPageDetector`'s logic (URL patterns,
    JSON-LD offer walk, microdata, add-to-cart/rating heuristics), again not
    generated or parity-tested.
  - `redditPostHasMedia()`/gating (1015-1048) — Reddit-specific "is this post's
    primary content animated" gate, no Swift twin (the real media-download
    resolution only happens after the URL is handed to the app).
  - Used for: (a) whether to inject the "Read in Luna" / "Download in Luna" /
    "Track in Luna" floating button (all three are the SAME code path,
    `injectLunaButton`, just different `target` builders — `readTarget`,
    `downloadTargetFor`, `trackTargetFor`, 799-863); (b) which of the three
    `luna{reader,downloader,pricetracker}://` custom-scheme deep links (or App
    Clip / App Store fallback URL) the button opens; (c) whether to reveal a
    paywalled article in Safari itself (`revealArticle()`, declarative-net-request
    driven, no button); (d) Reddit's SPA soft-nav watcher (poll every 1000ms,
    `setInterval`) to add/remove the pill as the user navigates feed↔post.
    **Never** a badge/context-menu — it's exclusively a floating in-page button
    plus a `declarativeNetRequest` ruleset toggle.

- **`Resources/background.js`** (202 lines) — runs in the extension's (non-persistent)
  background page. Does **no** platform/host matching of its own. Responsibilities:
  relay `browser.tabs` URL changes to the native handler (`report`, 34-41, for the
  SaveLink intent's "active Safari tab" feature); inject `content.js` +
  `news_hosts.generated.js` per completed page load (`injectContentScript`, 43-52);
  toggle the two `declarativeNetRequest` rulesets (`referer`, `blockers`) on/off
  based on the native handler's `bypassEnabled` answer (`syncBypassRuleset`,
  22-32); relay `content.js`'s `sendMessage` calls to
  `browser.runtime.sendNativeMessage` (content scripts can't call
  `sendNativeMessage` directly — background.js is the required relay, 156-197);
  drive the one-shot onboarding takeover overlay.

- **`Resources/annoyances.js`/`annoyances.css`** — generic cosmetic
  cookie-banner/overlay cleanup, declared as an actual Manifest V3
  `content_scripts` entry (`document_start`, `all_frames`, every URL). No host or
  platform matching at all (grepped — zero `hostname`/`location.`/`host ==` hits).

- **`Resources/manifest.json`** — MV3 manifest. `host_permissions: ["<all_urls>"]`,
  `nativeMessaging`/`tabs`/`scripting`/`declarativeNetRequest*` permissions. Only
  `annoyances.*` is a declared content script; `content.js` is injected
  programmatically (see above) so it can be paired with the generated news-hosts
  file and so it only runs after `document_complete`.

- **`Resources/news_hosts.generated.js`** — **generated artifact**, header:
  "GENERATED from NewsSites.swift (LunaURLClassification) by
  NewsSitesJSParityTests. Do NOT edit by hand." Populates
  `self.__LUNA_NEWS_HOSTS = {hardPaywall:[...], free:[...]}` directly from
  `NewsSites.hardPaywall`/`.free` (Swift arrays), regenerated via
  `TEST_RUNNER_RECORD_NEWS_HOSTS=1 xcodebuild test …`. This is the ONE
  matching-related JS artifact that is provably byte-identical to its Swift
  source today, and the precedent for §4/§5's recommendation.

- **`Resources/rules_referer.json`** (30 lines) / **`rules_blockers.json`** —
  `declarativeNetRequest` static rulesets: per-host `Referer` header rewrites and
  metering-script blocks, generated from `site_unlock_rules.json`
  (`LunaPaywallBypass/Resources/`) by `scripts/generate_safari_blocker_rules.js`.
  Host matching here is declarative browser-native matching (`requestDomains`),
  not app JS — out of scope for "platform recognition" but the same
  keep-in-lockstep-via-generation pattern as `news_hosts.generated.js`.

- **`SafariWebExtensionHandler.swift`** (native, `NSExtensionRequestHandling`) —
  **does zero URL/platform matching**. It only: reads a handful of
  `UserDefaults(suiteName: SafariAppGroup.id)` flags and `Info.plist` strings
  (suggestion mode, App-Clip/App-Store URLs, sibling-app-installed markers) and
  answers `{ mode, isDownloaderHost, readerInstalled, downloaderInstalled,
  priceTrackerInstalled, readerAppClipURL, downloaderAppClipURL,
  priceTrackerAppStoreURL }` for `buttonContext`; answers a hardcoded
  `{enabled: true}` for `bypassEnabled`; records unlocked HTML
  (`SharedSafariURL.recordUnlockedContent`) for `saveContent`; records/consumes
  onboarding-takeover state; records the plain active-tab URL by default. One
  `beginRequest` call = one message = one response, synchronous within that
  call but each `browser.runtime.sendNativeMessage` from JS is itself async
  (Promise-based, real process-hop latency — see §3).

- **`SafariAppGroup.swift`** — reads `LunaAppGroupID` from its OWN Info.plist
  (mirrors `LunaAppConfig.AppConfig`, since this target links no Swift package —
  confirmed: `grep -rn "import Luna" LunaSafari/*.swift` → zero hits). This is the
  **only** App-Group access pattern the native handler has; it never touches
  `ReadingListStore`/`LunaURLClassification`/`LunaPlatforms` — those aren't
  linked into the extension target at all (confirmed via `project.pbxproj` and
  a repo-wide import grep).

- **`SharedOnboardingStatus.swift`/`SharedSafariURL.swift`** — thin App-Group
  read/write wrappers (onboarding takeover flag, active-tab URL, unlocked-HTML
  cache). No matching logic.

- **`LunaSafari.entitlements`/`Info.plist`** — App Group entitlement + the
  App-Clip/App-Store URL keys read above. Not matching-related.

---

## 2. Drift matrix

| URL example | `PlatformRecognizer` (Swift, canonical) | `LunaPlatforms` per-file `XxxLink` (Swift, presentation) | `content.js` `recognizedPlatformPage()` | Which is "right" per what the caller actually DOES |
|---|---|---|---|---|
| `https://instagr.am/p/AbC123/` | Recognized as `.instagram`, itemID `AbC123` (ingest classifies it as social, media-download works, price/article never considered) | `InstagramLink.isInstagram` → **false** (not called in prod anyway) | `recognizedPlatformPage()` — **not matched** (`hostMatches(host, ["instagram.com","instagr.am"])` line 890 — **actually IS covered in JS**) | `PlatformRecognizer` and JS agree; the Swift `InstagramLink` mismatch is inert (dead code path) — no live bug. |
| `https://mobile.twitter.com/user/status/123` | Recognized (`twitter.com` suffix — `mobile.twitter.com` matches) | `XLink.handle`/`.appURL` → recognized (hardcoded 5-host set includes `mobile.twitter.com` explicitly) | `hostMatches(host, ["x.com","twitter.com"])` → recognized | All three agree here (this exact host was special-cased into `XLink`'s fixed set). |
| `https://some-other.twitter.com/user/status/123` (a hypothetical subdomain) | Recognized (suffix match) | `XLink.handle`/`.appURL` → **not recognized** (not in the 5-host set) → subtitle/deep-link both silently blank | JS `hostMatches` → recognized, download-adjacent pill would show (JS doesn't render tweet subtitle, N/A) | **`PlatformRecognizer` is right** — ingest already saved it as X; `XPlatform.subtitle` should show the handle. This is the one **live, real** Swift-side drift from the prior audit (§2.2 A), still present, still only cosmetic (missing subtitle/deep-link, not a misclassification). |
| `https://i.redd.it/abc.jpg` (no post path) | **Not** recognized as a post (no `/comments/`, no share token — `i.redd.it` alone doesn't satisfy `reddit`'s `recognizes` gate) | `RedditLink.isReddit` → true (suffix-matches `redd.it`) — but `.isReddit` has no production caller | JS: `isRedditHost()` true, but `currentRedditPostID()` → null → not "reddit" in `recognizedPlatformPage` (correctly falls to `handleReddit` feed-suppression path) | All three agree in outcome (not a post) even though `RedditLink.isReddit`'s looser predicate differs — again inert since nothing calls it in prod. |
| `https://redd.it/1abc2d` | Recognized, itemID `1abc2d` | `RedditLink.postID` would work (test-only, unused in prod); `.subreddit`/`.jsonURL` don't gate on host at all | JS: `currentRedditPostID` → `nonEmptySegment(segments[0])` → matches | Agree. |
| `https://open.spotify.com/track/...` | **Not recognized at all** — no `.spotify` case exists in `ContentPlatform` (`LunaModels/ContentModels.swift:3` has exactly 6 cases: x, bluesky, reddit, tiktok, instagram, facebook) | n/a | `recognizedPlatformPage()` → `"spotify"` (line 892) | **Concrete live bug.** Safari shows a "Download in Luna" pill and deep-links `lunadownloader://read?url=...`. Once the URL lands in the app, `IngestPipeline`/`Classifier`/`MediaDownloadablePlatform` have no idea what it is — `PlatformRecognizer.recognize` returns nil, so it falls through to ordinary shop/news/article classification (almost certainly `.undetermined` or a bare-link save), and `MediaDownloadablePlatform.supports` is false, so no media-download UI ever appears in the app. The Safari-side promise ("Download in Luna") is broken by the time the app gets the URL. |
| `https://music.apple.com/...` / `https://podcasts.apple.com/...` | Not recognized | n/a | `recognizedPlatformPage()` → `"appleMusic"` / `"applePodcasts"` (894-896) | Same live bug as Spotify — JS invents 3 whole platforms Swift has never heard of. |
| `https://m.facebook.com/watch/?v=123` | Recognized — `facebook.com` suffix (via `.facebook.com`? **No** — `m.facebook.com` IS a `facebook.com` subdomain, so `hostSuffixMatches` succeeds) | `FacebookLink.isFacebook` — same suffix logic, would also match (unused in prod) | `hostMatches(host, ["facebook.com","fb.com"])` → matches | Agree. |
| `https://www.facebook.com/...` via `SocialPostFinder` post-search | `PlatformRecognizer` would classify a found URL normally | n/a | n/a | `SocialPostFinder.Platform.facebook.hosts` includes `m.facebook.com` as a literal separate entry (redundant given suffix matching already covers it) — harmless but shows the 4th table's host list was hand-copied, not derived. |
| `https://vm.tiktok.com/ZM1234/` (short link) | Recognized, itemID nil (opaque) | `TikTokLink.isTikTok` → true (identical suffix logic, used via `.handle`) | `hostMatches(host, ["tiktok.com"])` → matches | All agree. |

**Net assessment:** the Swift-side drift flagged in the prior audit (§2.2 A) is
real but almost entirely **inert in production** today — `InstagramLink` and
`FacebookLink` have zero callers outside tests, and `RedditLink`'s drifted
predicate (`isReddit`) is never invoked by the one production caller
(`.subreddit`, which skips the gate). Only `XLink`'s fixed 5-host set is a live
(if cosmetic — missing subtitle only) drift. The **actually damaging** drift in
this audit is JS-vs-Swift: three platforms Safari's content script invents
(Spotify/Apple Music/Apple Podcasts) that silently fail once the deep link
reaches the app.

---

## 3. Safari extension architecture

**What the matching is FOR:** exclusively an in-page floating button
(`injectLunaButton`, one `<div role=button>` element, bottom-right) whose label
and target URL depend on what kind of page it is — never a toolbar badge, never
a context (right-click) menu, never an address-bar suggestion. Three mutually
exclusive outcomes per page: "📖 Read in Luna" → `lunareader://read?url=`,
"Download in Luna" → `lunadownloader://read?url=`, "Track in Luna" →
`lunapricetracker://read?url=` (or, per-target, an App Clip URL / the Price
Tracker App Store page when the owning app isn't installed). Separately (no
button involved), `revealArticle()` strips known paywall-overlay DOM when the
app's on-device unlock is enabled, and `declarativeNetRequest` rulesets rewrite
`Referer`/block metering scripts declaratively (browser-native matching, not JS).

**Where it runs:** `content.js` executes **inside the loaded web page's own JS
world** (`browser.scripting.executeScript` from `background.js`, fired on
`tabs.onUpdated` when `changeInfo.status === "complete"` — i.e. once per fully
loaded page, not per DOM mutation initially) — but Reddit additionally runs a
**client-side `setInterval` poll every 1000ms** (`startRedditNavWatcher`,
line 1099-1108) for the lifetime of the tab, to catch SPA soft-navigation
(feed→post→feed with no full page load), plus up to 4 bounded 1500ms retries
per navigation while waiting for `<shreddit-post>` to hydrate
(`attemptRedditInjection`, 1079-1094). `background.js` itself runs in the
**non-persistent MV3 background service worker/page** — it does no per-page
matching, only routing/injection/relay.

**Native-messaging viability — the concrete constraint:**
- Every `browser.runtime.sendNativeMessage` call is a real **process hop**:
  content script → (relay through background.js, since content scripts can't
  call `sendNativeMessage` directly, confirmed at `background.js:156-197`) →
  the `SafariWebExtensionHandler` extension process → `NSExtensionContext`
  round trip → back. This is genuinely async (Promise-based) with real,
  variable latency (extension process wake-up if not already warm) — not a
  same-thread synchronous call.
- Today `content.js` makes **exactly two** native round trips per page load
  (`buttonContext`, `bypassEnabled`, both fired once at content-script
  startup, 36 and 82) plus one more only on a button tap (`saveContent`,
  786-787). **Zero** of the platform/article/product/paywall-marker
  *matching* itself goes over native messaging — it's 100% synchronous
  in-page JS against `document`/`location`, by design, because:
  - The Reddit soft-nav watcher alone would need a native round trip every
    ~1000ms for as long as the tab stays open, times every open Reddit tab —
    both a real latency/jank risk (the pill visibly lagging behind navigation)
    and needless extension-process wake churn.
  - `looksLikeArticle`/`looksLikeProductPage`/`redditPostHasMedia` all read
    live DOM state (`document.querySelectorAll`, `innerText`, JSON-LD
    `<script>` content) that would have to be **serialized and shipped** to
    the native process on every check — for a full modern page this is
    exactly the same size problem `capturedHTML()` already has to solve for
    `saveContent` (a raw `outerHTML` can exceed native messaging's ~1.5MB
    practical budget, per that function's own comment, 1127-1133) — except
    matching needs to run far more often than the one-time "unlocked HTML"
    hand-off.
  - Native messaging in Safari Web Extensions has no push/streaming
    channel — every check would be a fresh request/response round trip,
    there's no way to keep a live subscription open from the extension
    process into the content script.
- **What native messaging IS good for and already used for here:** small,
  infrequent, app-state questions that only the app process can answer —
  "is Reader/Downloader/PriceTracker installed," "what's the current
  suggestion mode," "is on-device unlock enabled," "here's the unlocked HTML,
  please store it." All of `buttonContext`/`bypassEnabled`/`saveContent`/
  `onboardingStatus` fit this shape exactly (App-Group-backed state, asked
  once or on a real user action) — and this is precisely how
  `SafariWebExtensionHandler` reads the App Group today (`UserDefaults(suiteName:
  SafariAppGroup.id)`, `Info.plist` keys — see §1.2), which is the existing
  precedent for "native call for cross-process state," not "native call for
  per-page URL classification."

**Conclusion: JS matching logic must remain.** Moving `recognizedPlatformPage`/
`isArticlePage`/`looksLikeProductPage`/`looksPaywalled`/the Reddit gating into
native-message round trips would either (a) serialize and ship substantial page
content on every check — a bandwidth/latency non-starter at the frequency these
run (once per load minimum, every ~1s on Reddit), or (b) require the native
extension process to somehow evaluate `document`/`location` itself, which it
cannot — it has no DOM access; only the content script, running in the page's
own JS context, can read the page. A pure URL-only check (no DOM) COULD in
principle go over native messaging, but even that would add real per-page
latency to `recognizedPlatformPage`'s classification path, which today is a
synchronous string operation with zero I/O — there's no benefit to paying a
process-hop for a check libssl-in-JS can already do byte-identically. **The
target design (§4) must therefore keep exactly one JS implementation**, not
zero.

---

## 4. Recommended target design

### 4.1 One canonical Swift matcher — already exists, needs one extension

`PlatformRecognizer` (`LunaURLClassification`) already IS the single Swift
source of truth for platform recognition, and — per `Package.swift` — every
module that needs it already depends on `LunaURLClassification` directly
(`LunaHTMLClassification`, `LunaPaywallBypass`, `LunaPlatforms`,
`LunaMediaDownload`, `LunaReadingList` all declare it; `LunaURLClassification`
itself depends on nothing but `LunaModels`). **No module move is needed** — this
is not a case of the canonical matcher living in the wrong layer; it's already
at the bottom of the stack, below everything that consumes it. What's missing:

1. **Add the 3 orphan platforms JS already recognizes.** `ContentPlatform`
   (`LunaModels/ContentModels.swift:3`) needs `.spotify`/`.appleMusic`/
   `.applePodcasts` cases (or a decision that Luna intentionally doesn't handle
   them, in which case JS should stop promising a working button for them —
   see §5). Given `content.js` already has real host/path logic for all three
   (892-896), the cheapest correct fix is porting that logic into 3 new
   `PlatformRule`s in `PlatformRecognizer.rules` (they're social/audio, not
   video/downloadable-media, so `MediaDownloadablePlatform.supported` should
   NOT include them unless media download is actually being added for them —
   that's a product decision, not this audit's call).
2. **Retire the five/six duplicate presentation-layer predicates** in
   `LunaPlatforms` (`XLink.hosts`, `RedditLink.isReddit`, `InstagramLink.isInstagram`,
   `TikTokLink.isTikTok`, `FacebookLink.isFacebook`, `BlueskyLink.hosts`) in favor
   of calling `PlatformRecognizer.recognize(urlString)?.platform == .x` (etc.)
   directly, or — better, since these files already receive an `itemID` from
   ingest-time recognition — restructure `XPlatform.subtitle`/`.appDeepLink` etc.
   to take the already-recognized `RecognizedPlatform`/itemID as a parameter
   instead of re-parsing `item.urlString` from scratch. This removes the
   duplicate host tables entirely rather than just fixing their predicates to
   match (which would leave 6 files independently agreeing with a 7th).
3. **Fold `SocialPostFinder.Platform`'s host/marker table into
   `PlatformRecognizer`.** Its `hosts`/`searchDomain` fields are redundant with
   `PlatformRule.hosts`; its `postMarkers` (URL path fragments marking a post
   vs. profile/home) are a genuinely new concept worth adding as a
   `PlatformRule.postMarkers: [String]` (or exposing `PlatformRule.recognizes`
   itself, since that's already the "is this a post" gate for reddit/bluesky) —
   either way, one table, not two.
4. **API surface for the canonical matcher should cover** (mostly already true):
   `recognize(_:) -> RecognizedPlatform?` (have it); a canonical-URL builder per
   platform (`webURL(author:rkey:)`-style — currently scattered per-`Link` type,
   e.g. `BlueskyLink.webURL`, worth centralizing under
   `PlatformRecognizer`/`PlatformRule` too, though lower priority); and — new —
   a way to ask "is this host on ANY platform" cheaply for the content-script's
   generated-table use case (`Classifier.platformHosts`, `PlatformRecognizer.swift:82`,
   already does exactly this and is the model for §4.2's generated JS file).

### 4.2 Keeping the one remaining JS implementation in lockstep

The repo already has the exact precedent needed, twice over:

- **`news_hosts.generated.js`** — a build-time-generated (well, test-time — see
  `NewsSitesJSParityTests.swift`) JS artifact, checked in, with a header
  comment forbidding hand edits, produced directly from the compiled Swift
  arrays (`NewsSites.hardPaywall`/`.free`) — never by string-parsing the
  `.swift` source. A companion XCTest (`testGeneratedArtifactMatchesNewsSites`)
  asserts the committed file is byte-identical to freshly-generated content and
  fails with a re-record hint (`TEST_RUNNER_RECORD_NEWS_HOSTS=1 xcodebuild
  test …`) on drift.
- **`site_unlock_rules.json` → `rules_referer.json`/`rules_blockers.json`** — a
  Node script (`scripts/generate_safari_blocker_rules.js`) converts the Swift
  paywall-bypass rule JSON into the `declarativeNetRequest` ruleset format Safari
  needs — same "one source of truth, mechanically projected into the shape the
  other runtime needs" pattern, just JSON→JSON instead of Swift-const→JS-const.

**Recommended: extend the `NewsSitesJSParityTests` pattern to platform
recognition.** Concretely:
- Add a `self.__LUNA_PLATFORM_RULES` generated file (e.g.
  `platform_rules.generated.js`), produced the same way (a new
  `PlatformRecognizerJSParityTests.swift`, or extend
  `NewsSitesJSParityTests`), containing each platform's host list AND enough of
  the path/id shape to drive `content.js`'s `recognizedPlatformPage()` — at
  minimum the host lists (mechanical, safe to generate) even if the
  post-vs-profile path logic (Reddit's `recognizes` gate, Bluesky's `/post/`
  requirement) stays hand-written in JS since it's genuinely control-flow, not
  data — same split `news_hosts.generated.js` already uses (data is generated,
  the two `isKnownArticleHost`/`isKnownHardPaywallHost` predicate FUNCTIONS
  that consume it are hand-written but trivial/stable).
- This closes the Spotify/Apple-Music/Podcasts gap the moment those 3 rules
  are added to `PlatformRecognizer` (§4.1 item 1) — regenerating the JS file
  would either add them to Swift's table (making JS and Swift agree) or, if the
  product decision is "Luna doesn't support these," immediately surface the 3
  hardcoded JS entries as no longer backed by anything, prompting their
  deletion from `content.js` instead of leaving them silently broken.
- The paywall-marker list (`GATE_MARKERS`, 18 lines, `content.js:18-30`) and the
  product-detection subset (`looksLikeProductPage` et al., 544-734) are
  currently **hand-copied with a "keep in sync" comment and no test** — lower
  priority than platform hosts (they're heuristic scorers, not exact-match
  tables, so a generator is a bigger lift), but the same
  generate-from-Swift-data pattern applies to at least the exact-list parts
  (`GATE_MARKERS` could be generated from `PaywallDetector`'s gate-marker
  constant the same way `news_hosts.generated.js` is, even though the
  surrounding scoring logic stays hand-written JS on both sides). Flagged here,
  not solved — this audit's mandate is platform/URL matching specifically.

---

## 5. Migration list

**Move to the canonical matcher (behavior changes are explicit and intentional per the user's authorization):**

1. **`XPlatform.subtitle`/`.appDeepLink`** (`XPlatform.swift:51-57`) — stop
   calling `XLink.handle`/gating on the fixed 5-host set; use the
   already-recognized platform match (ingest already ran `PlatformRecognizer`
   to get here) or call `PlatformRecognizer.recognize` directly for the host
   check, then keep `XLink`'s pure `/status/` segment-parsing for the handle
   extraction itself (that part isn't host-gated and has no drift).
   **Behavior change:** an X/Twitter subdomain outside the old 5-host set
   (there's no evidence one exists in real data, per the prior audit) would
   newly show a subtitle/deep-link instead of silently showing neither.
2. **Delete `InstagramLink.isInstagram`/`FacebookLink.isFacebook`** (dead in
   production) and replace their test coverage
   (`LunaTests/PlatformParsersTests.swift` lines 81-93) with equivalent
   assertions against `PlatformRecognizer.recognize` directly, OR keep the
   pure shortcode/itemID extraction and simply stop it from independently
   re-deciding "is this the platform" (delete `.isInstagram`/`.isFacebook`,
   have `.shortcode`/`.itemID` take a pre-validated URL or an already-known
   `RecognizedPlatform`). **No prod behavior change** (nothing calls the
   deleted predicates today) — purely dead-code removal per ingest-pipeline
   audit item 2.4, extended here with the platform-specific confirmation.
3. **`RedditLink.isReddit`/`.postID`** — same treatment: `.postID` has zero
   production callers; either delete it or repoint it at
   `PlatformRecognizer.recognize(_:)?.itemID` for the id and drop the
   redundant `isReddit` gate. `.subreddit`/`.jsonURL` (the two actually-used
   methods) don't gate on host at all today and can stay as-is — they're safe
   pure path/URL builders once a platform match is already established.
4. **`TikTokLink.isTikTok`** — no behavior change needed (already agrees with
   `PlatformRecognizer`), but worth replacing with a direct
   `PlatformRecognizer` call anyway so there's only one host table left to
   maintain, not two that happen to agree today.
5. **`BlueskyLink`'s `hosts` set** (`BlueskyLink.swift:11`) — replace
   `{"bsky.app","www.bsky.app"}` membership test with
   `HostMatching.hostSuffixMatches(host, "bsky.app")` (or route through
   `PlatformRecognizer` and keep only the post-path parsing here).
   **No observable behavior change** (suffix match is a superset that already
   covers both listed hosts).
6. **`SocialPostFinder.Platform`** (`SocialPostFinder.swift:15-47`) — replace
   the hand-maintained `hosts`/`searchDomain` with a lookup against
   `PlatformRecognizer.rules` (filtered to x/tiktok/instagram/facebook), and
   promote `postMarkers` to a `PlatformRule` field or equivalent shared table.
   **Behavior change:** `facebook.hosts` currently includes `m.facebook.com`
   explicitly (redundant, already covered by `facebook.com` suffix matching) —
   removing the explicit entry changes nothing observable; but reddit and
   bluesky aren't in `SocialPostFinder.Platform` at all today (it only handles
   x/tiktok/instagram/facebook, by design — no behavior change there, just
   noting the table won't magically cover reddit/bluesky search just because
   it's unified with `PlatformRecognizer`, since `findPostURL` itself has no
   reddit/bluesky call sites to add).
7. **`MediaDownloadService.referer`/`LiveMediaDownloadManager`'s
   `.contains("tiktok")`/`.contains("reddit")` substring checks** — fold into
   `HostMatching` (e.g. add a non-anchored `HostMatching.hostContains` if the
   substring behavior is intentionally kept, or switch to
   `hostSuffixMatches(host, "tiktok.com")` if the substring looseness was never
   intentional). **Possible behavior change:** switching to anchored suffix
   matching would stop a hypothetical `faketiktok.com`/`myreddit.example.com`
   from spuriously getting the TikTok/Reddit `Referer` header — vanishingly
   unlikely in practice but worth naming since it's a real semantic tightening.
8. **Add `.spotify`/`.appleMusic`/`.applePodcasts` to `ContentPlatform` +
   `PlatformRecognizer.rules`** (or explicitly decide not to and instead delete
   the 3 JS-only entries in `recognizedPlatformPage`, `content.js:892-896`).
   **This is the one migration item with real user-facing behavior today**:
   currently tapping "Download in Luna" on a Spotify/Apple Music/Podcasts page
   opens Luna Downloader with a URL the app cannot classify or download media
   from. Either direction (add Swift support, or remove the JS entries) is a
   genuine behavior change from what ships today — this audit surfaces the gap
   but doesn't adjudicate which way to close it (that's a product call: does
   Luna Downloader intend to support audio-platform links at all?).
9. **Generate `platform_rules.generated.js`** (new) from
   `PlatformRecognizer.rules`'s host lists, mirroring
   `news_hosts.generated.js`/`NewsSitesJSParityTests`, and repoint
   `recognizedPlatformPage()`'s hardcoded host arrays (`content.js:882-896`) to
   read from it, the same way `isKnownArticleHost` reads
   `self.__LUNA_NEWS_HOSTS`. **No behavior change** if done correctly (the
   generated lists must match what's hardcoded today, verified by the parity
   test's first run); it converts today's "silent hand-copy" into "test-enforced
   parity," which is the actual point of this migration.
10. **`content.js`'s `hostMatches`** (1120-1125) — leave as hand-written JS
    (it's a 4-line pure function, not data, so generation doesn't apply — its
    correctness is what the parity test in item 9 indirectly protects: if the
    generated host list and `hostMatches`'s algorithm disagree with Swift's
    `HostMatching.hostSuffixMatches`, wrong entries would show up as
    class-of-URL misclassifications the parity test can catch by construction
    if the test also asserts on sample URLs, not just the raw list).

**Not recommended to move:** `GATE_MARKERS`/`looksPaywalled`/
`looksLikeProductPage`/`looksLikeArticle` in `content.js` — these are DOM/HTML
heuristics with no practical way to run over native messaging (§3), and
generating them from Swift is a materially bigger lift than the host-list case
(the Swift originals are procedural code, not data tables) — out of this
audit's scope, flagged in §4.2 as a follow-up, not a migration item.
