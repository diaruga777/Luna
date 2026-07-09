# LunaSafari — Safari Web Extension

Tracks the URL of the active Safari tab and persists it so the SaveLink intent can save "the page I'm looking at" without any UI.

## Flow

```
background.js (tabs.onActivated / tabs.onUpdated)
  → browser.runtime.sendNativeMessage("application.id", {url})
  → SafariWebExtensionHandler (extension process, NSExtensionRequestHandling)
  → App Group UserDefaults (group.com.hsanabria.luna): lastSafariURL, lastSafariURLDate
  → read by SafariURLStore (app) / SaveLinkIntent
```

## Key files

- `LunaSafari/Resources/manifest.json` — MV3; `background.page` (event page — iOS kills MV3 service workers) **with `"persistent": false`** and a numeric-keyed `icons` map — both are REQUIRED by App Store Connect upload validation (ITMS error 90849 otherwise); permissions `nativeMessaging`, `tabs`; `host_permissions: <all_urls>` (needed to read tab URLs; user grants "All Websites").
- `LunaSafari/Resources/background.js` — listens `tabs.onActivated` + `tabs.onUpdated` (active tab, url change or load complete), dedupes, sends native message.
- `LunaSafari/SafariWebExtensionHandler.swift` — principal class (`NSExtensionPointIdentifier = com.apple.Safari.web-extension` in `LunaSafari/Info.plist`); writes via `SharedSafariURL`.
- `LunaSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — no shared framework in this small project).

Target: `LunaSafari`, bundle `com.hsanabria.luna.safari`, app-extension product embedded in Luna.app/PlugIns. Resources flatten into the appex root (Safari requires manifest.json at bundle root on iOS).

## "Read in Luna" / "Download in Luna" / "Track in Luna" button

The same extension also presents a page button: "Read in Luna" on article pages,
"Download in Luna" on recognized Downloader-platform pages, or "Track in Luna" on
recognized product pages. This is independent from
the iOS 27+ Action Button shortcut setup; keep it available on earlier iOS versions
as long as the Safari web extension and deep-link/App Clip path work there.

**Installed-app detection.** Each app writes a `lunaInstalled.<surface>` marker into
the App Group at launch (`Luna/Settings/InstalledAppMarkers.swift`, called from
AppDelegate). The native handler reports `readerInstalled` / `priceTrackerInstalled`
in the `buttonContext` reply: true when the marker is set OR when the extension's own
host IS that app (bundle-id suffix — the host is installed by definition). Markers can
go stale after an uninstall (App Group data outlives any one app); treated as
best-effort.

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
2. If `never`, or the page isn't an article, or (`onlyLocked`) the page isn't locked, it
   does nothing. A page is an article when its host is a known news/article host
   (`isKnownArticleHost` — see "Shared news-host list" below) OR the DOM scorer accepts it
   (`looksLikeArticle`). A page is "locked" for `onlyLocked` when its host is a known
   hard-paywall site (`isKnownHardPaywallHost`) OR it shows paywall markers (`looksPaywalled`
   — a JS mirror of `PaywallDetector`: gate markers + `isAccessibleForFree` + `content_tier`).
3. Otherwise it injects a Luna-indigo (`#5856D6`) "Read in Luna" capsule button. Tapping it
   prefers `LunaReaderAppClipURL?url=<source>` from `LunaSafari/Info.plist`; that URL is
   filled in after App Store Connect has the Reader App Clip experience and should open the
   full Reader app when installed or the Reader App Clip otherwise. Until that value exists,
   it falls back to `lunareader://read?url=<encoded>` (`LunaDeepLink`) when Reader is
   installed — ONLY Reader registers `lunareader://` now, so with Reader absent and no
   App Clip URL the button isn't shown on article pages.

**Shared news-host list (`isKnownArticleHost` / `isKnownHardPaywallHost`).** The main app
recognizes news/article sites by URL host alone — `afr.com` and ~450 others in
`NewsSites.hardPaywall` / `.free` (`LunaURLClassification`), matched by host suffix
(`KnownSite.matches`) with zero DOM inspection — which is why the app classifies a metered
site's truncated teaser as an article while a DOM-only scorer cannot. The extension shares
that exact data through the generated `LunaSafari/Resources/news_hosts.generated.js`
(`self.__LUNA_NEWS_HOSTS`), which `background.js` injects immediately before `content.js`.
`NewsSitesJSParityTests` regenerates it (`TEST_RUNNER_RECORD_NEWS_HOSTS=1`) from the Swift
arrays and, without that flag, fails the suite if the committed file drifts — so the two
sides can never disagree on which hosts are article/news sites. A known article host is an
article regardless of the DOM scorer; a known hard-paywall host also counts as "locked" for
the `onlyLocked` mode. This is the single generalized rule — no site is hardcoded in the
extension; `afr.com` is simply one entry in the shared list.

**Article heuristic (`looksLikeArticle`).** The FALLBACK scorer for hosts NOT on the shared
list above — a lightweight Readability-style scorer, JS-only, since it only decides button
visibility; the app re-classifies properly on save via `LunaIngest`.
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

**Per-app URL schemes.** Each app registers ONLY its own scheme — `lunareader://`
(Reader), `lunadownloader://` (Downloader), `lunapricetracker://` (Price Tracker) — via
`$(LUNA_URL_SCHEME)` in the shared `Luna/Info.plist`, a per-app-target build setting in
`project.pbxproj` (literal values: the schemes are mirrored as literals in `LunaDeepLink`
and content.js, so they deliberately do NOT derive from `LUNA_NAMESPACE`). A deep link
therefore opens exactly the app it names. `LunaDeepLink.articleURL(from:)` accepts any of
the three schemes (the OS only delivers what the running app registered);
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
2. Before article heuristics run, content.js recognizes Downloader-platform hosts mirrored
   Facebook, Spotify, Apple Music, Apple Podcasts). These pages are never classified as
   articles by text length, even when a caption/comment body is long.
3. On a recognized platform URL, the button says "Download in Luna". With the Downloader
   app installed (its own extension host, or the launch marker), it deep-links
   `lunadownloader://read?url=...`. Otherwise it routes to
   `LunaDownloaderAppClipURL?url=<source>`. If `LunaDownloaderAppClipURL` is empty
   (the default until the production App Clip invocation URL exists), no button is shown
   on platform pages when Downloader isn't installed.
4. **Reddit is post-page + media gated** (mirrors `PlatformRecognizer.reddit`, which
   now `recognizes:` only a post). The pill appears ONLY on an individual post permalink
   (`/comments/<id>`, `/r|user|u/<name>/comments/<id>`, `/gallery/<id>`, or a
   `redd.it/<id>` short link) — never on the home feed, a subreddit listing, or a
   comment-history listing (a subreddit literally named "comments" is still a feed) —
   AND only when the post's primary content is image/video. `redditPostHasMedia()`
   qualifies on the server-rendered `<shreddit-post post-type="image|video|gallery|gif">`
   (disqualifying `text`/`link`/`poll`/`crosspost`), an `og:video` meta, a `/gallery/`
   path, or the old-reddit `#siteTable .thing.link` with an `i.redd.it`/`v.redd.it`/
   `i.imgur.com` `data-domain` (or an `.expando` holding a video/img). Because feeds must
   never get ANY pill, a reddit host that is not a post short-circuits `content.js` before
   the product/article heuristics. New Reddit is a client-side-navigating SPA, so
   `content.js` retries on hydration (bounded) and runs a ~1s soft-nav watcher (reddit
   hosts only) that drops/re-adds the pill as the URL changes between feed and post.

Product-page flow:
1. content.js mirrors `ProductPageDetector` (`looksLikeProductPage`): Tier 1 — a
   JSON-LD `Product` offer price / OpenGraph `product:price` meta / microdata
   `itemprop=price` is decisive alone; Tier 2 — ≥2 retail signals (og:type=product,
   add-to-cart affordance, rating signal, retail URL shape). The Swift detector's
   embedded-app-state-JSON price signal is deliberately not mirrored (visibility
   heuristic only; the app re-classifies on save). Checked after the platform check
   and BEFORE the article heuristics, so a wordy retail page never shows "Read in Luna".
2. On a product page the button says "Track in Luna". With Price Tracker installed
   it opens `lunapricetracker://read?url=<source>` — Price Tracker's own scheme, so
   the tap always lands in Price Tracker. Without it, the button opens
   `LunaPriceTrackerAppStoreURL` from `LunaSafari/Info.plist` (Price Tracker's App
   Store page — fill in once the app is live); while that key is empty, no button is
   shown on product pages when Price Tracker isn't installed.

Paywall unlock ("Unlock Paywalls On-Device") gating + toast:
- The native handler answers `bypassEnabled` true only when the toggle is on AND
  Luna Reader is installed (marker or reader-host extension) — unlocking is a Reader
  feature. This gates both the declarative Referer ruleset (background.js) and the
  in-page overlay cleanup (content.js `revealArticle`).
- When a reveal actually unlocks something (page had paywall markers, or the cleanup
  removed/revealed a paywall node — the generic UNHIDE class sweep doesn't count),
  content.js shows a brief "Unlocked with Luna" toast: an indigo capsule centered
  above the button's corner (bottom ≈84px + safe area, so the two never overlap),
  fading out after ~3s. The "Read in Luna" button still appears independently.

The setting lives in Settings → Shortcut & Safari ("Read in Luna Button" — a 3-segment
control). On pre-iOS 27 builds this screen shows only the Safari-button setting; the
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
  → responds {takeover: true/false, scheme: "<lunareader|lunadownloader|lunapricetracker>"}
  → background.js: if takeover, inject a full-page overlay on the active tab
```

- `LunaSafari/SharedOnboardingStatus.swift` derives THIS extension's surface +
  scheme from its own bundle id suffix (`<host>.reader|.downloader|.pricetracker.safari`
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
