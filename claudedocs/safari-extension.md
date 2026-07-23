# LunaSafari — Safari Web Extension

Tracks the URL of the active Safari tab and persists it so the SaveLink intent can save "the page I'm looking at" without any UI.

## Flow

```
background.js (tabs.onActivated / tabs.onUpdated)
  → browser.runtime.sendNativeMessage("application.id", {url})
  → SafariWebExtensionHandler (extension process, NSExtensionRequestHandling)
  → App Group UserDefaults (group.com.hsanabria.luna): lastSafariURL, lastSafariURLDate
  → read by SafariURLStore (app; the Provide Context intent's fresh-URL save)
```

## Key files

- `LunaSafari/Resources/manifest.json` — MV3; `background.page` (event page — iOS kills MV3 service workers) **with `"persistent": false`** and a numeric-keyed `icons` map — both are REQUIRED by App Store Connect upload validation (ITMS error 90849 otherwise); permissions `nativeMessaging`, `tabs`; `host_permissions: <all_urls>` (needed to read tab URLs; user grants "All Websites").
- `LunaSafari/Resources/background.js` — listens `tabs.onActivated` + `tabs.onUpdated` (active tab, url change or load complete), dedupes, sends native message.
- `LunaSafari/Resources/annoyances.css` + `annoyances.js` — declarative, all-frame
  `document_start` suppression for cookie consent and intrusive popovers; intentionally
  leaves ordinary inline/display ads intact.
- `LunaSafari/SafariWebExtensionHandler.swift` — principal class (`NSExtensionPointIdentifier = com.apple.Safari.web-extension` in `LunaSafari/Info.plist`); writes via `SharedSafariURL`.
- `LunaSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — no shared framework in this small project).

Target: `LunaSafari`, bundle `com.hsanabria.luna.safari`, app-extension product embedded in Luna.app/PlugIns. Resources flatten into the appex root (Safari requires manifest.json at bundle root on iOS).

## Annoyance suppression (not an ad blocker)

The extension hides cookie dialogs and intrusive overlays before first paint without
turning Luna into a general ad blocker. `manifest.json` declaratively loads
`annoyances.css` and `annoyances.js` at `document_start` on every HTTP(S) frame (including
about:blank child frames). This is separate from the later, programmatic `content.js`
injection used by the Luna action pill.

- **Before-paint layer:** `annoyances.css` contains a compact set of stable CMP container
  selectors (OneTrust, Cookiebot, Didomi, Sourcepoint, TrustArc, Osano, CookieYes,
  Complianz, Klaro, and common cookie/consent banner names). Safari applies it before page
  content renders, so known dialogs do not flash while JavaScript waits for hydration.
- **Privacy-preserving consent:** `annoyances.js` clicks a CMP's explicit reject action or
  an exact localized `Reject all` / `Necessary only` equivalent. It never clicks an
  accept action and does not guess from vague labels such as “Continue” or “Save.” It
  retries briefly because server-rendered banners can exist before their framework has
  attached click handlers. When no safe reject action exists, the notice is hidden and
  scrolling is restored, but Luna does not fabricate a consent string or enable optional
  cookies.
- **Late and unfamiliar UI:** a MutationObserver begins at `document_start`, before the
  first page paint, and handles DOM-hydrated CMPs plus open shadow roots. Its generic
  popover fallback requires BOTH overlay structure (`dialog`/`aria-modal`, an overlay
  name plus fixed positioning, or substantial fixed viewport coverage) and narrow
  annoyance language for newsletter capture, push notifications, app-install prompts,
  surveys, ad-block nags, or ad interstitials.
- **Safety boundary:** no network rule or cosmetic selector targets ad slots, ad iframes,
  sponsored cards, or generic `ad` classes. Inline ads therefore remain visible. Login,
  one-time-code, checkout, billing, and payment dialogs are protected. A generic popover
  appearing immediately after a pointer/touch/key interaction is also preserved, so Luna
  does not erase a dialog the user intentionally opened; cookie consent remains suppressed.
- **Scroll recovery:** after suppressing an overlay, the script removes common scroll-lock
  state only from `<html>` / `<body>`. It does not rewrite the article DOM.
- **Tests:** `SafariAnnoyanceSuppressionTests` evaluates the production JS in a bare
  `WKWebView` and verifies OneTrust rejection, generic necessary-only selection,
  newsletter-overlay suppression, preservation of inline advertising and login UI, and
  the immediate-user-action guard.

## "Read in Luna" / "Download in Luna" / "Track in Luna" button

The same extension also presents a page button — but ONLY for the page kinds its
containing app handles, and a tap always deep-links into that app via its own
scheme (`claudedocs/surface-support.md`): the central Luna app's extension shows
all three pill types (via `luna://`); Reader's shows only "Read in Luna",
Downloader's only "Download in Luna", Price Tracker's only "Track in Luna". The
native handler's `buttonContext` reply carries `scheme` +
`supportsArticles`/`supportsMedia`/`supportsProducts`, derived from the
extension's own bundle-id suffix (the bare `<prefix>.safari` id is the central
app). There is no cross-app routing, no installed-marker checks, and no App
Clip/App Store fallback in the pills anymore — the target app is the host and is
installed by definition. This is independent from the iOS 27+ Action Button
shortcut setup; keep it available on earlier iOS versions.

`LunaSafari/Resources/content.js` is injected **programmatically** by `background.js`
(`scripting.executeScript` on every `tabs.onUpdated`/`status:complete` http(s) page),
self-guarded with `window.__queueContentScriptRan`. (A declarative `content_scripts` block
also validates fine — programmatic is just a smaller manifest footprint.) **ITMS-90849
gotcha**: the manifest `description` must stay **≤ ~112 chars** — a 127-char description
failed App Store validation with the opaque code 90849 (NOT content_scripts/scripting, which
were red herrings).

Article flow:
1. content.js asks background `{type:"buttonContext"}`; background relays to the native handler,
   which returns the app's `SafariSuggestionMode` (`never` / `all` / `onlyLocked`, default
   `all`) from the App Group (`SafariSuggestionSettings`, key `safariSuggestionMode`).
2. If `never`, the host app doesn't handle articles, or the page isn't an article, or
   (`onlyLocked`) the page isn't locked, it does nothing. A page is an article when the DOM is **not** an obvious index/listing
   and either its host is a known news/article host (`isKnownArticleHost` — see "Shared
   news-host list" below) OR the DOM scorer accepts it (`looksLikeArticle`). An index
   vetoes both paths: 4+ `<article>` elements, a whole-page link density above 0.5, or
   explicit landing/collection/search/site JSON-LD paired with at least five distinct
   headline-sized destination links. A page is "locked" for `onlyLocked` when its host is a known
   hard-paywall site (`isKnownHardPaywallHost`) OR it shows paywall markers (`looksPaywalled`
   — a JS mirror of `PaywallDetector`: gate markers + `isAccessibleForFree` + `content_tier`).
3. Otherwise it injects a Luna-indigo (`#5856D6`) "Read in Luna" capsule button. Tapping
   it opens `<ownScheme>://read?url=<encoded>` (`LunaDeepLink`) — the extension's own
   containing app.

**Shared news-host list (`isKnownArticleHost` / `isKnownHardPaywallHost`).** The main app
recognizes news/article sites by URL host alone — `afr.com` and ~450 others in
`NewsSites.hardPaywall` / `.free` (`LunaURLClassification`), matched by host suffix
(`KnownSite.matches`) with zero DOM inspection — which is why the app classifies a metered
site's truncated teaser as an article while a DOM-only scorer cannot. The extension shares
that exact data through the generated `LunaSafari/Resources/news_hosts.generated.js`
(`self.__LUNA_NEWS_HOSTS`), which `background.js` injects immediately before `content.js`.
`NewsSitesJSParityTests` regenerates it (`TEST_RUNNER_RECORD_NEWS_HOSTS=1`) from the Swift
arrays and, without that flag, fails the suite if the committed file drifts — so the two
sides can never disagree on which hosts are article/news sites. A known article host rescues
a thin teaser **unless** the DOM is structurally an index/listing (so a publisher's root or
section page does not get a reader pill); a known hard-paywall host also counts as "locked"
for the `onlyLocked` mode. This is the single generalized rule — no site is hardcoded in the
extension; `afr.com` is simply one entry in the shared list.

**Shared platform-host list (`recognizedPlatformPage`).** `PlatformRecognizer`
(`LunaURLClassification`) is the single Swift source of truth for platform recognition
(X, Bluesky, Reddit, TikTok, Instagram, Facebook) — every real classification decision
in the app (ingest, media-download gating, paywall-bypass gating, pasteboard
suggestions) goes through it. The extension shares its host lists through the generated
`LunaSafari/Resources/platform_hosts.generated.js` (`self.__LUNA_PLATFORM_HOSTS`),
injected by `background.js` immediately before `content.js` (same slot as
`news_hosts.generated.js`). `PlatformHostsJSParityTests` regenerates it
(`TEST_RUNNER_RECORD_PLATFORM_HOSTS=1`) from `PlatformRecognizer.rules` and, without
that flag, fails the suite if the committed file drifts. Only the host lists are
generated data; the path-shape requirements content.js needs beyond a host match —
Bluesky's `/profile/<author>/post/<rkey>` shape (`blueskyPostID`), Reddit's post/gallery/
share-link gate (`currentRedditIsPost`, mirroring `PlatformRecognizer.reddit`'s
`recognizes`) — are hand-written JS mirroring the Swift structural checks, guarded by
`PlatformHostsJSFixtureParityTests`' URL-matrix comparison against `PlatformRecognizer`
directly (in a bare `WKWebView`, not just the raw host-list diff). Spotify, Apple Music,
and Apple Podcasts are NOT platforms — `ContentPlatform` has no such cases (see
`content-platforms.md`) — so content.js recognizes none of them; it used to invent all
three independently, which showed a "Download in Luna" pill the app could never act on.

**Article heuristic (`looksLikeArticle`).** The fallback prose scorer for pages that are not
rescued by the shared host list — a lightweight Readability-style scorer, JS-only, since it
only decides button visibility; the app re-classifies properly on save via `LunaIngest`. The
index/listing veto above runs before both the host fallback and this scorer.
- Hard negatives (any one disqualifies the page): 4+ `<article>` elements (a teaser
  feed); whole-page link density (all `<a>` text ÷ `document.body.innerText`) above 0.5;
  a `docs`/`documentation`/`api`/`reference`/`sdk`/`changelog` first-or-second URL path
  segment, OR `<pre>`/`<code>` text outweighing the qualifying candidate text (see
  below); an `input[type=password]` (login/signup gates).
- Candidates: every `<p>`, plus the deduped parent of each `div > br` pattern
  (old-school/book-style pages with no `<p>` at all) — never a `<pre>`. Each is dropped
  if it's nested in an `<li>`, cheaply hidden (inline `display:none`/`visibility:hidden`,
  `hidden`, `aria-hidden="true"`), has its own link density above 0.2, or it (or one of
  its nearest 5 ancestors, stopping at `<body>`) has a class/id matching an UNLIKELY
  pattern (comment/sidebar/nav/promo/social/…) without also matching a POSITIVE one
  (article/content/main/story/…).
- Scoring: surviving candidates with `innerText.length >= 140` contribute
  `sqrt(len - 140)`; their lengths also roll up per `parentElement` to find
  `largestClusterShare` (the biggest single parent's share of all qualifying text).
- Verdict is two-tier: with strong evidence (`og:type=article`, a JSON-LD
  `Article`/`BlogPosting` node, a byline + `time[datetime]` pair, or a single
  `<article>` holding ≥60% of the qualifying text) the bar is `score > 20`; otherwise
  `score > 40 AND largestClusterShare >= 0.5` (rejects link-dense/teaser pages whose
  raw text total is large but scattered across many small siblings).
- SPA retry: if the initial check falls through to "not an article," a single
  `setTimeout` re-runs just the article branch (re-checking `onlyLocked`/
  `looksPaywalled` too) after 2500ms, for bodies that hydrate late.
- Testability: every top-level `browser.*` call is wrapped in
  `if (typeof browser !== "undefined")` so content.js can be evaluated standalone in a
  bare `WKWebView` (no extension host); it exposes `window.__lunaLooksLikeArticle` for
  exactly this. See `LunaTests/SafariArticleHeuristicTests.swift`.

**Per-app URL schemes.** Each app registers ONLY its own scheme — `luna://`
(the central Luna app), `lunareader://`
(Reader), `lunadownloader://` (Downloader), `lunapricetracker://` (Price Tracker) — via
`$(LUNA_URL_SCHEME)` in the shared `Luna/Info.plist`, a per-app-target build setting in
`project.pbxproj` (literal values: the schemes are mirrored as literals in `LunaDeepLink`
and content.js, so they deliberately do NOT derive from `LUNA_NAMESPACE`). A deep link
therefore opens exactly the app it names. `LunaDeepLink.articleURL(from:)` accepts any of
the four schemes (the OS only delivers what the running app registered);
`LunaDeepLink.ownScheme` reads the running bundle's registered scheme for links that must
reopen the current app (e.g. the Live Activity photos-permission action URL).

App side: `SceneDelegate.openReader` ingests the URL (`handleSavePress`) then opens it via
`ReadingListViewController.open(_:presenter:)` — so a paywalled article opens straight into
the in-app archive reader, a ready article into the native reader. The "Locked Only" mode and
the in-app paywall handling share one detector (`PaywallDetector`), so a reader logged in via
their browser sees a full article and isn't flagged.

Downloader-platform flow:
1. content.js asks background `{type:"buttonContext"}`; background relays to the native
   handler, which returns the same suggestion mode plus:
   - `isDownloaderHost` — true only for the `*.downloader.safari` extension bundle.
   - `readerInstalled` / `downloaderInstalled` / `priceTrackerInstalled` — see
     "Installed-app detection" above.
   - `readerAppClipURL` — `LunaReaderAppClipURL` from `LunaSafari/Info.plist`.
   - `downloaderAppClipURL` — `LunaDownloaderAppClipURL` from `LunaSafari/Info.plist`.
2. Before article heuristics run, content.js recognizes Downloader-platform hosts (X,
   Bluesky, Reddit, TikTok, Instagram, Facebook) via `recognizedPlatformPage` — see
   "Shared platform-host list" below. These pages are never classified as articles by
   text length, even when a caption/comment body is long.
3. On a recognized platform URL, the button says "Download in Luna" — shown only when
   the host app handles media (Downloader / central Luna), deep-linking
   `<ownScheme>://read?url=...`.
4. **Static-image posts are not proactively suggested.** The Downloader still accepts
   those URLs if the user adds/saves them manually, but the Safari extension only shows
   the "Download in Luna" pill when a platform page is not a static-image post. Explicit
   video/player metadata, `<video>` nodes, and GIF/GIFV/video URLs are treated as
   downloadable/animated; preview-image-only posts are suppressed.
5. **Reddit is post-page + animated-media gated** (mirrors `PlatformRecognizer.reddit`, which
   now `recognizes:` only a post). The pill appears ONLY on an individual post permalink
   (`/comments/<id>`, `/r|user|u/<name>/comments/<id>`, `/gallery/<id>`, a
   `redd.it/<id>` short link, or Reddit's own app-native share link `/r/<sub>/s/<token>`,
   `currentRedditIsPost`) — never on the home feed, a subreddit listing, or a
   comment-history listing (a subreddit literally named "comments" is still a feed) —
   AND only when the post's primary content is animated image/video. `redditPostHasMedia()`
   qualifies on the server-rendered `<shreddit-post post-type="video|gif|gifv">`
   (disqualifying static `image`/`gallery` plus `text`/`link`/`poll`/`crosspost`),
   `og:video`/player metadata, GIF/GIFV/video URLs, or the old-reddit `#siteTable`
   row for `v.redd.it` / animated URLs. Static `i.redd.it` image posts do not show
   the pill. Because feeds must never get ANY pill, a reddit host that is not a post
   short-circuits `content.js` before the product/article heuristics. New Reddit is a
   client-side-navigating SPA, so
   `content.js` retries on hydration (bounded) and runs a ~1s soft-nav watcher (reddit
   hosts only) that drops/re-adds the pill as the URL changes between feed and post.

Product-page flow:
1. content.js mirrors `ProductPageDetector` (`looksLikeProductPage`). The declarative
   evidence (score threshold, OpenGraph/price names, product and listing URL shapes,
   cart phrases, and rating markers) has one Swift source of truth in
   `ProductPageRules.swift`; `product_rules.generated.js` carries those exact values
   into Safari. `ProductPageRulesJSParityTests` fails if the generated artifact is
   stale, while `ProductPageJSFixtureParityTests` runs representative markup through
   both production classifiers to catch control-flow drift. It fires only
   for a SINGLE primary product (a related/recommended rail is fine), never on a
   search / category grid showing several products at equal primacy:
   - **Listing-URL veto** (`urlIsMultiProductListing`, mirrors
     `ProductPageDetector.urlIsMultiProductListing`): a search/browse/category/deals
     URL (Amazon `/s?k=…`, `/b`, `/gp/bestsellers`; eBay `/sch`; generic `/search`,
     `/category`, `/collections`, or a `?k=`/`?q=`/`?query=` search param) is a
     multi-product listing and is rejected up front, whatever per-card furniture it
     carries. This is the fix for the "Track in Luna" pill wrongly appearing on
     Amazon search results.
   - Tier 1 — a JSON-LD `Product` offer price / OpenGraph `product:price` meta /
     microdata `itemprop=price` is decisive alone.
   - Tier 2 — ≥2 combinable retail signals (og:type=product, add-to-cart affordance,
     rating signal, retail URL shape) catch a legitimate single product page that has
     no Tier-1 markup. The listing-URL veto already excludes multi-product grids, so
     Tier 2 stays a standalone classifier. The Swift detector's embedded-app-state-JSON
     price signal is deliberately not mirrored (visibility heuristic only; the app
     re-classifies on save).
   Checked after the platform check and BEFORE the article heuristics, so a wordy
   retail page never shows "Read in Luna".
2. On a product page the button says "Track in Luna" — shown only when the host app
   handles products (Price Tracker / central Luna), deep-linking
   `<ownScheme>://read?url=<source>`.

Paywall unlock + toast:
- The native handler answers `bypassEnabled` true only for article-handling hosts
  (Reader and the central Luna app) — unlocking is article handling, so the
  Downloader / Price Tracker extensions never enable the declarative Referer
  ruleset (background.js) or the in-page overlay cleanup (content.js
  `revealArticle`). No user preference.
- When a reveal actually unlocks something (page had paywall markers, or the cleanup
  removed/revealed a paywall node — the generic UNHIDE class sweep doesn't count),
  content.js shows a brief "Unlocked with Luna" toast: an indigo capsule centered
  above the button's corner (bottom ≈84px + safe area, so the two never overlap),
  fading out after ~3s. The "Read in Luna" button still appears independently.

The setting lives in Settings → Shortcut & Safari ("Read in Luna Button" on Reader,
"Download Button" on Downloader, and "Track in Luna Button" on Price Tracker — a
3-segment control). On pre-iOS 27 builds this screen shows only the Safari-button setting; the
Action Button shortcut setup section is hidden. `background.js` relays
`buttonContext`/`buttonMode`; content scripts can't call `sendNativeMessage` directly.

## Onboarding takeover: "You're all set!"

While Luna's Safari-onboarding step is on screen (waiting for the user to enable
the extension in Settings), the app sets a one-shot per-surface takeover-pending
flag via `LunaStorage.SafariExtensionStatusStore.setTakeoverPending(true,
forSurface:)`. Once the extension actually runs (any native message reaches
`SafariWebExtensionHandler`, though `background.js` asks explicitly at script
load), the handoff completes:

```
background.js (script load) → sendNativeMessage {type: "onboardingStatus"}
  → SafariWebExtensionHandler records extension run for every native message
    - writes safariExtensionHasRun.<surface> = true (App Group)
    - writes safariExtensionEnabled.<surface> = now (legacy timestamp, App Group)
  → SafariWebExtensionHandler "onboardingStatus" case
  → SharedOnboardingStatus.recordEnabledAndConsumeTakeover()
    - reads + clears onboarding.safariTakeoverPending.<surface> (App Group)
  → responds {takeover: true/false, scheme: "<luna|lunareader|lunadownloader|lunapricetracker>"}
  → background.js: if takeover, inject a full-page overlay on the active tab
```

- `LunaSafari/SharedOnboardingStatus.swift` derives THIS extension's surface +
  scheme from its own bundle id suffix (`<host>.reader|.downloader|.pricetracker.safari`;
  the bare `<prefix>.safari` is the central Luna app → surface "luna", scheme `luna://`
  — mirrors `SafariWebExtensionHandler`'s existing `isHost(appSuffix:)` pattern) and
  owns the key literals (`safariExtensionHasRun.<surface>`,
  `safariExtensionEnabled.<surface>`,
  `onboarding.safariTakeoverPending.<surface>`), duplicated from the app-side
  `LunaStorage.SafariExtensionStatusStore` (no shared framework in this target).
- The overlay (`background.js`'s `lunaTakeoverOverlayScript`, injected via
  `browser.scripting.executeScript({ func, args })` on the active tab — same
  programmatic-injection approach as `content.js`) is a fixed, full-viewport,
  max-z-index Luna-indigo (`#5856D6`) panel: "You're all set!" headline, "The Luna
  extension is enabled." subline, and a real `<a href="<scheme>://">Back to
  Luna</a>` tap target — it never auto-navigates (that could fight the user's own
  navigation or get blocked as a redirect). If no eligible active tab exists yet
  (e.g. `about:` page), the scheme is stashed in `pendingTakeoverScheme` and
  retried exactly once on the next `tabs.onUpdated` "complete" event.
- The bare `<scheme>://` link (no host/path) is intentionally minimal — the app's
  `scene(_:openURLContexts:)` → `LunaDeepLink.articleURL(from:)` requires
  `host == "read"`, so a bare scheme is a no-op route (verified in
  `LunaDeepLinkTests.testArticleURLRejectsBareSchemeWithNoHost`), never crashing or
  ingesting junk.

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Luna → enable + allow all websites. Verify via Luna app Settings screen ("Safari extension status" shows last tracked URL).
