# Luna — four weblink apps over one shared store (experiment)

Luna is a family of **four standalone iOS apps** (UIKit, deployment target iOS 18;
FoundationModels/new-API code is gated behind `@available(iOS 26, *)`)
that share one App Group, one on-disk store (`readingList.json`), and one codebase:

- **Luna** (`com.hsanabria.luna`, Xcode target `Luna`) — the central, PAID app:
  the only app whose every surface (app, share/action/safari extensions, App
  Intents) accepts and processes EVERY content kind. Its home screen is the
  reader-style card deck showing all kinds. Placeholder crescent-moon icon.
- **Luna Reader** (`com.hsanabria.luna.reader`, target `LunaReader`) — articles,
  paywalled articles, documents. Scrolling reader (inline split-web frames) + RSVP speed
  reader; background-playback read-aloud with autoplay-next and on-device trimming (see
  `claudedocs/audio-playback.md`); send-to-Kindle (emailed through the connected email account);
  share-sheet export of any unlocked article as EPUB / PDF / Markdown / plain text
  (`claudedocs/article-export.md`, shared with the central app); long-form X posts and
  self-threads read as articles (`claudedocs/x-posts.md`, shared with the central app —
  X serves no post text to an unauthenticated client, so that ONE kind's text comes from
  the keyless fxtwitter mirror instead of HTML extraction).
- **Luna Downloader** (`com.hsanabria.luna.downloader`, target `LunaDownloader`) —
  social / video / audio links + friend-sharing (email-based; see
  `claudedocs/social-sharing.md` — no CloudKit).
- **Luna Price Tracker** (`com.hsanabria.luna.pricetracker`, target `LunaPriceTracker`) —
  product price tracking.

Every app classifies ANY incoming URL through the one shared pipeline; a
single-content app then DROPS foreign kinds with a generic error (nothing is
stored), while the central Luna app processes everything — behavior is fixed at
compile time by each target's link set + per-target composition files. See
`claudedocs/surface-support.md`.

**`luna` is a placeholder namespace** — rename it by editing the two top lines of
`Config/Luna.xcconfig` (`LUNA_NAMESPACE`, `COMPANY_PREFIX`). Everything derives from
there: bundle ids (`$(PRODUCT_BUNDLE_PREFIX).<app>`), the **shared** App Group
(`group.com.hsanabria.luna`), display names (`$(DISPLAY_NAME_PREFIX) …`), and — via
the Info.plist key `LunaAppGroupID` read by the `LunaAppConfig` library (`AppConfig`)
— the in-code identifier. Entitlements reference `$(APP_GROUP_ID)`.

**Shared store + surfacing.** Any link saved through ANY app (share sheet, action
extension, App Intents, Safari extension) is classified by the shared
`LunaIngest.IngestPipeline` into a `ContentKind` and written to the one shared
`readingList.json`. Each app shows only its category: every app's root is a CARD
DECK, and `LunaApp.current` — derived from the bundle-id suffix — decides both what
it shows (`LunaApp.includes`, in `LunaReadingListUI`) and what it accepts
(`SurfaceSupport`, the ingest gate). Items of other categories are stored but
surface only in their own app. There is no sectioned table list: it was deleted
once every app rooted on a deck. Feature docs live in `claudedocs/` — keep them current when changing features.

**Targets.** Four app targets (`Luna`/central, `LunaReader`, `LunaDownloader`,
`LunaPriceTracker`) each share the `Luna/` app-shell sources via the same synchronized
group. Each app bundles its OWN copies of the universal share / action / safari extensions
(`<Target>Share/Action/Safari`, bundle ids `<app>.share|.action2|.safari`, all on the shared
App Group) — an app-extension bundle id must be prefixed by its host app, so the same
extension SOURCE is built once per host. **Two extensions are NOT universal**: an App
Clip (`LunaReaderClip`, `LunaDownloaderClip` — the "Share Link…" recipient flow, see
`claudedocs/readers.md`) and the Live Activity widget (`LunaLiveActivity`,
`LunaDownloaderLiveActivity`). The Live Activity renders the ONE activity in the
codebase, `LiveMediaDownloadAttributes` from LunaMediaDownload, and ActivityKit only
lets the app whose process called `Activity.request` show it — so only the two
media-handling hosts embed it. Reader and Price Tracker link no media module, so their
copies could never fire and were removed; do not re-add one to an app that does not
link `LunaMediaDownload`. Per-target COMPOSITION uses synchronized-group
membership exceptions (exactly one `KindWiring+*.swift` / `ShareEntry+*.swift` /
`ActionEntry+*.swift` variant compiles per target — `#if canImport` is NOT target-reliable
here, never use it for gating). **An app has SEVERAL composition roots** — `KindWiring+<App>`
(the app), `ShareEntry+<App>`, `ActionEntry+<App>`, and the App Clip's own `AppDelegate` —
each running in a different process with no shared wiring code. They must NEVER write
`IngestKindProcessors` / `ShareKindPresenters` themselves: **each kind's registrations are
defined once in a KIND PACK** (`ArticleKindComposition` in LunaReaderUI,
`MediaKindComposition` in LunaMediaDownload, `ProductKindComposition` in LunaPriceUI), and a
root just calls `<Kind>KindComposition.install()` for each kind its app handles. Hand-listing
per surface is what produced the split where a long X post saved inside the app worked but the
same link through the share sheet was dropped as another app's kind. The per-app split is
unaffected: a pack lives in the kind's own module, so only a target that LINKS that kind can
install it. `KindCompositionRootTests` fails the build on a direct registry write, on a root
whose installed packs don't match its app's kinds, and on a new unlisted root.
`IngestorKindHandlers` stays per-`KindWiring` (it is built from app-shell types). See
`claudedocs/surface-support.md`'s "Kind packs". **DELETING a file that carries a membership exception
means editing `project.pbxproj` too.** The synchronized group picks up added files by
itself, but each exception is a by-name entry under
`PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions`, and one naming a
file that no longer exists is a dangling reference: Xcode (and any CLEAN build) fails with
`Build input files cannot be found`. A warm-derivedData `xcodebuild` run does NOT catch
this — verify removals from an empty `-derivedDataPath`. `LunaTests` (unit tests) hosts on the central Luna app, so
the `-scheme Luna` recipe below is unchanged and the test host registers every kind
processor at launch. New app targets are generated by `scripts/add_luna_app.rb` (xcodeproj
gem). Dependency: SwiftSoup. Dev with Xcode 27 beta / iOS 27 simulator; archive/upload with
stable Xcode 26.2.

> **Surface gating.** There is NO onboarding flow — every app opens straight into its
> main UI, and notification authorization is requested at launch. Email is a
> per-app capability, `LunaApp.sharesByEmail` (true for `Luna` and
> `LunaReader` only): those two connect an account, send saves to contacts
> (`claudedocs/social-sharing.md`) and import shares/newsletters from a mailbox
> (`claudedocs/incoming-mail.md`) — each still KEEPING only its own kinds from those
> sources. Downloader and Price Tracker share by plain URL through the system share
> sheet: no account, no Contacts screen, no mail import, no mail-fetch background
> task. An account is connected INLINE in Settings → Email & Sending (whose Sharing
> Account section is the sign-in form until one exists, see
> `claudedocs/email-login.md`), and an attempted send without one redirects there.
> Shortcut install and Safari-extension setup live in Settings → Shortcut & Safari.
> Per-app content
> kinds, the drop behavior, and the composition mechanism are documented in
> `claudedocs/surface-support.md`. UI prose says
> "Luna"; each app has its own `AppIcon{Luna,Reader,Downloader,PriceTracker}` (PNG appiconsets in
> `SharedIconAssets.xcassets`; `scripts/make_icons.py` is retired — update the PNGs directly).
> The ACTION extensions use separate `{Luna,Reader,Downloader,PriceTracker}ActionExtIcon`-style
> sets (`ReaderActionExtIcon`, `LunaActionExtIcon`, …): iOS
> renders action-extension icons as monochrome templates from the icon's ALPHA channel, so an
> opaque app icon shows as a solid blob. `scripts/make_action_icons.swift` extracts each glyph
> directly from the foreground artwork in its committed 1024px `AppIcon*` master (open book,
> segmented download arrow/tray, tag-with-magnifier; crescent moon for the central app) and
> converts it to monochrome alpha. Do not
> substitute generic symbols or invent new action artwork. Share extensions keep the full-color
> `AppIcon*` sets.

> **Appearance: both modes are night, and the sky is NOT `userInterfaceStyle`.** Dark mode is
> true black; "Light" is the **predawn** theme — the same near-black sky lifted one barely
> perceptible notch (mean 0.055 vs 0.000) and faintly tinted with the app's own colour cooled
> toward pre-sunrise blue. Because UIKit's own materials (Liquid Glass, blur, alerts,
> keyboards, scroll indicators, text selection) key off `userInterfaceStyle` and render LIGHT
> under a light trait, the style is **pinned to `.dark` app-wide** and the chosen appearance
> rides a custom trait, `LunaSkyTrait` (`LunaSky.night` / `.predawn`) — see
> `claudedocs/visual-effects.md`. Consequences: a view caching resolved `CGColor`s must
> `registerForTraitChanges([LunaSkyTrait.self])` (**a style change will never arrive again**);
> `.system` follows the device via the window *scene*, not the window; `AppearanceSettings.apply`
> has a `UIWindow` form for apps and a `UIViewController` form for surfaces living in someone
> else's window (share/action extensions via `ShareViewController`, both App Clips); and code
> rendering Luna colours onto a foreign surface must resolve them against an explicit trait
> collection (as `PriceGraphEmailSnapshot` does). The one deliberate hold-out is the Live
> Activity widget, which keeps system semantics and so still goes light with the OS.

## Agent workflow

- Always commit completed work in small, logical chunks as you go — don't wait for
  explicit permission each time, and don't batch everything into one commit at the
  end of a task. Do not bundle unrelated changes into the same commit.

## Module structure

Almost all code lives in the local SwiftPM package `LunaLibraries/` (layered: config/models
→ URL/HTML parsing → fetch/bypass/ingest → services → UIKit feature libs →
orchestration/intents; `LunaAppConfig` at the bottom is the App-Group id source of
truth). The Xcode targets are thin shells: the `Luna/` folder holds the shared app shell
(AppDelegate/SceneDelegate), per-app Settings, the main-screen composition
(each app's card deck), composition wiring (AppReaderProviders), the App Intent **definitions** (`Luna/Mail/Intents/*` —
business logic is in the `LunaIntents` library) — and is shared by ALL
FOUR app targets (each picks its surface from its bundle id; per-app kind wiring
comes from the one `KindWiring+*.swift` variant each target compiles). `KindWiring` is
also each app's static composition API: AppDelegate/SceneDelegate call
`KindWiring.makeRootViewController()/mainNavigationController(of:)/settingsCategories()`
plus fixed lifecycle points (`appDidLaunch/appDidEnterBackground/sceneDidForeground/
readingListDidChange/wifiBecameAvailable/retryPendingArticleSends/
resumeUnfinishedMediaDownloads/attachBackgroundURLSessionHandler/priceRefreshRunner`), so
the universal shell never names a foreign kind's symbols. The Action Button intents' media handoff goes through
`ActionButtonIntentSupport.mediaHandoff` (installed by `MediaIntentHandoff`), read-aloud via
`ReadArticleIntent.playArticle`, and URL Rescue's kind legs via
`URLRescueWiring.mediaRescueStarter`/`rescueProductInfo`. Kind-specific shell files
(article: card deck, mini-player, audio wiring, reader/email settings; media: saved-media
deck, auto-download settings, intent handoff; `UITestScreen`/`NonArticleCardOpening`:
central-app-only) are excluded from foreign targets via the same membership-exception
mechanism. The Share/Action extensions
link `LunaShareSurface` (+ transitive) plus their host's kind modules, `LunaSafari` links
nothing (it reads the App
Group id from its own Info.plist via `SafariAppGroup`). Cross-tier wiring uses injected
closures/protocols installed at launch in AppDelegate or KindWiring (e.g.
`AudioPlaybackCenter.dataSource`, `ReadingListIngestor.unsupportedSavePresenter`,
`DiagnosticLog.exportIdentityProvider`,
`PriceTrackingViewController.defaultSaveAsArticle`). Component-boundary communication
inside the UI layers uses delegate protocols (e.g. `RabbitHoleLayerDelegate`,
`ReaderCompletionDelegate`, `InlineReaderPresentationCoordinating`,
`CarouselScrubberViewDelegate`), not stored closures. The package is pinned to Swift
5 language mode. Reusable modules need `public` API + explicit `public init`s.

**Per-app SwiftPM link groups.** Every app links the universal set — Models / Storage /
DesignSystem / Transitions / Fetch / Ingest / URLClassification / HTMLClassification /
PriceMetadata / Mail / MailAccount / MailTransport / Social / SocialUI / ReadingList /
ReadingListUI / Intents / URLRescue / ShareSurface / SwiftSoup — plus its own kind group(s):

| App target | Kind group(s) linked on top of the universal set |
| --- | --- |
| `Luna` (central) | article + media + product (everything) |
| `LunaReader` | LunaArticleIngest, LunaReaderUI, LunaArchiveReader, LunaPaywallBypass, LunaAudioPlayback, LunaReaderEngine, LunaEpub, LunaDocuments, LunaSend |
| `LunaDownloader` | LunaMediaDownload, LunaPlatforms |
| `LunaPriceTracker` | LunaPriceIngest, LunaPriceUI |

`LunaTests` keeps everything (it hosts on the central app). No foreign-kind
transitive edges remain: `SocialMediaResolving` lives with `MediaAsset` in
LunaModels and the rescue engine takes an injected resolver
(`URLRescueWiring.mediaResolverFactory`, installed by media KindWirings; the
`NoMediaResolver` default keeps media rescues unrescuable elsewhere); the
intent post-search machinery (`SocialPostFinder`/`DuckDuckGoSearch`/
`Bluesky|RedditSearchClient`) moved into LunaIntents (URL search is
kind-neutral); `BlueskyLink` moved to LunaURLClassification. Correctness never
depended on the link graph — it comes from the `SurfaceSupport` ingest gate
plus `LunaApp.includes` — but the graph now matches it.

## Running the unit tests (CLI — works headless, no Blitz needed)

The full `LunaTests` suite runs from the command line on an **iOS 26.x simulator**
(the project's deployment target is iOS 18 — the iOS 26.x simulator is just what's used
for testing) via the **`Luna`** scheme (the central Luna app is the test host, so
every kind processor is registered at launch). The `LunaReader` /
`LunaDownloader` / `LunaPriceTracker` schemes build their apps (`xcodebuild build
-scheme …`) but carry no test bundle of their own. Recipe:

> **Schemes: five, and only five.** `Luna`, `LunaReader`, `LunaDownloader`,
> `LunaPriceTracker`, and `AllLunaApps`. Each app scheme's build action lists
> **only its app** — every extension, clip and live activity is already a target
> dependency and gets embedded and signed with the host, so per-extension schemes
> are pure duplication and were deleted. `AllLunaApps` builds all four in one
> press (Luna is its runnable). Xcode's Run only *installs* a scheme's runnable, so
> to get all four onto a device or simulator in one go use
> `scripts/install_all_luna_apps.sh [<device-or-simulator>]` — it builds the
> aggregate scheme, then installs each app. The ~34 schemes Xcode synthesizes for
> `LunaLibraries` package targets are hidden via
> `xcuserdata/*/xcschemes/xcschememanagement.plist` (`isShown` false plus
> `SuppressBuildableAutocreation` for every non-app native target — without the
> latter, opening the project regrows a scheme per extension). That file is
> per-user and gitignored, so **run `ruby scripts/hide_generated_schemes.rb`** after
> adding a target, adding a package product, or on a fresh clone. It reads the app
> list and the package schemes from the project, so it needs no editing.
>
> **No spaces in paths.** Build inputs are all space-free (`LunaAction/`, not the
> old `Luna Action Extension/`; `AllLunaApps.xcscheme`, not `All Luna Apps`) —
> quoting bugs in build scripts are otherwise silent. The one deliberate exception
> is the bundled resource `Luna/Resources/Send To Luna.shortcut`, whose filename IS
> the user-visible name in the Action Button picker (`BundledShortcut.displayName`
> must keep matching it).

```sh
DD=<a derivedDataPath>
SIM=<a booted iOS 26.x simulator UDID>   # e.g. xcrun simctl list devices | grep -A8 'iOS 26'
xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM" \
  -configuration Debug -derivedDataPath "$DD" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

- **App icons use conventional PNG `.appiconset`s in
  `SharedIconAssets.xcassets`**, so stable Xcode 26.2's `actool` compiles every
  host app and extension. Do not add Xcode 27 Icon Composer `.icon` bundles to
  the project; they are not supported by Xcode 26.
- **`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO` works around a confirmed Xcode 26
  swift-build bug (swiftlang/swift-build#975).** Its target-dependency-graph
  validator emits spurious `'X' is missing a dependency on 'Y' because dependency
  scan … discovered a dependency` warnings against `LunaLibraries` package targets
  during test builds only — every flagged dependency is already declared correctly
  in `Package.swift` (verified directly: adding the "missing" edges didn't change
  the warning set at all). The setting is real (confirmed by reading swift-build's
  source) but only takes effect from a build-invocation-level override — neither
  the project's own `buildSettings` nor its `baseConfigurationReference` xcconfig
  reach local-package task planning, so it can't be fixed by editing project files
  and must be passed on the command line (or via `-xcconfig`) instead. Omitting it
  is harmless — the warnings don't fail the build — but this keeps output clean.
  Re-verified 2026-07-28 by diffing the 90 flagged pairs against `Package.swift`:
  6 looked undeclared, and all 6 turn out to have **no direct `import`** in the
  flagged target's sources at all (`LunaReadingList`→`SwiftSoup`,
  `LunaPriceIngest`→`LunaFetch`, …) — the scanner reports modules it loads
  transitively, so there is nothing to declare and adding the edges would be noise.
- **A build that fails with "cannot find type `LunaApp` in scope" in files you did
  not touch is a swift-build flake — RE-RUN, don't wipe.** Seen 2026-07-28 after
  editing `LunaModels`: three runs failed naming types that plainly exist
  (`LunaDeepLink`/`PlatformRecognizer` twice, `LunaReaderEngine/RSVPEngine` once —
  a *different* consumer each time), then the next identical invocation succeeded
  and has every time since. It is NOT the stale-module case that a derived-data
  wipe fixes: it reproduced immediately after `rm -rf "$DD"`, and afterwards five
  deliberate reproduction attempts all passed — touching `LunaModels`, adding a
  public type to it, three cold builds on fresh `-derivedDataPath`s, a populated
  `LunaLibraries/.build` from a macOS `swift build`, and brand-new source files in
  two package targets. Tell the two apart by whether the failing FILES change
  between runs; if they do, just run the command again.
- **The `Embedded binary is not signed with the same certificate as the parent app`
  error is permanently fixed.** The Luna app target has a **"Re-sign embedded
  extensions (debug)"** build phase (after Embed Foundation Extensions) that re-signs
  each `PlugIns/*.appex` with the app's OWN resolved identity
  (`codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY"`) so they always match the
  parent app on incremental builds — ad-hoc on the simulator, the Apple Development cert
  on a physical device. It's scoped to `CONFIGURATION == Debug` (no-op on Release /
  archive, so distribution/TestFlight signing is untouched), and covers both simulator
  AND device builds. You no longer need to delete the built `.app`/`.appex` products
  before each run. (Old escape hatch if it ever resurfaces:
  `rm -rf "$DD/Build/Products/Debug-iphone"*/*.app …/*.appex`.)
- **Do NOT pass `CODE_SIGNING_ALLOWED=NO`** — it strips the `group.com.hsanabria.luna`
  app-group entitlement, so the test host crashes at launch (early-exit, "external
  symbol") on app-group container access. Default ad-hoc signing applies the
  entitlement and the app group works on the simulator.
- **Every app target gets its OWN entitlements file** — `Luna/{Luna,LunaReader,
  LunaDownloader,LunaPriceTracker}.entitlements`. Never point two apps at one file even
  when the contents look identical today: `Luna` and `LunaReader` shared
  `Luna/Luna.entitlements`, so the central app inherited the Reader's
  `com.apple.developer.associated-appclip-app-identifiers` and every device build died
  with `Entitlement … not found and could not be included in profile` plus a misleading
  `No Accounts: Add a new account in Accounts settings` (automatic signing wanted an
  account session to go edit the `com.hsanabria.luna` App ID it should never have been
  touching). Only the two apps that actually have a clip may declare that key.
- **Current suite state on the iOS 26.x sim: 1915 tests, 9 skipped, 0 failures**
  (measured 2026-07-29 post-merge, full run with nothing skipped on the command line). The
  long-standing `AudioMiniPlayerTests` reference-image drifts are gone: the whole
  snapshot set was re-recorded for the predawn palette, and the harness now pins the
  same appearance the app does (dark style + `lunaSky = .predawn`, over
  `LunaColors.background`) instead of forcing a light style. The 9 skips are
  intentional `XCTSkip`s —
  `PriceTrackingScreenTests.testPriceTracking{,Alerting}EditorSnapshot`, two
  `SocialMediaResolverTests` live-YouTube transfers
  (`RUN_LIVE_YOUTUBE{,_BACKGROUND}_TESTS=1`), the four
  `EclipsePreviewRecorderTests` corona/starfield preview recorders
  (`RECORD_ECLIPSE_PREVIEWS=1` + `ECLIPSE_PREVIEW_DIR`), and
  `ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested`. One class,
  `ArticleAudioEngineTests` (14 tests, real `AVAudioEngine.start()` even in manual/offline
  rendering mode), is environment-fragile: on at least one Mac it reproducibly aborts every
  test with a mediaserverd "RPC timeout, apparently deadlocked" — reproduced across a
  simulator reboot and a sandbox toggle, ruling out a code regression (the class hasn't
  changed since it first landed). If you hit this, verify the rest of the suite with
  `-skip-testing:LunaTests/ArticleAudioEngineTests` and run that class alone/on another
  Mac. The ~36 failures previously documented here were all stale test data, not the
  environment, and have been fixed: snapshot reference PNGs are device-specific and
  were re-recorded on this sim with `RECORD_SNAPSHOTS=1` (re-record after intentional
  UI changes via `TEST_RUNNER_RECORD_SNAPSHOTS=1 xcodebuild test …` — the build-setting
  form does NOT reach the runner's environment); and the two extraction tests were
  aligned to the 1200 threshold. If snapshots fail again on a *different* device,
  re-record there rather than treating it as a regression.
- For a compile-only check (fast, no run): `xcodebuild build-for-testing -scheme Luna
  -destination 'generic/platform=iOS Simulator' DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`.
- **A target with an EMPTY Sources phase breaks `xcodebuild test` while plain builds
  "succeed".** The widget targets do NOT use synchronized groups — their sources are
  explicit per-target build files — so a scripted target clone must copy the source
  build files too. An empty appex target still links a phantom executor binary under
  the debug-dylib arrangement (plain build looks fine!), but the test-variant graph
  plans no link task, "Removed stale file"s the binary, and the test host can't
  install ("missing its bundle executable"). If that ever resurfaces, check the
  target's Sources phase FIRST. Also: never run the suite via
  `test-without-building` pointed at the products dir — its DYLD_FRAMEWORK_PATH
  loads second copies of the package frameworks and `as?` casts on app-created views
  fail spuriously (class-identity split).

# Swift Project — Blitz AI Agent Guide

## blitz-macos

This project is opened in **Blitz**, a native macOS iOS/macOS development IDE with integrated simulator streaming. The user sees Build, Release, Insights, Testflight tab groups, and can see simulator view in Build>Simulator tab.

### MCP Servers

Two MCP servers are configured in `.mcp.json`:

- **`blitz-macos`** — Controls the Blitz app: project state, tab navigation, App Store Connect forms, build pipeline, settings.
- **`blitz-iphone`** — Controls the iOS device/simulator: tap, swipe, type, screenshots, UI hierarchy. See [iPhone MCP docs](https://github.com/blitzdotdev/iPhone-mcp).
- **`asc` CLI** — A bundled Go binary at `~/.blitz/bin/asc` for direct App Store Connect API access. Shares credentials with Blitz MCP tools automatically (no separate login needed).

### MCP Tools vs `asc` CLI vs Direct API Calls

**Priority order: MCP tools → `asc` CLI → direct API calls (last resort).**

**Default to MCP tools** for common workflows — they are opinionated, safe, and integrate with Blitz's UI (approval prompts, progress tracking, form validation). **When MCP tools don't cover an operation, use `asc` CLI** — it has 60+ subcommands covering nearly every ASC API endpoint and handles JWT auth, pagination, and retries. **Direct API calls (python scripts, curl to api.appstoreconnect.apple.com, urllib) should be an absolute last resort** — only when both MCP tools AND `asc` CLI genuinely cannot accomplish the task. Before writing any script, run `asc --help` and `asc <command> --help` to confirm the CLI doesn't already support it.

**Use MCP tools for:** filling ASC forms (`asc_fill_form`), reading tab/app state (`get_tab_state`), the build pipeline (`app_store_setup_signing` → `app_store_build` → `app_store_upload`), creating IAPs/subscriptions, setting prices, managing screenshots, and submitting for review.

**Use `asc` CLI for:** listing builds (`asc builds list`), TestFlight beta management (`asc testflight`), certificate/profile inspection (`asc certificates list`, `asc profiles list`), analytics & finance reports (`asc analytics`, `asc finance`), release management (`asc releases`), submission management (`asc submit create`, `asc submit cancel`), custom product pages (`asc product-pages`), Xcode Cloud (`asc xcode-cloud`), Game Center, offer codes, bulk localization updates, and any ASC operation without a dedicated MCP tool.

| Task | MCP (preferred) | `asc` CLI (fallback) |
|---|---|---|
| Set app information metadata | `asc_fill_form` tab="appInformation" | `asc metadata update --locale en-US ...` |
| Check submission readiness | `get_tab_state` tab="ascOverview" | `asc versions list` + manual checks |
| Create subscription | `asc_create_subscription` (one call) | `asc subscriptions create` + localization + pricing (3 steps) |
| Cancel stuck submission | N/A | `asc submit cancel --id "..."` |
| List all builds | N/A | `asc builds list` |
| Add beta testers | N/A | `asc testflight add-tester --email ...` |
| Upload IPA | `app_store_upload` (with polling) | `asc builds upload --path ./app.ipa` |
| Financial reports | N/A | `asc finance download --period 2026-01` |

Both tools share the same API key via Blitz's auth bridge (`~/.blitz/asc-agent/config.json`). If `asc` is not on PATH: `export PATH="$HOME/.blitz/bin:$PATH"`

### Testing Workflow

After making code changes:
1. Wait briefly for hot reload / rebuild
2. Use `blitz-iphone` `describe_screen` to verify the UI updated as expected
3. Use `blitz-iphone` `device_action` to interact (tap buttons, enter text, navigate)
4. Use `blitz-iphone` `describe_screen` again to verify the result

## App Store Connect Tools

### asc_fill_form

Fill App Store Connect form fields. Auto-navigates to the tab (if auto-nav permission is on).

#### Tabs and fields

**appInformation**
| field | type | required | notes |
|---|---|---|---|
| title | string | yes | App name (max 30 chars) |
| subtitle | string | no | (max 30 chars) |
| description | string | yes | (max 4000 chars) |
| keywords | string | yes | comma-separated, max 100 chars total |
| promotionalText | string | no | (max 170 chars) |
| marketingUrl | string | no | |
| supportUrl | string | yes | |
| whatsNew | string | no | first version must omit |
| privacyPolicyUrl | string | yes | |
| copyright | string | yes | e.g. "2026 Acme Inc" |
| primaryCategory | string | yes | GAMES, UTILITIES, PRODUCTIVITY, SOCIAL_NETWORKING, PHOTO_AND_VIDEO, MUSIC, TRAVEL, SPORTS, HEALTH_AND_FITNESS, EDUCATION, BUSINESS, FINANCE, NEWS, FOOD_AND_DRINK, LIFESTYLE, SHOPPING, ENTERTAINMENT, REFERENCE, MEDICAL, NAVIGATION, WEATHER, DEVELOPER_TOOLS |
| contentRightsDeclaration | string | yes | DOES_NOT_USE_THIRD_PARTY_CONTENT / USES_THIRD_PARTY_CONTENT |

Legacy aliases accepted: `storeListing`, `appDetails`

**monetization**
| field | type | required | values |
|---|---|---|---|
| isFree | string | yes | "true" / "false" |

To set a paid price, use the `asc_set_app_price` tool (not `asc_fill_form`). For in-app purchases and subscriptions, use `asc_create_iap` and `asc_create_subscription` — see dedicated tool docs below.

**review.ageRating**
Boolean fields (value "true"/"false"):
`gambling`, `messagingAndChat`, `unrestrictedWebAccess`, `userGeneratedContent`, `advertising`, `lootBox`, `healthOrWellnessTopics`, `parentalControls`, `ageAssurance`

Three-level string fields (value "NONE"/"INFREQUENT_OR_MILD"/"FREQUENT_OR_INTENSE"):
`alcoholTobaccoOrDrugUseOrReferences`, `contests`, `gamblingSimulated`, `gunsOrOtherWeapons`, `horrorOrFearThemes`, `matureOrSuggestiveThemes`, `medicalOrTreatmentInformation`, `profanityOrCrudeHumor`, `sexualContentGraphicAndNudity`, `sexualContentOrNudity`, `violenceCartoonOrFantasy`, `violenceRealistic`, `violenceRealisticProlongedGraphicOrSadistic`

**review.contact**
| field | type | required |
|---|---|---|
| contactFirstName | string | yes |
| contactLastName | string | yes |
| contactEmail | string | yes |
| contactPhone | string | yes |
| notes | string | no |
| demoAccountRequired | string | no |
| demoAccountName | string | conditional |
| demoAccountPassword | string | conditional |

**settings.bundleId**
| field | type | required |
|---|---|---|
| bundleId | string | yes |

### get_tab_state

Read the structured data state of any Blitz tab. Returns form field values, submission readiness, versions, builds, localizations, etc. **Use this instead of screenshots to read UI state.**

| param | type | required | notes |
|---|---|---|---|
| tab | string | no | Tab to query. Defaults to currently active tab. |

Valid tabs: `ascOverview`, `appInformation`, `screenshots`, `monetization`, `review`, `analytics`, `reviews`, `builds`, `groups`, `betaInfo`, `feedback`

Legacy aliases accepted: `storeListing`, `appDetails`

### asc_open_submit_preview

No arguments. Checks all required fields and either opens the Submit for Review modal or returns missing fields.

### app_store_setup_signing

Set up code signing for App Store distribution (iOS or macOS — auto-detected from project). Idempotent — re-running skips already-completed steps. For macOS, also creates MAC_INSTALLER_DISTRIBUTION certificate for .pkg signing.

| param | type | required | notes |
|---|---|---|---|
| teamId | string | no | Apple Developer Team ID. Saved to project metadata after first use. |

### app_store_build

Build an IPA for App Store submission. Archives the Xcode project and exports a signed IPA.

| param | type | required | notes |
|---|---|---|---|
| scheme | string | no | Xcode scheme (auto-detected if omitted) |
| configuration | string | no | Build configuration (default: "Release") |

### app_store_upload

Upload an IPA to App Store Connect / TestFlight. Optionally polls until build processing completes.

| param | type | required | notes |
|---|---|---|---|
| ipaPath | string | no | Path to IPA (uses latest app_store_build output if omitted) |
| skipPolling | boolean | no | Skip waiting for build processing (default: false) |

### asc_set_app_price

Set the app's price on the App Store.

| param | type | required | notes |
|---|---|---|---|
| price | string | yes | Price in USD (e.g. "0.99", "0" for free) |
| effectiveDate | string | no | ISO date for scheduled price change (e.g. "2026-06-01"). Omit for immediate. |

### asc_create_iap

Create an in-app purchase. Creates the IAP, adds en-US localization, and sets the price.

| param | type | required | notes |
|---|---|---|---|
| productId | string | yes | Unique product identifier (e.g. com.app.coins100) |
| name | string | yes | Internal reference name |
| type | string | yes | CONSUMABLE, NON_CONSUMABLE, or NON_RENEWING_SUBSCRIPTION |
| displayName | string | yes | User-facing display name (en-US) |
| price | string | yes | Price in USD (e.g. "0.99") |
| description | string | no | User-facing description |

### asc_create_subscription

Create an auto-renewable subscription. Creates or reuses a subscription group.

| param | type | required | notes |
|---|---|---|---|
| groupName | string | yes | Subscription group name (created if doesn't exist) |
| productId | string | yes | Unique product identifier |
| name | string | yes | Internal reference name |
| displayName | string | yes | User-facing display name (en-US) |
| duration | string | yes | ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR |
| price | string | yes | Price in USD (e.g. "4.99") |
| description | string | no | User-facing description |

### Recommended full workflow (code + build + submission)

0. Code the app in the pwd, using the current pwd's framework language
1. Check submission readiness: call `get_tab_state` with `tab: "ascOverview"` — check `submissionReadiness.isComplete` and review `submissionReadiness.missingRequired` for any missing fields
2. Fill all required ASC forms until submission readiness is complete:
    - `asc_fill_form` tab `"appInformation"` — title, description, keywords, supportUrl, privacyPolicyUrl, copyright, primaryCategory, contentRightsDeclaration
    - `asc_fill_form` tab `"monetization"` — isFree (use `asc_set_app_price` for paid pricing)
    - `asc_fill_form` tab `"review.ageRating"` — set all applicable content descriptors
    - `asc_fill_form` tab `"review.contact"` — contactFirstName, contactLastName, contactEmail, contactPhone
    - Screenshots: `screenshots_switch_localization` → `screenshots_put_track_slot` / `screenshots_remove_track_slot` / `screenshots_reorder_track` → `screenshots_save` for APP_IPHONE_67/APP_IPAD_PRO_3GEN_129 (iOS) or APP_DESKTOP (macOS)
    - Re-check `get_tab_state` tab `"ascOverview"` to confirm all required fields are filled
3. **Manual step:** Tell the user to set Privacy Nutrition Labels manually in [App Store Connect](https://appstoreconnect.apple.com) — this is not exposed in Apple's REST API
4. `app_store_setup_signing` teamId=YOUR_TEAM_ID (one-time per bundle ID)
5. `app_store_build`
6. `app_store_upload`
7. `asc_open_submit_preview` — fix any flagged missing fields, then submit
