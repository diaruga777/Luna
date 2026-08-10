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
- `LunaSafari/SharedSafariURL.swift` — App Group defaults writer (key constants duplicated in app-side `SafariURLStore` — see "Where the work runs" for when a hand-copy is acceptable and when it isn't).

Target: `LunaSafari`, bundle `com.hsanabria.luna.safari`, app-extension product embedded in Luna.app/PlugIns. Resources flatten into the appex root — that suits Safari (manifest.json must be at the bundle root on iOS) but it is Xcode's synchronized-group resource copy doing it, indiscriminately, to nested folders too. **`_locales/en/messages.json` must NOT be left flattened**: `browser.i18n.getMessage` reads only `_locales/<locale>/messages.json`, and a root-level copy makes every key resolve to `""` — which is what once rendered the in-page pill as a text-less indigo stub (its width is its label plus padding) and dropped the extension's own name. `scripts/update_safari_extension_branding.sh` (an `alwaysOutOfDate` build phase on all four Safari targets) re-copies the `_locales` tree from `$SRCROOT`, deletes the flattened stray, and only then rewrites `extensionName` per host app. `content.js` additionally carries an inline English default for every string it renders, so an empty lookup degrades to correct copy instead of an empty pill; `SafariPillLabelTests` covers both halves — the fallbacks (and their parity with `messages.json`) and the built appex's directory layout.

## Where the work runs

**Extraction runs in shared Swift, in every process. It is never re-implemented
for Safari.**

The four Safari appex targets used to link no package at all, and the
`LunaSafari/Shared*.swift` files hand-copy the app's App-Group key formats
because of it. That pattern is fine for what it covers — a handful of string
constants and a 24h window, each pinned by a parity test — and it is **not** the
model for anything with logic in it. The extension now links the package, so:

| linked product | what it buys the appex |
| --- | --- |
| `LunaAppConfig` | the App Group id (`SafariAppGroup` reads the Info.plist key) |
| `LunaModels` | `ProductIdentifiers` / `ProductIdentityMatching`, the shared identity primitives |
| `LunaStorage` | the App Group containers the app also writes |
| `LunaURLClassification` | URL shape rules + `WebFetchConstants` (the Safari UA and byte cap) |
| `LunaMediaResolve` | "post URL → direct CDN asset", the in-page player's one round trip |
| `LunaPriceCompare` | the alternative-seller fan-out, its bundled seller directory and lean page parser — and, through it, `LunaPriceMetadata` |

All Foundation-only, no UIKit, on all four host copies (the per-kind gates are
runtime, so the Downloader's extension links the price engine too and simply
never reaches it).

- **`LunaMediaResolve`** is the ONE implementation of "post URL → direct CDN
  asset" (`SocialMediaResolver`, `YouTubeMediaResolver`, the per-platform
  parsers, `MediaAsset.direct`, `MediaAsset.isDirectlyPlayable`). The app, the
  share extension, the action extension and the Safari native handler all call
  it. It was split out of `LunaMediaDownload` for exactly this: resolution is
  Foundation + `URLSession`, while the download machinery around it pulls UIKit,
  Photos, ActivityKit and SwiftSoup, none of which belong in an appex with an
  ~80MB ceiling. `LunaMediaDownload` `@_exported import`s it, so no call site
  outside the extension changed.
- **`SafariWebExtensionHandler` is an adapter and nothing more**: parse the
  message, call the shared code, serialize the answer.
  `SafariVideoOverlayContractTests` fails the build if that file ever mentions
  `URLSession`, `JSONSerialization`, a string-splitting parse, or a platform
  endpoint — and if any other `LunaSafari/*.swift` file starts naming
  `MediaAsset` or a platform's JSON keys.

**What genuinely has to be JavaScript**, and why:

| In the page | Why it can't be Swift | What pins it |
| --- | --- | --- |
| Page/platform recognition (`recognizedPlatformPage`, `currentRedditIsPost`, `currentYouTubeIsVideo`) | Needs the live URL + DOM at the moment the user is looking at it; the host lists come from Swift | `platform_hosts.generated.js`, generated from `PlatformRecognizer.rules`; `PlatformHostsJSParityTests` |
| Has-video / static-image signals (`hasVideoOrAnimatedImageSignal`, `redditPostHasMedia`) | Reads the rendered DOM (`<video>`, `og:` tags, `shreddit-post`) | `SafariRedditGatingTests`, `SafariArticleHeuristicTests` |
| Article / product classification | Same — rendered DOM | `news_hosts.generated.js`, `product_rules.generated.js`; `ProductPageRulesJSParityTests`, `ProductPageJSFixtureParityTests` |
| The pill and the video overlay | In-page UI has to be in-page | `SafariPillLabelTests`, `SafariVideoOverlayTests` (the overlay, driven directly), `SafariMediaPillTests` (how a page GETS one: which target it earns, the auto-open, the pill as the way back) |

**The rule for the next platform.** New extraction logic goes into
`LunaMediaResolve` once and every surface gets it for free — there is no Safari
leg to add. If a platform ever genuinely needs page-context work (say a
session-bound token that only exists on the live page), the JavaScript should
capture the **minimal raw input** and hand it to shared Swift, which does all the
parsing and processing; and that JS piece must then be either generated from its
Swift source or pinned by a parity test that fails on drift — never a silent
hand-mirror.

## The in-page setup confirmation

The first time an app's extension ever runs after that app sent the user off to
enable it, the content script takes the whole window instead of offering a pill:
"Nice! / You're all set up" over a tinted semi-transparent scrim, with a "Return
to `<app name>`" button. It dismisses itself after 20s and hands the page back, so
a pill can still appear if that page earns one. A page refresh dismisses it
immediately. Once the overlay is attached, its native handler sends the App Group
Darwin notification `safariCelebrationPresented`; a running onboarding app uses
that signal to stop its Safari setup-guide PiP video without waiting for Safari to
return to the foreground.

The premise it disproves is worth stating, because it shapes everything here: a
Safari extension's **JavaScript** cannot read the container app's state, but its
**native handler** runs in an appex holding the App Group entitlement, and
`sendNativeMessage` bridges the two. So this is not a new capability — it is the
same channel `buttonContext` and `recordExtensionRun` already used.

Four App-Group keys, all **per app** rather than shared (unlike the
`setup.safari.hasRun.*` completion markers, which the three faceted apps
deliberately share): an extension may only ever hand off to its OWN containing
app, so central Luna's tap must not make the Reader's extension offer to return
the user to an app they never left.

| key | written by | when |
| --- | --- | --- |
| `setup.safari.setupTapAt.<app>` | app | `AppOnboardingViewController.openSafariSetup`, before the hop |
| `setup.safari.setupTapAppName.<app>` | app | same moment, with `LunaApp.displayName` |
| `setup.safari.firstRunAt.<app>` | extension | `recordExtensionRun`, **only if absent** |
| `setup.safari.celebrationShown.<app>` | extension | as soon as the overlay is COMMITTED to, before its DOM is built |

The rule — all three of: tap within 24h, first run within 24h, never shown — is
stated by `LunaSetupStatusStore.shouldCelebrateSafariSetup` and mirrored by
`SharedSafariURL.shouldCelebrateSetup`, because `LunaSafari` links no package.
`SafariSetupCelebrationTests` owns the rule, the overlay, AND the parity between
the two copies (key formats, the window, and that `SharedSurfaceScheme`'s surface
strings really are `LunaApp.storageIdentifier`s — the keys only meet if they are).
`resetAllRunEvidence` clears all four, including the extension's two: an extension
first-runs exactly once, so a reset that left `firstRunAt` behind could never show
the confirmation again.

The flag is written **before** the overlay's nodes are built, not after they land.
That ordering is load-bearing rather than incidental: a one-shot whose flag is
written last is not a one-shot at all if the rendering in between can fail, and
here failure was not hypothetical. `"Return to $APP$"` in `messages.json` used
web-extension i18n **placeholder syntax** (`$NAME$`, and likewise `$1`…`$9`) with
no `placeholders` dictionary to resolve it; WebKit's `localizedStringForKey` then
dereferenced a null JSON object and **segfaulted the Web Content process**. Safari
showed "A problem repeatedly occurred" on every site, forever, because the crash
landed two statements before the flag was sent — so the next page decided to
celebrate again. The token is now `{app}`, substituted by `content.js` itself, and
`SafariPillLabelTests.testNoLocalizedMessageCarriesPlaceholderSyntax` fails the
build on any `$` in the catalog that lacks a `placeholders` entry. Nothing in JS
can catch a process-level crash, so the only defences are keeping `$` out of the
catalog and bounding a bad render to one page.

Three things constrain the design, none of them fixable in code:

- **Website permission, not the extension toggle, gates it.** Enabling the
  extension in Settings doesn't run content scripts; host access starts at Ask. The
  confirmation therefore appears when access is granted, which may be several taps
  after the switch. This is the same gate `recordExtensionRun` evidence has always
  been behind (the background script needs `tab.url`), so it adds no new failure
  mode — but the PiP guide has to keep walking the user to the Allow step.
- **The return hop must be a tap.** An appex cannot open a URL
  (`NSExtensionContext.open` is not available to a Safari web extension handler on
  iOS), and Safari only honours app-scheme navigation under user activation — an
  automatic `window.location = "lunareader://"` is dropped silently. Hence a
  button. Expect Safari's "Open in Luna?" confirmation; only a hosted universal
  link would avoid it, and there is no Luna-owned page in real Safari (the
  onboarding lesson's `.lunaPage` is a native mock, and the lesson sends the user
  to `en.wikipedia.org`).
- **It is independent of pill eligibility**, deliberately: the lesson proves the
  extension runs on an ordinary page, and that page is frequently one the app would
  never offer a pill on (Wikipedia in Downloader). It also ignores `mode: "never"`,
  which silences pills rather than the proof that setup worked.

The button opens a **bare** scheme (`lunareader://`, no `?url=`) — `SceneDelegate`'s
`route` matches nothing and simply leaves the app on whatever it was showing.

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
  popover fallback requires overlay structure (`dialog`/`aria-modal`, an overlay
  name plus fixed positioning, or substantial fixed viewport coverage) AND either
  annoyance language (newsletter/subscribe/register/email-capture copy, push
  notifications, app-install prompts, surveys, ad-block nags, ad interstitials) OR the
  general email-capture signal — an `input[type=email]` (or `autocomplete=email`/
  `name*=email`) with no password or one-time-code field. The email-field signal
  catches newsletter/email modals whose copy matches none of the text patterns (or is
  in an unmatched language); it stays safe because the protected-dialog guard has
  already excluded anything with a password/OTP or login/checkout/billing wording.
- **Never the page itself:** every identity signal above is a SUBSTRING match, and
  publishers put transient modal/overlay STATE classes on the document — NYT's consent
  vendor (Ethyca Fides) adds `fides-overlay-modal-link-shown` to `<body>`, Bootstrap adds
  `modal-open` — so `<body>` starts matching the `[class*="overlay" i]` /
  `[class*="modal" i]` overlay probes. A publisher page also always carries cookie wording
  and a reject button *somewhere* inside it, so the whole document then reads as a valid
  consent root. That is what blanked NYT in Safari (correct page painted, then
  `display:none` landed on `<body>`). `holdsPageContent` therefore rejects
  `<body>`/`<html>` and anything containing `main`/`article`/`[role=main]`, enforced at the
  single `hide()` sink AND in `semanticConsentRoot`'s candidate loop — the latter matters
  because a consent root short-circuits the popover scan of everything below it, so
  claiming the document would also hide the real banner from consideration. Regression:
  `testDocumentBodyIsNeverTreatedAsTheConsentRoot`.
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

### Colour: a pill is its KIND's, chrome is its APP's

Every in-page surface carries one of Luna's four identity colours
(`LunaSurfacePalette.baseColor` — Luna indigo `#5856D6`, Reader periwinkle
`#ADB5F6`, Downloader amber `#CC7609`, Price Tracker green `#07FF9D`), and which
one it takes follows a single rule: **a pill is coloured by the CONTENT KIND it
would save; app chrome is coloured by the APP showing it.**

The two readings agree everywhere it matters, and only one of them is
expressible. A single-content app shows exactly one kind of pill, so the
Downloader's is always amber and the Price Tracker's always green — while the
central Luna app, the only host that shows all three, colours each pill by the
save it would make, which is the answer to "which of my apps is this button for".
So `KIND_TINTS` (article → the Reader's, media → the Downloader's, product → the
Price Tracker's) hangs off the target factories: `readTarget`/`downloadTargetFor`/
`trackTargetFor` each name their tint, `injectLunaButton` renders whatever the
target gave it (and stamps it on `data-luna-tint`), and a target that forgets one
falls back to the Luna indigo. The video player's Download button takes the tint
of the pill that opened it; the "Unlocked with Luna" toast takes the article tint
(only article-capable hosts unlock at all).

The **setup confirmation** is the exception that proves the rule: it belongs to
the app rather than to any page — it is deliberately shown on pages that would
earn no pill — so it is coloured by `surface`, which is why that field rides the
`buttonContext` reply (handler → `background.js` relay → page) alongside `scheme`.
Its wash is the app colour mixed most of the way down toward the night sky, since
three of the four are far too bright to sit undimmed over someone's article.

**Text colour is a function of the fill, never a constant.** The four identity
colours span nearly the whole brightness range, so white would be unreadable on
the Price Tracker's near-neon green and the Reader's pale periwinkle. Both
languages pick the winner at the same threshold — WCAG relative luminance 0.19,
where white and `#12121a` tie on contrast — `tintForeground` in `content.js` and
`LunaSurfacePalette.ink(on:)` in Swift. That is what lets the fill go on being
*exactly* the app's colour rather than a tempered version of it. The two
informational chips (the "Was $X" history pill and the alternative-seller pill)
are the one place the tint is a cast rather than a fill: they report a price
instead of offering an action, so they stay the dark chip they have always been
with the tint mixed 22% into it — filling them would make them read as a second
button.

`content.js` hand-copies the four hex values (this target links no package — the
same trade the `Shared*.swift` files make), and `SafariSurfaceTintTests` holds the
copy, the kind mapping, the text-colour rule and the resulting contrast against
`LunaSurfacePalette`. The Downloader's onboarding Safari lesson replicates the
player panel in UIKit and reads the same palette
(`SafariVideoOverlayReplicaTests`).

`LunaSafari/Resources/content.js` is loaded **both** ways: it is a **declared
`content_scripts` entry** (`run_at: document_idle`, top frame, `js:
[news_hosts.generated.js, platform_hosts.generated.js, product_rules.generated.js,
content.js]` so the shared data globals load first in the same isolated world) AND it is
still injected **programmatically** by `background.js` (`scripting.executeScript` on every
`tabs.onUpdated`/`status:complete` http(s) page). The declared entry is the reliable path
— on iOS a non-persistent background event page can miss/defer `scripting.executeScript`,
which would drop BOTH the pill AND the in-page `revealArticle` unlock while leaving
background native-messaging (URL tracking / manual share) working; the declared script
runs like `annoyances.js` regardless. The programmatic call is a harmless fallback:
`content.js` self-guards with `window.__queueContentScriptRan`, so whichever injection
wins the race runs setup once and the other no-ops. **ITMS-90849
gotcha**: the manifest `description` must stay **≤ ~112 chars** — a 127-char description
failed App Store validation with the opaque code 90849 (NOT content_scripts/scripting, which
were red herrings).

Article flow:
1. content.js asks background `{type:"buttonContext"}`; background relays to the native handler,
   which returns the app's `SafariSuggestionMode` (`never` / `all` / `onlyLocked`, default
   `all`) from the App Group (`SafariSuggestionSettings`, key `safariSuggestionMode`).
2. If `never`, the host app doesn't handle articles, or the page isn't an article, or
   (`onlyLocked`) the page isn't locked, it does nothing. There are two article paths.
   On a **known** news/article host (`isKnownArticleHost` — see "Shared news-host list"
   below), positive article metadata (`pageDeclaresArticle`: `og:type=article`, or an
   `Article`/`NewsArticle`/`BlogPosting` JSON-LD node) makes it an article outright,
   mirroring the app's `NewsSites` fast-path; only a host page carrying **no** article
   declaration falls back to the structural index veto (so a publisher homepage still
   gets no pill). On an **unknown** host the index veto runs first and the DOM scorer
   (`looksLikeArticle`) decides. The index veto is: 4+ `<article>` elements, a whole-page
   link density above 0.5, or explicit landing/collection/search/site JSON-LD paired
   with at least five distinct headline-sized destination links.

   **The app has this veto too now.** `ListingPage` (LunaHTMLClassification) is the
   Swift twin of `looksLikeNonArticleIndex`, added because the pipeline had no index
   test at all: a page that got no pill here could still be offered by the recents
   tray and sent to the archive reader (`claudedocs/url-pipeline.md`).
   `SafariIndexVetoParityTests` runs one fixture set through both — the production
   `content.js` in a bare `WKWebView` (via `window.__lunaLooksLikeNonArticleIndex`)
   and `ListingPage` directly — and fails if they disagree, the same drift guard
   `ProductPageJSFixtureParityTests` gives the product detector. Only the HTML half
   is comparable: the Swift side adds a URL-only search-results shape, since it
   classifies URLs the extension only ever sees as a loaded document.

   **A page that declares an article is exempt from every purely STRUCTURAL veto, on
   every host.** The two shapes live in one shared `hasStructuralListingShape()` (4+
   `<article>`, link density > 0.5) which returns false outright for a declaring page,
   because neither shape says anything about a page's kind: real articles routinely embed
   a related-story `<article>` rail (Business Insider ships six; a Paris Review interview
   ships thirteen "more from this issue" cards) and go link-dense once metered. The
   exemption used to be gated on the known-news list, which left every declared article
   OFF that list vetoed by markup carrying no such meaning — a rail of cards is not a
   property of the host. `looksLikeArticle` carried its OWN copy of those two lines
   (which is why fixing the veto alone changed nothing on theparisreview.org) and now
   calls the shared helper, so they can't drift apart again. The same exemption covers
   the scorer's `input[type=password]` disqualifier: a document-wide password test is not
   "this page is a login form" — publishers ship an inline sign-in form in the site
   header (Paris Review carries two, one per breakpoint) and a metered page puts one
   under the teaser. A page's own LISTING declaration still vetoes even when it also
   claims to be an article, and on an unknown host the prose scorer still has to find
   real prose afterwards, so a thin metered teaser off the host list stays pill-less
   (`SafariArticleHeuristicTests.testUnknownHostWithThinTeaserIsNotArticle`,
   `testUnknownHostArticleWithCardRailAndHeaderSignInIsArticle`,
   `testUndeclaredPageWithCardRailAndSignInIsNotArticle`, `testSignInPageIsNotArticle`).

   A page is "locked" for `onlyLocked` when its host is a known
   hard-paywall site (`isKnownHardPaywallHost`) OR it shows paywall markers (`looksPaywalled`
   — a JS mirror of `PaywallDetector`: gate markers + `isAccessibleForFree` + `content_tier`).
3. Otherwise it injects a "Read in Luna" capsule button in the article tint (the
   Reader's periwinkle `#ADB5F6` — see "Colour" above). Tapping
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
sides can never disagree on which hosts are article/news sites. A known article host that
declares an article (`pageDeclaresArticle`) is an article outright — no prose score needed,
matching the app's fast path; a known host with no article declaration falls back to the
structural index veto, so a publisher's root or section page still does not get a reader
pill. What the list does NOT decide is whether publisher furniture can veto a declared
article: that exemption is host-independent (see the article flow above), so the list is
purely additive — it rescues thin teasers, it is not a prerequisite for being read as an
article. A known hard-paywall host also counts as "locked" for the `onlyLocked` mode. This
is the single generalized rule — no site is hardcoded in the extension; `afr.com` and
`businessinsider.com` are simply entries in the shared list.

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
- Hard negatives (any one disqualifies the page): `hasStructuralListingShape()` — 4+
  `<article>` elements (a teaser feed) or whole-page link density (all `<a>` text ÷
  `document.body.innerText`) above 0.5; a
  `docs`/`documentation`/`api`/`reference`/`sdk`/`changelog` first-or-second URL path
  segment, OR `<pre>`/`<code>` text outweighing the qualifying candidate text (see
  below); an `input[type=password]` (login/signup gates). **The structural pair and the
  password gate are skipped for a page that declares an article** — see the exemption
  under the article flow above; without it, publisher furniture (a card rail, a header
  sign-in form) disqualified real articles outright.
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
the deck's tap routing (`ArticleCardsViewController`) — so a paywalled article opens straight into
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
   the host app handles media (Downloader / central Luna). The **in-page video player**
   (below) opens BY ITSELF on such a page when the page's subject is a video; the pill
   is then how the user gets back to it after a dismissal, and the route on a page that
   never earns an auto-open. The deep link `<ownScheme>://read?url=...&ret=safari`
   is still what that overlay falls back to when nothing turns out to be playable, and
   is still what Reddit's pill does directly.
4. **Static-image posts are not proactively suggested.** The Downloader still accepts
   those URLs if the user adds/saves them manually, but the Safari extension only shows
   the "Download in Luna" pill when a platform page is not a static-image post. Explicit
   video/player metadata, `<video>` nodes, and GIF/GIFV/video URLs are treated as
   downloadable/animated; preview-image-only posts are suppressed.
   **A video-only URL SHAPE outranks that heuristic** (`pathIsInherentlyVideo`,
   the `INHERENTLY_VIDEO_PATH_SEGMENTS` table): Instagram serves a reel with
   markup identical to a photo post — `og:type` is literally `article`, the only
   media meta is the JPG thumbnail, and no `og:video`/`twitter:player` appears
   anywhere in the document, its `<video>` being hydrated by script long after
   content.js runs — so the static-image signal matched and every reel lost its
   pill while the same link downloaded fine when shared in. `/reel/`, `/reels/`
   and `/tv/` (with a shortcode after them; a leading username segment is
   allowed, as Instagram's own `og:url` uses it) are video-only surfaces and skip
   the heuristics. Instagram `/p/` deliberately does NOT: it carries photos as
   well as videos, and there the static-image verdict is the right one. Since
   Instagram publishes no server-side video signal at all, a VIDEO under `/p/`
   remains suppressed — the only way to tell would be to re-check the DOM after
   hydration, which only Reddit does today.
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

### The in-page video player

On a media-handling host (central Luna / Downloader), a recognized media page
does not send the user to the app to watch what they are already looking at: an
overlay plays the post's video right there, with one Download button under it.

**It opens on its own, and the pill is the way back to it.** The player is not a
reward for finding a button — on a page whose subject IS a video it is up before
the user does anything, in its loading state, and the resolve is already running.
The pill stays where it was: tapping it re-opens a player the user dismissed, and
on a page that never earns an auto-open it does what it always did.

Auto-open asks a NARROWER question than pill eligibility, and the two are not the
same question. A bare platform host recognizes (`x.com/home`, `tiktok.com`) and a
feed that slips past the static-image suppression can earn a pill — but covering
someone's feed with a panel they did not ask for is a different act from offering
them a button beside it. It takes the same two authorities the pill takes, in the
same order: **the URL shape** where a platform has video-only surfaces
(`pathIsInherentlyVideo`), otherwise **the video signal** (`og:video` / player
metadata / a `<video>` / a GIF). Order matters here rather than being tidiness —
an Instagram reel carries no video metadata at all and hydrates its `<video>`
long after this file runs, so on the one platform where the signal never comes,
the path is the whole answer. Where the signal IS the answer, a client-rendered
post frequently has none of it at `document_idle`, so it looks again on a bounded
schedule (`AUTO_PLAYER_RETRY_DELAYS`, three looks inside ~2.5s) instead of giving
up on the first look. A dismissal cancels whatever is still pending: closing it
once means this page, not this instant.

```
content.js (recognized media page, or a pill tap)
  → runtime.sendMessage {type:"resolveMedia", url, title}
  → background.js relay → sendNativeMessage
  → SafariWebExtensionHandler: SocialMediaResolver().resolveAssets(for:)   ← the app's own resolver
      ├─ ResolvedMediaCache (App Group)  ← the FULL [MediaAsset]
      └─ reply {assets:[{url, kind, thumbnailURL?}]}  ← only what a <video> can stream
  → content.js sets <video src>
```

**Shape.** A dimmed, blurred fixed backdrop (tap to close); a panel at
`calc(100vw - 24px)` capped at 640px, near the full width and **only as tall as
its contents**; an X at the top left; the stage; a full-width Download button
beneath, filled with the media kind's tint (see "Colour" above). Built the same way the pill and the setup confirmation are — plain
elements, every style assigned through `applyStyle` (CSSOM property assignment,
so a page's `style-src` CSP can't strip it), all text via `createTextNode`,
`<div role="button">` rather than `<button>`, `z-index: 2147483647`, idempotent
by element id. **There is no Share button**: the thing worth sharing is the video
file, which does not exist until it has been downloaded — sharing happens in the
app afterwards.

**The popup's HEIGHT is the clip's, clamped at both ends.** A 9:16 reel in a 16:9
letterbox is mostly black bars, so the stage takes the media's own aspect ratio —
but it never goes *below* the 16:9 it opens at (a wide clip gets exactly the panel
that shipped; the opening shape is a floor, not a starting point) and never past
what is on screen. The stage is the only part of the panel whose size ever
changes; the rest (padding, header, button) is measured at run time and is what
the ceiling subtracts, so a wrapped label or a large accessibility font is already
accounted for.

The clamp is taken from **`window.visualViewport`, and this is the whole subtlety
of the feature**. Both obvious answers are wrong: `100vh`/`100dvh` is the *large*
viewport (laid out as though Safari's toolbars were retracted), and
`position: fixed` is laid out against that same box — so the backdrop's own height
is no better an answer than `100vh`. A panel sized by either runs under the
address bar on a real device while every simulator test still passes.
`visualViewport` is the one thing that reports the box that is on screen right
now, so the backdrop is pinned to it (`top`/`height` from `visualViewport
.offsetTop`/`.height`, `bottom: auto`) and the flex centring inside it is then
centring in what the user can actually see. The safe-area insets are subtracted on
top of that, as the backdrop's PADDING (`calc(14px + env(safe-area-inset-top))`
and the bottom equivalent): they describe the unsafe part of exactly that box, and
resolve to 0 on any page that isn't `viewport-fit=cover`. A toolbar collapsing, a
rotation or a pinch re-runs both (`visualViewport`'s `scroll` moves the backdrop,
`resize` also re-clamps the stage).

The aspect ratio itself comes from the media, in two steps: the page's own
`og:video:width`/`height` or `twitter:player:*` if it declares any (a beat earlier
than the stream, and free), then authoritatively from the element's
intrinsic `videoWidth`/`videoHeight`. `preload="metadata"` is only advisory on
iOS, so content.js explicitly calls `load()` after insertion and rereads the
intrinsic size on `loadedmetadata`, `loadeddata`, `canplay`, `durationchange`,
and `playing`; a Play or Download tap is never the first opportunity to size the
panel. Most posts declare nothing (an Instagram reel declares no video at all),
so the second step is the one that usually does the work; the first size is applied without animation
because it is the panel arriving, and every correction after it animates because
it is the panel growing to fit. `SafariVideoOverlayTests`' shape section pins all
of it, and `SafariVideoOverlayContractTests.testTheHeightIsClampedToTheVisual
Viewport` pins the one part no rendering test can (a bare `WKWebView` has no
browser chrome to be wrong about).

**Why the resolve happens before the user needs to tap play.** The overlay opens
in a loading state and sets `src` when the answer arrives, so the play tap on the
native controls is a genuine user gesture driving playback directly — which is
what lets it play unmuted inline.

A Safari → Luna → Safari bounce can reconstruct the content-script DOM even
though the tab never left its page. The native handler reuses that page's existing
fresh `ResolvedMediaCache` entry for ten minutes, so the replacement player gets
its source immediately and runs the same sizing path again. It does not persist a
panel size; the size is always re-derived from the live media element.

The Download handoff waits only for Luna to persist the destination and recoverable
download job and to create its Live Activity. Asset-size preflight then continues
under the same short app background-execution lease used by every media download;
once the named background `URLSession` task is registered, the system owns the
transfer. Luna immediately asks the system to reopen the original `https` URL, which
returns to the existing Safari page rather than intentionally creating a new tab.
The queued resolved-media record carries a one-minute copy of that return intent so
launch/foreground recovery cannot consume the queue before `openURLContexts` and lose
the bounce. The marker expires independently of the download: a failed responder-chain
open still downloads on a later launch, but that later manual launch stays in Luna.

**The page's own CSP governs the media load**, so this only ever plays a
same-platform asset — and every platform we resolve allows its own CDN
(instagram.com allows `*.cdninstagram.com` in `media-src`, x.com allows
`*.twimg.com`, tiktok.com's `default-src` covers `*.tiktokcdn*.com`, youtube.com
ships no `media-src` at all).

**The page's own player is paused while the overlay is up.** Every platform this
pill appears on autoplays its own video, and an overlay does not stop it — the
user would hear two soundtracks. The overlay pauses exactly the `<video>`s that
were playing when it opened and resumes those on dismiss; one the user had
already paused stays paused. Since the panel now opens BEFORE the page's own
player necessarily exists, that pause cannot be a one-shot sweep: a capture-phase
`play` listener on the document (`play` does not bubble) pauses — and remembers —
anything outside the panel that starts playing for as long as the panel is up.
Without it, the auto-open's own earliness is what would leave a reel autoplaying,
unmuted, behind the overlay.

**Everything that can go wrong lands in one place.** An empty resolve, the
handler's 20s budget, the JS 25s backstop, a CSP refusal, or an expired
IP-bound googlevideo URL all surface as either an empty asset list or a `video`
`error` event: the stage is replaced with a short message and Download reverts to
the navigation the pill did before this feature existed. Nothing is lost.

**Reddit keeps exactly today's treatment** — the plain pill, navigating into the
app — and does not enter the overlay path (`evaluateRedditPage` keeps building
`downloadTargetFor`). Reddit hosts video and audio as two independent DASH
streams, so a browser handed the video URL plays it silently; muxing is the
download pipeline's job (`MediaMuxer`). This is expressed twice, deliberately:
as the routing above, and as `MediaAsset.isDirectlyPlayable` in LunaMediaResolve
(no separate audio track, not a still), which the handler filters its reply
through — so the extension never names a platform to get this right.

**Download.** The page never holds a `[MediaAsset]`: it says
`{type:"queueResolvedDownload", url}`, and the handler promotes its own cached
record — the **full** asset set, including a split audio stream the player could
not use — into `PendingResolvedMediaStore`. The page then navigates
`<scheme>://resolvedmedia?ret=safari`, a payload-free link exactly like
`rescue`. `SceneDelegate.route` drains via `KindWiring.drainPendingResolvedMedia`
→ `PendingResolvedMediaDownloads.drain` (LunaMediaDownload) →
`LiveMediaDownloadManager.startWithResolvedAssets`, then bounces back to Safari
through the same `SafariReturnPolicy` a media pill save uses. The drain also runs
at launch and on foreground, because an appex-initiated app open can silently
fail; Reader and Price Tracker answer the same deep link with a no-op (their
handler gates `resolveMedia` on `hostHandlesMedia`, so nothing can ever queue for
them). Store lifetimes: the cache is 1 hour / 12 entries (CDN URLs expire
anyway), the pending queue is 3 days with take-semantics.

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
   `<ownScheme>://read?url=<source>` with `captureContent: true`. Before deciding which pill(s) to show, `content.js`
   extracts a passive product SNAPSHOT and sends it (see "Passive product snapshots"
   below); the reply decides whether Track shows at all.

### Passive product snapshots + the "Was $X on <date>" history pill

Every time a product-handling extension (Price Tracker / central Luna) sees a product
page, `extractProductSnapshot()` (next to `looksLikeProductPage`) pulls `{name, price,
currency, keyed identifiers, canonical URL}` from the SAME structured tiers the
classifier already checked — JSON-LD `Product`/offer, OpenGraph `product:price:*`, or
microdata — with **no heuristic/rendered-DOM tier**: a page with no structured price
yields no snapshot at all, mirroring `ProductInfo`'s "the price is mandatory" rule.
Identifiers are keyed (`gtin`, `mpn`, `sku`, `productID`, `retailerItemID`, `brand`),
never flattened, so matching scope rules (an ASIN only matches `amazon.*`, an SKU only
the same host, …) stay applicable downstream. The canonical URL strips the same
tracking params (`utm_*`, `gclid`, `srsltid`, `ref`, Amazon's `tag`) `content.js`
already knows about from `GoogleShoppingProductParser`.

One message, `{type: "productSnapshot", snapshot}`, does BOTH jobs in a single round
trip: the native handler (gated `hostHandlesProducts`) validates and PERSISTS the
snapshot into an App Group JSON file (`LunaSafari/SharedProductSnapshots.swift` —
`Library/ProductSnapshots/productSnapshots.json`; deduped by (canonical url, day),
pruned past 365 days / 2000 records), then ANSWERS the history-pill query by matching
the page against (a) `priceHistoryIndex.json` (the app-written compact index of
tracked products — `PriceHistoryIndexWriter`, LunaPriceUI, regenerated after every
save/refresh/background) and (b) the snapshot file itself, using the SAME identifier
precedence `SnapshotMatcher` uses app-side (GTIN → retailer-id/host-family → mpn+brand
→ sku+host → canonical URL → fuzzy name) — `LunaSafari/SharedProductMatching.swift` is
a THIRD hand-written copy of that logic (the extension links no package), pinned by
`SharedProductMatchingParityTests`. The reply is
`{hasHistory, isTracked, amount, currency, day}`: `isTracked` skips the Track pill
entirely (`renderProductPills`); `hasHistory` — the lowest matched price strictly
BELOW the page's current price, same currency only, ties broken by earliest date —
shows a second, **non-interactive** (`pointer-events: none`) pill, `Was $79.99 on
1/12/25`, stacked above Track when unsaved, alone when already tracked, absent
entirely when tracked with no cheaper history. Snapshots are NEVER saves: no
reading-list row, no scheduled refresh, no alert — they exist to seed a tracker's
history at save time (`claudedocs/price-tracking.md`), to fold into EXISTING
trackers as past-day history via `ProductSnapshotSweep` (LunaPriceUI — run at the
product apps' launch and at the head of every refresh cycle, matched by product
code through `SnapshotMatcher`, never by URL equality), and to answer this query.
Two capture details that were bugs first: the native validators SANITIZE the raw
price text the meta/microdata tiers send (`"$1,299.00"` used to fail
`Decimal(string:)` and drop the whole record, silently), and the suggestion mode
`"never"` silences PILLS only — `offerLunaButton` still records the passive
snapshot through `recordProductSnapshotSilently` (the mode was never about the
price record).

### The alternative-seller pill ("$59.00 at Acme")

A second message on the same product pages, `{type: "comparableSellers", snapshot}`,
asks the one question the history pill cannot: **is this cheaper somewhere else right
now?** It is deliberately a SECOND round trip rather than a rider on `productSnapshot`
— that reply is answered from two local files and is instant, while this one may take
seconds, and a page should not wait to learn what Luna already knows.

```
content.js (after the productSnapshot reply)  → spinner pill + Track pill
  → runtime.sendMessage {type:"comparableSellers", snapshot}
  → background.js relay → sendNativeMessage
  → SafariWebExtensionHandler → ComparableSellerFinder.answer(forPageSnapshot:)
      ├─ 1. priceHistoryIndex.json + productSnapshots.json, <24h            ← no network
      ├─ 2. else SellerFanOut(.constrained) over URLSession                 ← LunaPriceCompare
      │      └─ results written back via SharedProductSnapshots.record
      └─ reply {found, price, currency, sellerName, url}
  → content.js fills the pill in place — found / "No better price found" /
    "Unable to find better prices" — all three replace the spinner in its slot
```

Natively (`LunaSafari/ComparableSellerFinder.swift`, gated `hostHandlesProducts`) it
runs two legs in order:

1. **What is already stored.** The app-written `priceHistoryIndex.json` and the
   passive snapshot file, matched to this page by `SharedProductMatching`'s existing
   tiers. Costs no network, and after one visit to a rival's page it is usually enough.
2. **A constrained fan-out**, only if leg 1 has nothing: `SellerFanOut` with
   `.constrained` (6 candidate retailers, 3 results, no web-search layer, **no
   name-only matches**), fetched with a bare ephemeral `URLSession` carrying
   `WebFetchConstants.safariUserAgent` and its byte cap — the appex cannot link
   `LunaFetch`, and the engine takes its fetching injected precisely so this
   environment exists. A page declaring **no GTIN and no MPN skips this leg
   entirely**: with name-only matching off, the run could only end in refusals after
   spending 15s and six retailers' bandwidth. Everything it fetches is written back
   through `SharedProductSnapshots.record` — a fan-out result IS a snapshot — so it
   prunes with everything else and feeds the "Was $X" pill on the next visit.

`FreshComparablePrices` (LunaPriceCompare) is the whole decision, and all four of its
conditions are refusals: **>24h stale** (the pill claims a price is better *now*, and
a year of snapshot material cannot support that), **a different currency** (Luna has
no FX source anywhere — see the unpopulated `PriceDaySnapshot.fxRate`), **not strictly
cheaper** than the page, or **the page's own retailer**. Ties break on the registrable
domain so the same inputs never name two different shops. An index point records a
DAY, not an instant, so it is dated to that day's UTC start — which makes "fresh"
exactly "recorded today", since today's start is always under 24h ago and yesterday's
never is.

Budgets nest: the fan-out's `.constrained` 15s sits inside the finder's 18s, which
sits inside the handler's 20s, which sits inside the page's 25s backstop. Only a dead
appex reaches the outermost one.

In the page, `beginSellerLookup` puts up a spinner pill (a pulsing dot via the Web
Animations API — no stylesheet injected into someone else's document) in the SAME slot
the history pill would take, plus the Track pill, which is not waiting on anything.
`finishSellerLookup` then fills that pill in place with one of THREE terminal states —
the pill never just vanishes:

- **found** — `<price> at <Seller>`, `role="button"`, `pointer-events: auto`, the
  destination on a `data-luna-seller-url` attribute so the tap reads what was
  rendered;
- **empty** (`"No better price found"`) — the search COMPLETED and found nothing
  cheaper (`{found: false}`, or a found answer with no URL to send the tap to);
- **failed** (`"Unable to find better prices"`) — the LOOKUP itself died: the
  relay's catch (`{found: false, failed: true}` — only the catch sets `failed`, which
  is what keeps the two non-found states distinguishable), a thrown request, or the
  page's 25s backstop.

The two non-found states are informational (`pointer-events: none`) and KEEP the
slot, so the history pill is not rendered behind them — the seller pill and the
history pill never coexist: both speak about this product's price, and only one can
be the more useful thing to say. The Track pill was never waiting on the lookup and
is already on the page. One lookup per page, its flag set before any DOM work.
`ProductHistoryPillRenderTests` drives all of it through the shared
`SafariJSTestHarness` web view.

### Bounce back to Safari after a media save

Only a Downloader media pill carries `&ret=safari` on its deep link. Once
`ReadingListIngestor.handleSavePress` returns and the download has started, the Live
Activity is up, and `SceneDelegate` decides via the pure
`SafariReturnPolicy.shouldReturn` (LunaURLClassification) whether to reopen the original https page —
`UIApplication.shared.open`, never a private `x-safari-https://`-style scheme, and
never the `URLUnwrapper`-resolved URL. A failed or unsupported save keeps the user in
the app to see the error surface. Article and product saves also remain in Luna:
their reader and Price Tracker cards are the destination. The policy rejects a return
flag for either kind as defense in depth for stale deep links. Known limitation: the
media bounce opens the user's DEFAULT browser (Safari unless changed) and typically a
NEW tab, not the tab the pill was tapped from — there's no supported "return to the
previous app" API.

Paywall unlock + toast:
- The native handler answers `bypassEnabled` true only for article-handling hosts
  (Reader and the central Luna app) — unlocking is article handling, so the
  Downloader / Price Tracker extensions never enable the declarative Referer
  ruleset (background.js) or the in-page overlay cleanup (content.js
  `revealArticle`). No user preference.
- `revealArticle`'s cleanup is structure/attribute-driven, not a site list: besides the
  named overlay selectors it removes generic component-driven walls (`[data-component-type*=paywall]`,
  `pw-modal`/`paywall-backdrop`/`registration-wall`-style containers, `[id*=paywall]`) and
  un-clamps any element that STILL holds substantial prose but is inline-clamped with a
  genuine "faded teaser" signature — a `max-height` limit AND a visual fade
  (`mask-image`/`linear-gradient`/`filter:blur`); bare `overflow:hidden` or a bare
  `max-height` is ubiquitous layout styling and is deliberately NOT matched (force-
  revealing those rewrote a complex SPA's own layout containers and blanked NYT — the
  un-clamp now clears only the clamp/fade properties, never height/display/visibility).
  Every removal is `articleChars`-guarded — a node holding the real story is REVEALED,
  never deleted. This dismantles a metered wall that overlays/clamps the body (e.g.
  Business Insider's `pw-modal-backdrop` + `inline-backup-paywall` + clamped
  `[data-content-container]`) in Safari itself. It cannot restore body text a site
  DELETES client-side; that case still relies on the pill → in-app reader (which
  re-extracts the body from the server HTML). Note the network `blockers` ruleset only
  helps when the wall's metering script sits at a URL the rule matches — sites that
  bundle metering into their main app JS (BI now does) can't be blocked without breaking
  hydration, so the DOM cleanup is the durable path there.
- **Do not blame the block rules for a blank page.** Twice now a blank NYT tab was
  diagnosed as "the per-site block rules break hydration on a site whose unlock also
  needs `useragentCustom`, so don't emit them" (45589c52, reverted; then 5b2085ec, also
  reverted). Both were wrong: the blank was `annoyances.js` putting `display:none` on
  `<body>` (see the annoyance section above), and neither `content.js` nor the `blockers`
  ruleset was involved — bisected in a real WKWebView against the live article. The
  rules earn their keep on exactly this site: NYT ships the FULL article body in its
  embedded client state (verified — 16 `ParagraphBlock` nodes, ~4.6k chars) and its
  metering JS truncates the RENDER to the first 7 paragraphs plus a subscribe pitch. So
  blocking `nytimes.com/meter.js`, `svc/onsite-messaging/query` and `mwcm.nyt.com/*.js`
  is what lets the rest render in Safari — and dropping those rules truncates what the
  "Read in Luna" pill captures, which the app then accepts as a readable body (a trusted
  prefetch clears the 1200-char threshold without the paywall re-check), i.e. a
  truncated in-app article. Re-verify against the live site before touching them again.
- **A wall that redirects has nothing to reveal — so leave the page.** Some publishers
  don't overlay a wall on the article; they server-side redirect to their own subscribe
  page (News Corp Australia: `…/subscribe/news/1/?dest=<article>`), so Safari's address
  bar shows the interstitial and the article is not in the DOM at all. Before the
  cleanup runs, `escapeSubscribeInterstitial` navigates to the article the interstitial
  itself names, with an `?amp` flag (`withAMPFlag`, the same transform as Swift's
  `AMPQueryBypass.ampQueryURL` — those sites serve the AMP rendering un-metered, and
  the `blockers` ruleset already kills `amp-subscriptions-*.js` on them). It is
  deliberately narrow, because it MOVES the user: only on a known news host (the shared
  `__LUNA_NEWS_HOSTS` list — no new site table), only on a SUBSCRIBE-family path (never
  sign-in / register / checkout, where hopping to a `?next=` target would abandon
  something the user started), only to a same-site absolute http(s) target that isn't
  itself an interstitial (the open-redirect guard, mirroring
  `NewsAggregatorUnwrapper.interstitialTarget`), and once per destination per tab via
  `sessionStorage` so a site that bounces straight back can't ping-pong.
  `location.replace`, so Back returns where the user came from. Target sources: a
  `dest=`-style param, else `og:url` with `og:type=article`. Test hooks:
  `window.__lunaSubscribeInterstitialTarget` / `__lunaWithAMPFlag`
  (`SafariSubscribeInterstitialTests`, in a bare WKWebView).
- **AMP subscriber gating.** `revealArticle` also unhides `amp-subscriptions` content:
  such a document ships the story AND the pitch and lets the runtime pick after load,
  so `[subscriptions-section="content"]` has the attribute removed in place while the
  gate nodes (any other `subscriptions-section` value, `[amp-access-hide]`) are
  removed. Mirrors `AMPQueryBypass.extractableHTML` (Swift, silent tier) and upstream's
  `amp_unhide_subscr_section`; removing a real gate counts as an unlock for the toast.
- When a reveal actually unlocks something (page had paywall markers, or the cleanup
  removed/revealed a paywall node — the generic UNHIDE class sweep doesn't count),
  content.js shows a brief "Unlocked with Luna" toast: a capsule in the article tint,
  centered
  above the button's corner (bottom ≈84px + safe area, so the two never overlap),
  fading out after ~3s. The "Read in Luna" button still appears independently.

The setting lives in Settings → Shortcut & Safari ("Read in Luna Button" on Reader,
"Download Button" on Downloader, and "Track in Luna Button" on Price Tracker — a
3-segment control). **Nothing about the extension is version gated** — `nativeMessaging`
needs no particular iOS, so the pills, the unlocking, and the recent-URL history the util
card offers run everywhere Luna does. On a device with no Action Button shortcut to set up
(`ShortcutSettingsScreen.deviceHasShortcutSetup`: iOS 27 AND Action Button hardware) this
screen keeps only the Safari-button setting and renames itself "Safari"; the shortcut,
On-Screen URLs and Double Save sections are hidden, since all three are behaviors OF that
shortcut. `background.js` relays
`buttonContext`/`buttonMode`; content scripts can't call `sendNativeMessage` directly.

## Enabling (simulator/device)

Settings → Apps → Safari → Extensions → Luna → enable + allow all websites. Verify via Luna app Settings screen ("Safari extension status" shows last tracked URL).
