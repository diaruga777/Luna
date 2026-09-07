# Luna — four weblink apps over one shared store (experiment)

Luna is a family of **four standalone iOS apps** (UIKit, deployment target iOS 18;
FoundationModels/new-API code is gated behind `@available(iOS 26, *)`)
that share one App Group, one on-disk store (`saves.sqlite`), and one codebase:

- **Luna** (`com.hsanabria.luna`, Xcode target `Luna`) — the central, PAID app:
  the only app whose every surface (app, share/action/safari extensions, App
  Intents) accepts and processes EVERY content kind. Its home screen is the
  reader-style card deck showing all kinds. Placeholder crescent-moon icon.
- **Luna Reader** (`com.hsanabria.luna.reader`, target `LunaReader`) — articles,
  paywalled articles, documents. Scrolling reader (inline split-web frames) + RSVP speed
  reader (whose opt-in eye-tracking toggle pauses the silent speed read when your gaze
  leaves the focal word — ARKit face tracking, `claudedocs/eye-tracking.md`);
  background-playback read-aloud with autoplay-next and on-device trimming (see
  `claudedocs/audio-playback.md`); send-to-Kindle (emailed through the connected email account,
  `claudedocs/send-to-kindle.md`) and send-to-Xteink (EPUB delivered to a CrossPoint-firmware
  e-reader over a BLE rendezvous, or over local Wi-Fi when reachable, `claudedocs/xteink.md`)
  as SWIFT `ArticleDestination`s — the central Luna app delivers to the same two destinations
  through bundled PLUGINS instead (`kindle.js`/`xteink.js`, see "Plugins" below), never this
  Swift code; share-sheet export of any unlocked article as EPUB / PDF / Markdown / plain text
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

**Luna Writer** (`com.hsanabria.luna.writer`, target `LunaWriter`) is a SIXTH, standalone
app: a Markdown writing surface (iA Writer's Focus, syntax colouring and Authorship),
a Ulysses-style organiser, Pen-style notes with an "@" lookup, and a gaze-plus-voice
read-along built on the Reader's ARKit tracker (now the shared `LunaGaze` module). It
shares no store with the other apps and talks to no server: sheets are plain `.md`
files under Documents, everything else in its own `writer.sqlite`. Its tiers are
`LunaWriter*` in the package plus `LunaGaze`; the organiser never imports the editor,
it declares seams the composition root (`LunaWriter/WriterWiring.swift`) adapts. The
central Luna app links `LunaGaze` ONLY so one dynamic framework serves both it and
`LunaTests` (a product linked by the test bundle alone is folded statically into two
copies and test seams stop reaching the Reader). See `claudedocs/writer.md` and
`claudedocs/plans/writer-app.md`.

**Shared store + surfacing.** Any link saved through ANY app (share sheet, action
extension, App Intents, Safari extension) is classified by the shared
`LunaIngest.IngestPipeline` into a `ContentKind` and written to the one shared
saves database, `saves.sqlite` in the App Group container. Each app shows only its
category: every app's root is a CARD
DECK, and `LunaApp.current` — derived from the bundle-id suffix — decides both what
it shows (`LunaApp.includes`, in `LunaSavesUI`) and what it accepts
(`SurfaceSupport`, the ingest gate). Items of other categories are stored but
surface only in their own app. There is no sectioned table list: it was deleted
once every app rooted on a deck. **The store is SQLite on the system
`libsqlite3`, genuinely relational and never a JSON payload column**: one
`saves` row per save with typed columns, real child tables under `ON DELETE
CASCADE` for the send bookkeeping and the price tracker's stores and price
points, and the on-disk artifacts' ownership as edges (`files`/`file_refs`/
`file_holders`) whose triggers queue a released path in `pending_deletes` for
`PendingDeleteReaper` to unlink. WAL, `busy_timeout`, `foreign_keys = ON`, one
connection per process behind a serial queue; enum columns carry NO CHECK
constraint, because four independently-updated apps share the one file and an
unknown raw value must map to a safe default in Swift rather than fail a write.
See `claudedocs/saves.md`. Feature docs live in `claudedocs/` — keep them current when changing features.

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
gem). Dependency: SwiftSoup. A SECOND local package, `LunaVaultTailscale/`, embeds
Tailscale (tsnet) for Luna Vault's Mac backend: a committed
`Vendor/LibTailscale.xcframework` (rebuilt by `scripts/build_libtailscale.sh`, needs Go),
a vendored TailscaleKit wrapper, and the Vault Mac companion executable. Only the
`LunaVault` app target and `LunaTests` link it — never add it to another target
(`claudedocs/vault-mac.md`). Dev with Xcode 27 beta / iOS 27 simulator; archive/upload with
stable Xcode 26.2.

> **Surface gating.** There is no separate onboarding root. Every app opens straight
> into its card carousel, whose permanent index-zero util card doubles as first-run
> onboarding. While onboarding is unanswered it shows the surface headline (whose
> two-beat sweep belongs to the LAUNCH only — paged back to, it stands finished),
> the card's corona, and the setup block; after both lessons are
> completed or skipped, the next launch replaces those controls with matching
> Safari-history URLs. **The setup block is at most TWO buttons**, offered in
> priority order — Safari, the Action Button shortcut, then the email nudge — and
> stacked UP from the paste row, so an absent one is not a gap. There is NO
> share-sheet save lesson: a device that cannot run the shortcut is offered no
> save button at all and owes nothing on that leg. A COMPLETED button is retired
> the next time the app backgrounds (and at the next launch), which is what frees
> a slot for email; a SKIPPED one keeps its button and outranks email. Email
> waits for three saves or two days with the first, needs
> `LunaApp.sharesByEmail`, and disappears once an account is connected.
> **Above that block, and outside its budget**, the two apps that download media
> carry a chrome-free "Store downloads *in Luna* / *in Photos*" line in BOTH
> states, which stands the recents down while present and retires from the next
> launch once the question is answered anywhere (the card or Settings →
> Downloads, both through `MediaStorageSettings.choose`). **In Luna is the
> shipped default** — a new install keeps downloads in the app and never deletes
> them (`AutoDownloadSettings.autoSaveDownloadsToPhotos` defaults to false, and
> an absent retention setting means `.never`, so `MediaStorageSettings.option`
> resolves to `.deleteAfter(.never)`). The line exists because the OTHER answer,
> Photos, needs a permission nobody has been asked for and would otherwise be
> discovered only when a download silently did not arrive: choosing Photos there
> ASKS first and saves only on a yes — a refusal reverts to Luna, and a second
> attempt opens Luna's own page in Settings, since iOS prompts once. The card names no media symbol: `DownloadStorageChoice.installed`
> (LunaModels) is the seam and `MediaUtilCardStorageChoice.install()` fills it
> from the two media `KindWiring`s.
> Paste remains in both states; the Save of the Week row
> appears whenever a live signed entry exists (`claudedocs/save-of-the-week.md`).
> With saves present the first save, not the util card, is the launch selection.
> **A save from any surface answers the first run**: onboarding stamps its start
> at launch and latches completion once a newer save exists, so `-resetOnboarding`
> / Settings' reset shows the first-run card again until the next save arrives. See `claudedocs/util-card.md` and
> `claudedocs/reader-onboarding.md`. **Notification authorization is NOT requested at
> launch** — a fresh install has nothing to notify about yet. The three features that
> post ask at the moment the user opts in, and nowhere else: pasting the Save of the
> Week key (Diagnostics), connecting a sending account (both the app-password and
> Outlook-OAuth paths), and committing a price alert threshold (either price editor).
> `NotificationManager.requestAuthorization` is idempotent and self-skips in an
> `.appex`, so those call sites need no state of their own. Email is a
> per-app capability, `LunaApp.sharesByEmail` (true for `Luna` and
> `LunaReader` only): those two connect an account, send saves to contacts
> (`claudedocs/social-sharing.md`) and import shares/newsletters from a mailbox
> (`claudedocs/incoming-mail.md`) — each still KEEPING only its own kinds from those
> sources. Downloader and Price Tracker share by plain URL through the system share
> sheet: no account, no Contacts screen, no mail import, no mail-fetch background
> task. An account is connected INLINE in Settings → Email & Sending (whose Sharing
> Account section is the sign-in form until one exists, see
> `claudedocs/email-login.md`), and an attempted send without one redirects there.
> Shortcut install and Safari-extension setup can be entered from the util card and
> replayed from Settings → Shortcut & Safari. **The Safari extension is never version
> gated** — `nativeMessaging` (and so the page pills, the unlocking, and the recent-URL
> history the util card offers) needs no particular iOS. The ONE capability gate is the
> Action Button shortcut, which needs iOS 27 **and** hardware with an Action Button:
> `ShortcutSettingsScreen.deviceHasShortcutSetup` asks the same
> `OnboardingSaveSetupMode` the onboarding save lesson asks, so Settings (which hides
> the shortcut, On-Screen URLs and Double Save sections and renames itself "Safari")
> and the util card can never disagree about which save route this device is taught.
> Per-app content
> kinds, the drop behavior, and the composition mechanism are documented in
> `claudedocs/surface-support.md`. UI prose says
> "Luna"; each app has its own `AppIcon{Luna,Reader,Downloader,PriceTracker}` (PNG appiconsets in
> `SharedIconAssets.xcassets` — there is no icon generator script; update the PNGs directly).
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

> **iPad: one answer to "is there more room here", and it is a WIDTH.** Every app ships
> to iPhone and iPad from these same sources (`TARGETED_DEVICE_FAMILY = "1,2"`; iPhone is
> portrait-only, iPad takes all four orientations), so `LunaLayout` (LunaDesignSystem) is
> the single place that decides — as pure geometry over a container width, **never
> `UIUserInterfaceIdiom` or a size class**. An iPad in half-screen Split View and an
> iPhone are the same layout problem; a 13" iPad in landscape is a different one from the
> same device in portrait. The threshold is 700pt: above every iPhone (widest 440), below
> every iPad in portrait (narrowest 744). Three consequences worth knowing before touching
> layout: **(1)** a carousel card aspect-fits its complete usable card area, so tall iPads
> use their spare height rather than holding a phone-sized card in whitespace. A second
> reader column is offered only when two full-size cards fit with the normal outer padding
> (typically landscape; `claudedocs/card-carousel.md`). **(2)** On a wide screen that has
> room for it, a nested reader is a second CARD beside the first, not a tab over it, installed as a CHILD
> rather than a modal — a presentation container swallows every touch outside the presented
> frame, which is exactly the touches the card next door needs (`claudedocs/readers.md`).
> **(3)** Everything else that was a full-width band keeps a readable column instead
> (`LunaLayout.readableWidth`); the decks' own chrome follows the CARD's column rather than
> the screen edges.

> **One card frame, and it is a function of the SCREEN.** Every carousel card — article,
> media, product, failed save, util, onboarding — is the same rectangle: the largest exact
> 9:16 that fits the card area, centered (`CardCarouselMetrics.resolve`, one fit). A card's
> size used to be its KIND's answer (`CardFit`/`topOverflow`: a reader card took every point
> of width and hung its extra height above the card area; a product card filled the room),
> so paging between kinds resized and re-centered the card mid-transition; `edgeGap` was
> per-deck too, so the same video card was 40pt narrower in the Downloader. `peek`/`edgeGap`/
> `sideScale`/`verticalPadding` are constants now, and the 48pt top clearance is reserved by
> EVERY deck (`CardCarouselHostViewController.carouselTopClearance` = `CardDeckGeometry
> .topClearance`) rather than by the Reader alone. The point of all that:
> **`CardDeckGeometry.cardFrame(inScreenSize:safeAreaInsets:)` is pure arithmetic**, so the
> launch splash can be drawn at the deck's exact card before any deck exists — which is what
> `LunaLaunchScreen.storyboard` reproduces in Interface Builder constants (its one
> conditional, the iPad width cap, rides a regular-width variation because a launch
> storyboard has no step function). `CardDeckGeometryTests` and `LaunchScreenGeometryTests`
> pin the deck, the pure function and the storyboard to each other at six screen shapes;
> nothing else can. Corona rasterisation is per-purpose — `EclipseCorona.transitionScale`
> (1×) for a corona composited at its render size, `artworkScale` (3×) for the launch art,
> which is why the splash corona is no longer 3×3 blocks. See
> `claudedocs/card-carousel.md` and `claudedocs/reader-onboarding.md`.

> **Strings: one flat file, keyed by a descriptive name with a per-app
> suffix.** Every user-visible string in all four apps is an entry in
> `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`,
> written `"<descriptive base>_<suffix>" = "what Luna shows";`, where
> `<suffix>` is one of `Luna` (the universal fallback every base key MUST
> define), `Core` (the central Luna app's own override), `Reader`,
> `Downloader`, `PriceTracker`. A call site never names an app — it just calls
> `L10n.string("SomeDescriptiveKey")`, and `L10n`
> (`LunaModels/Localization.swift`) resolves `SomeDescriptiveKey_<the running
> app's own suffix>` first, then falls back to `SomeDescriptiveKey_Luna`. So a
> string every app shows the same needs only a `_Luna` line, and giving one
> app its own wording is one more line in the strings file — **never** a
> `switch LunaApp.current { … }` around an `L10n` call; that switch IS this
> resolution, done worse and invisibly to the strings file (`WeeklySaveLabels`
> and `OnboardingStrings.Definition`/`ChunkedDefinition` are the two worked
> examples of collapsing one into the suffix mechanism). `L10n.string(key,
> args...)` substitutes `%@`/`%lld`/etc via `String(format:)` — a key must
> NEVER itself be interpolated. `L10n.string(key, for: app)` / `L10n
> .stringIfPresent(key, for:)` resolve for an explicit app rather than
> `.current` (showing a sibling app's name, or reading a `ChunkedDefinition`'s
> `"<prefix>1"`, `"<prefix>2"`, … until one is missing). Grouping and the
> comment above each group in the strings file are HAND-AUTHORED — keys are
> named so alphabetical order matches on-screen reading order (zero-padded
> ordinals past 9 items, e.g. `_feature01`) — `scripts/strings_sync.py --write`
> only appends a placeholder for a referenced key missing its `_Luna` entry
> and drops lines nothing references; it never re-sorts or re-groups.
> `L10n.string` / `L10n.resource` are the only lookup points, resolving
> against `Bundle.module`, which ships in every app, extension, clip and
> widget that links LunaModels. **`defaultLocalization: "en"` in
> `Package.swift` is load-bearing**: without it the table is silently dropped
> from the resource bundle and every lookup falls back to a raw key.
> `LocalizableStringsTests` therefore reads the table out of the BUILT bundle,
> not the working tree, and checks every entry's suffix is recognized, every
> base key has a `_Luna` fallback, and format specifiers match ACROSS a base
> key's suffix siblings (not key-vs-value — the key no longer carries
> specifiers). NOT copy and deliberately unwrapped:
> `OnboardingStrings.Accessibility` (UI-test identifiers) and `.AnimationKeys`
> (CALayer keys), markup assembly, and matcher hostnames.
> **App Intents metadata is in the SAME file but gets there differently, and
> does NOT use the suffix fallback**: intent titles, descriptions,
> `@Parameter`/`@Property` names, and `AppEnum.caseDisplayRepresentations`
> must stay Swift literals (the metadata processor rejects anything else,
> including an `L10n` call) — so the literal IS the concrete, already-suffixed
> key (always ending `_Luna`), e.g. `static let title: LocalizedStringResource
> = "Intents_save_title_Luna"`. `strings_sync.py` finds these by shape in
> `Luna/Mail/Intents/` + the Live Activity widget (excluding a per-instance
> `DisplayRepresentation(title: "\(dynamic)")` VALUE, which is runtime content
> rather than build-time metadata), and the app/widget targets COPY the one
> file into their own bundles via `scripts/add_strings_to_app_bundles.rb`
> (re-run after adding a target; a test fails if a host's copy is missing or
> has drifted). **A built app therefore carries ~8 copies of the one file, each
> made by an independently-tracked copy task, and a stale one is invisible from
> inside the app** — it reads as "my copy edit didn't take", which invites
> re-editing copy that was already right. Measured on Xcode 26.2: put an older
> table into `<App>.app/LunaLibraries_LunaModels.bundle/en.lproj/…` and build
> again and the embed copy is NOT re-run — `BUILD SUCCEEDED`, stale app. An
> INTERRUPTED build gets there for real (the top-level resource bundle is
> updated early; every copy nested inside the `.app` is left a version behind),
> as does a products directory holding an app the current scheme didn't
> rebuild. So every app target ends with a **`Verify bundled strings table`**
> phase (`scripts/check_bundled_strings.py`, installed by
> `scripts/add_strings_check_phase.rb` — re-run after adding an app): every
> `Localizable.strings` under the `.app` must parse to the SAME table as the
> source, and a copy that doesn't is REWRITTEN IN PLACE (redoing whichever copy
> task produced it — a verbatim copy or a `plutil -convert binary1`, detected
> from the file's own bytes) rather than merely reported, so the build ships
> the real table instead of just detecting that it wouldn't have;
> always-out-of-date, ~0.1s. The one case it can't fix by rewriting bytes is a
> bundle root with no `en.lproj` copy of its own at all — that still fails the
> build, since nothing would re-create the file on a later build either. The
> phase guarantees a build that ran to the END, so `install_all_luna_apps.sh`
> runs the same check-and-repair before each install — an interrupted build
> never reaches its last phase, and that half-updated products dir is what a
> hand-run `simctl install` grabs.
> `LocalizableStringsTests` is NOT this guarantee: inside the test host it can
> only compare two copies made from the same input, and two stale copies agree
> perfectly. Staying in code: `AppShortcut` phrases/`shortTitle`s (they are
> `AppShortcuts.strings`, and are Siri grammar) and `BundledShortcut
> .displayName` (must equal the bundled `.shortcut` filename). **There is no
> `InfoPlist.xcstrings`** — the three that existed were shared by four targets
> each and every build rewrote `CFBundleDisplayName`/`CFBundleName` with
> whichever target built last, dirtying the tree on every `AllLunaApps` build;
> the usage descriptions they held are in the `Info.plist`s verbatim and the
> names come from the xcconfig per target. If a second language ever ships,
> add per-TARGET catalogs, never one shared file. Full detail in
> `claudedocs/strings.md`.

## Agent workflow

- Always commit completed work in small, logical chunks as you go — don't wait for
  explicit permission each time, and don't batch everything into one commit at the
  end of a task. Do not bundle unrelated changes into the same commit.
- Unless told otherwise, do all work in your own worktree taken off `main`, not in
  a shared checkout. Commit as you go (per the rule above), then merge the
  worktree's branch into `main` and delete both the worktree and the branch once
  the task is done — handle any merge conflicts yourself rather than leaving them
  for later. If the user asks for follow-up work afterward, repeat the same
  cycle (new worktree off the now-updated `main`, commit, merge, delete) rather
  than reusing a stale one. Never end a task with finished work still sitting
  unmerged in a worktree — that includes a worktree from an earlier task in the
  same session.

## Module structure

Almost all code lives in the local SwiftPM package `LunaLibraries/` (layered: config/models
→ URL/HTML parsing → fetch/bypass/ingest → services → UIKit feature libs →
orchestration/intents; `LunaAppConfig` at the bottom is the App-Group id source of
truth). The Xcode targets are thin shells: the `Luna/` folder holds the shared app shell
(AppDelegate/SceneDelegate), per-app Settings, the main-screen composition
(the ONE card deck — `Luna/CardCarouselHost/CardCarouselHostViewController.swift`
— plus each kind's `CardDeckProviding` half; see `claudedocs/card-carousel.md`),
composition wiring (AppReaderProviders), the App Intent **definitions** (`Luna/Mail/Intents/*` —
business logic is in the `LunaIntents` library) — and is shared by ALL
FOUR app targets (each picks its surface from its bundle id; per-app kind wiring
comes from the one `KindWiring+*.swift` variant each target compiles). `KindWiring` is
also each app's static composition API: AppDelegate/SceneDelegate call
`KindWiring.makeRootViewController()/mainNavigationController(of:)/settingsCategories()`
plus fixed lifecycle points (`appDidLaunch/appDidEnterBackground/sceneDidForeground/
savesDidChange/wifiBecameAvailable/retryPendingArticleSends/
resumeUnfinishedMediaDownloads/attachBackgroundURLSessionHandler/priceRefreshRunner`), so
the universal shell never names a foreign kind's symbols. The Action Button intents' media handoff goes through
`ActionButtonIntentSupport.mediaHandoff` (installed by `MediaIntentHandoff`), and URL
Rescue's kind legs via
`URLRescueWiring.mediaRescueStarter`/`rescueProductInfo`. Kind-specific shell files
(article: the article deck provider, mini-player, audio wiring, reader/email settings;
media: the media deck provider, auto-download settings, intent handoff, the bulk
import's download watcher) are excluded from foreign targets via the same
membership-exception mechanism. The Share/Action extensions
link `LunaShareSurface` (+ transitive) plus their host's kind modules. **The four
`LunaSafari` appexes used to link NOTHING; they now link the Foundation-only floor**
— `LunaAppConfig`, `LunaModels`, `LunaURLClassification`, `LunaMediaResolve`,
`LunaStorage` — so the Safari extension runs the SAME `SocialMediaResolver` the app and
the share/action extensions do rather than a Safari-local fork (it resolves a social
post's video for the in-page player; see `claudedocs/safari-extension.md`'s "Where the
work runs"). `LunaMediaResolve` exists for exactly that: post URL → direct CDN asset is
Foundation + URLSession, while the rest of `LunaMediaDownload` pulls UIKit/Photos/
ActivityKit/SwiftSoup that no appex can afford; `LunaMediaDownload` `@_exported import`s
it, so nothing else changed. The App-Group key format and product-matching hand-copies
that used to live in `LunaSafari/Shared*.swift` are gone — `LunaSafari/SharedProductMatching.swift`
now just reduces a "Was $X on <date>" answer over the real `LunaPriceCompare.ProductPageMatching`
the app links too. **The central `LunaSafari` target ALONE also links `LunaPluginKit` and
`LunaBundledPlugins`** on top of that shared floor — the other three Safari appexes do not,
even though all four compile the same `SafariWebExtensionHandler`/`content.js` source. See
"Plugins" below. `AppConfig.appGroupID` reads the App Group id from the extension's own
Info.plist, the same `LunaAppGroupID` key every other target reads (`Bundle.main` always
resolves to the calling process's own bundle). **Wiring is protocol contracts,
never stored closures** (owner standard, 2026-08): a stored closure property or a
closure parameter stored from `init` is not an acceptable seam. Cross-tier launch
seams are named protocol witnesses installed in AppDelegate, a ShellWiring leg, or
a kind pack (`*Providing` / `*Presenting` / `*Handling` / `*Making`; strong
references — e.g. `AudioPlaybackCenter.dataSource`,
`SavesIngestor.unsupportedSavePresenter`, `DiagnosticLog.exportIdentityProvider`,
`ProductPriceRescue.resolver`). Component boundaries inside the UI use `*Delegate`
/ `*DataSource` protocols with weak references (e.g. `RabbitHoleLayerDelegate`,
`ReaderCompletionDelegate`, `CarouselScrubberViewDelegate`). Closures remain ONLY
as call arguments: one-shot completions, async continuations, per-operation
callbacks stored for one in-flight task, and pure-value parameters (clocks,
comparators, formatters). Single-method protocols are fine; do not merge unrelated
seams to reduce protocol count. The package is pinned to Swift
5 language mode. Reusable modules need `public` API + explicit `public init`s.

**Comments follow ASD-STE100 and exist only where code cannot speak** (owner
standard, 2026-08): a comment states what the code does and how it interacts with
other code — active voice, short sentences, one idea each. Never describe what
the code isn't, a deleted feature, or an old design; never restate a spec or
narrate the next line. Keep: constraints the code cannot show, why esoteric code
exists, cross-artifact/parity contracts naming their pinning test or mirrored
artifact. **Prefer a compiler-enforced invariant to a comment**: when a processor
establishes a property its consumers must trust across a boundary, wrap the
result in a type only the processor can construct (worked examples:
`OwnedFilePath`, `UTCDay`, `CapturedPage`) instead of writing prose. Do not mint
NonEmptyString-grade wrappers for local trivia.

**Per-app SwiftPM link groups.** Every app links the universal set — Models / Storage /
DesignSystem / Transitions / Fetch / Ingest / URLClassification / HTMLClassification /
PriceMetadata / MailAccount / MailTransport / Social / SocialUI / Saves /
SavesUI / Intents / URLRescue / ShareSurface / SwiftSoup — plus its own kind group(s):

| App target | Kind group(s) linked on top of the universal set |
| --- | --- |
| `Luna` (central) | article + media + product (everything), plus the plugin tier: LunaPluginKit, LunaPluginRuntime, LunaPluginIngest, LunaPluginExport, LunaPluginTransport, LunaPluginUI, LunaBundledPlugins |
| `LunaReader` | LunaArticleIngest, LunaReaderUI, LunaArchiveReader, LunaPaywallBypass, LunaAudioPlayback, LunaReaderEngine, LunaEpub, LunaDocuments, LunaSend |
| `LunaDownloader` | LunaMediaDownload (re-exports LunaMediaResolve), LunaPlatforms |
| `LunaPriceTracker` | LunaPriceIngest, LunaPriceUI, LunaPriceCompare |

The plugin tier links only into `Luna`, plus `LunaShare`/`LunaAction` (the
central app's own share/action extensions — `LunaPluginKit`/`Runtime`/`Ingest`
only, no export/transport/UI) and the central `LunaSafari` (`LunaPluginKit`/
`LunaBundledPlugins` only, no JS runtime — see "Plugins" below). The three
sibling apps and every one of THEIR extensions link none of it.

**`LunaPriceCompare` is the one kind module that also goes into the SAFARI
appexes** (`claudedocs/price-comparison.md`): the alternative-seller fan-out —
bundled seller directory, local candidate ranking, regex-only page parser, match
verification — runs at save time in the app and the share/action extensions AND
inside all four Safari extensions. **It also owns the product-snapshot store**
(`ProductSnapshot` / `ProductSnapshotStore`), for exactly that reachability
reason: a product observation is written by the app, the share/action extensions
AND the Safari appexes, so it lives in the one kind module all of them link
rather than in a hand-copy per process (`claudedocs/price-tracking.md`). It
therefore depends on LunaModels / LunaURLClassification / LunaPriceMetadata /
LunaAppConfig (the App Group container, bottom-most and dependency-free) and
**nothing else**, all Foundation-only, the same ~80MB-ceiling trade
`LunaMediaResolve` makes. Every
network call and the optional rich page resolution are INJECTED closures, so the
app can route them through the shared ingest pipeline while the appex uses
URLSession plus the lean parser. Its link edges are added by
`scripts/add_price_compare_links.rb`. Do not give it a heavier dependency: if a
helper you want lives in LunaHTMLClassification or LunaFetch, re-implement the
small piece locally with a parity test (`LeanProductURLParityTests`,
`ComparisonMatchingParityTests` are the two worked examples).

`LunaTests` keeps everything (it hosts on the central app). No foreign-kind
transitive edges remain: `SocialMediaResolving` lives with `MediaAsset` in
LunaModels and the rescue engine takes an injected resolver
(`URLRescueWiring.mediaResolverFactory`, installed by media KindWirings; the
`NoMediaResolver` default keeps media rescues unrescuable elsewhere); the
intent post-search machinery (`SocialPostFinder`/`Bluesky|RedditSearchClient`)
moved into LunaIntents (URL search is kind-neutral), while `DuckDuckGoSearch`
itself sits one tier lower in **LunaFetch** — only the four APPS link
LunaIntents, and the share/action extensions run the same save-time seller
fan-out that uses it as its Layer-2 leg; `BlueskyLink` moved to
LunaURLClassification. Correctness never
depended on the link graph — it comes from the `SurfaceSupport` ingest gate
plus `LunaApp.includes` — but the graph now matches it.

## Plugins (central Luna only)

Central Luna alone runs a JavaScriptCore plugin platform that extends two
ingest-pipeline steps — **ingest** (URL → Model) and **export** (save →
delivered file) — plus one Bluetooth/Wi-Fi reader integration. Reader,
Downloader and Price Tracker link none of it and run no plugin code. Full
reference: `claudedocs/plugins.md`; the authoring side (for a plugin author,
not for editing this codebase) is `docs/plugins/`.

**Composition rule.** `PluginPlatformComposition.install()` (LunaPluginIngest)
is the single root call for the runtime/ingest half of the platform, made
`@MainActor` from EXACTLY three roots — `KindWiring+Luna.swift`,
`ShareEntry+Luna.swift`, `ActionEntry+Luna.swift` — after their kind packs
have installed the article/media/product adopters `PluginModelAdopters`
needs. `PluginExportComposition.install()` and `PluginTransportComposition
.install()` are called only from `KindWiring+Luna` — export and transport
never run in the extensions. Bridge factories are handed IN rather than
reached for (`additionalBridges:`), because `LunaPluginIngest` sits below
`LunaPluginUI`/`Export`/`Transport`/`LunaBundledPlugins` in the link graph.
`KindCompositionRootTests` fails the build if any other root writes
`PluginPlatformServices`/`IngestPipeline.pluginStage` directly, or if the
three required roots don't call `install`.

**Per-target variant files.** The Safari native handler dispatches every
`plugins.*` message through one seam, `SafariPluginMessaging`, and exactly
one of `LunaSafari/SafariPluginMessages+Luna.swift` (real, `LunaPluginKit`-
backed) or `+None.swift` (`handler = nil`) is a `project.pbxproj` membership
exception per Safari target — central `LunaSafari` keeps `+Luna`, the other
three keep `+None`. **Never gate this on `#if canImport(LunaPluginKit)`** —
that check is not target-reliable here, the same warning `KindWiring+*`
variants already carry. Three more files are membership-exception-excluded
from the three sibling app targets so only central `Luna` compiles them:
`Luna/Settings/PluginsSettingsCategory.swift`, `Luna/Stage/StageCatalog+Plugins.swift`
(reads `LunaApp.current`-agnostic — its own header comment describing a
runtime gate is stale now that the exception exists; trust the pbxproj), and
`Luna/Settings/XteinkSettingsScreen.swift` (excluded from `Luna` itself —
that Swift settings screen is dead code there now; the plugin owns Xteink
settings in central Luna). `XteinkSyncProtocol` (LunaSend) stays linked by
both apps — it is the wire protocol `xteink.js` and Luna Reader's Swift path
both implement, pinned to agree by `XteinkPluginTests`.

**Bundled plugins.** Nine ship in `LunaLibraries/Sources/LunaBundledPlugins/Plugins/`
(seven media resolvers plus `kindle.js`/`xteink.js`, the two destinations
that replace `KindleDestination`/`XteinkDestination` under their OLD ids via
`PluginDestinationLegacyIDs`, so `send_states` bookkeeping carries over).
That resource folder is named `Plugins`, **never `Resources`** — a directory
literally called `Resources` at a bundle's root makes `codesign` read the
bundle as a framework layout and refuse it.

**`luna.html` has two backings, one specification.** SwiftSoup (JSC, in the
app/extensions) and the Safari content script's `DOMParser`
(`LunaSafari/Resources/plugin_host.js`) both implement the exact same small
DOM subset, specified once as `LunaTests/Fixtures/Plugins/html-subset.spec.js`
(60 cases) and run against BOTH backings plus a third, `linkedom`, in the
node dev harness (`tools/plugin-sim/`). A disagreement is narrowed in the
subset or fixed in a backing — never special-cased per backing.

**Settings keys are bare, and `_` is reserved.** `luna.settings`/`luna.storage`
values live in `plugin_kv` under the field's OWN key — never a `settings.`
prefix — because both real writers (`luna.settings.set` and the Settings
detail screen) write that way; `PluginKVStore.isConfigured` reads the same
bare key to match. A manifest cannot declare a key starting with `_`, but
`luna.settings.set` accepts one anyway: `_status` is how a destination
plugin drives its own share-row dot.

**`tools/plugin-sim/`** is a Node harness (no Xcode, no simulator) a plugin
author or an implementation agent runs against real or fixture-recorded
`luna.fetch` responses in under a second — `node tools/plugin-sim/run.mjs
<plugin.js> <url> [--fixture dir]`. It is a convenience tool, never a build
gate; `LunaTests` is the one suite that matters.

**Transcription (central Luna only).** An `article` Model may carry a
`transcription` spec (an audio or video file) instead of `html`; the save
parks `.pending` with a `transcriptions` row (schema 14) and
`TranscriptionJobRunner` (new `LunaTranscribe` target, linked by `Luna` and
`LunaTests` only) downloads it, transcribes it on device with `SpeechAnalyzer`
(iOS 26), persists an ordinary article through `IngestorKindHandlers.article`,
and deletes the recording. `IngestInput.intent == .transcribe` makes the
seven media plugins decline so the seven `<platform>-transcript.js` plugins
(priority 90, below their twins) claim; an intent no plugin serves fails
with `.noTranscriptSource`, never a download. **`SavesIngestor.ingest` and
`ingestAllPending` skip any save with a job row** — a re-walk would queue a
second job or lose the intent to a media plugin. `Luna/TranscriptionShellWiring.swift`
is excluded from the three sibling apps by membership exception. See
`claudedocs/transcription.md`.

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
> is the four bundled shortcuts (`Luna/Resources/Luna.shortcut`, `Luna Reader
> .shortcut`, `Luna Downloader.shortcut`, `Luna Price Tracker.shortcut` — one per
> app, the other three excluded from each app target by membership exception),
> whose filename IS the user-visible name in the Action Button picker
> (`BundledShortcut.displayName` switches on `LunaApp.current` and must keep
> matching it).

```sh
scripts/run_tests.sh            # preferred — picks a simulator, reports the real verdict
scripts/run_tests.sh --fresh    # throwaway simulator (the fix for most flake modes)
scripts/run_tests.sh --changed  # INNER LOOP ONLY — just the tests the diff reaches
```

> **`--changed` is for iterating, never for declaring a task done.** It asks
> `scripts/select_changed_tests.py` which classes a `git diff <base>` (default
> `HEAD`, so uncommitted work counts) can reach — by name convention
> (`Foo.swift` → `FooTests`), by grepping LunaTests for every type the changed
> file declares, and by a small path table for the non-Swift inputs (the strings
> file → `LocalizableStringsTests`, the launch storyboard → the two geometry
> suites, `.xcodeproj`/`Package.swift`/xcconfigs → everything). It always adds
> `KindCompositionRootTests`. It prints what it picked and why, and when a
> changed file matches no rule it says so and runs the WHOLE suite rather than
> quietly running less — so a short selection is a claim it is prepared to
> justify. A green partial run is not a green suite: finish with a full
> `scripts/run_tests.sh --fresh`.

> **The test value bar: a test must assert BEHAVIOR.** Three sweeps (Aug 2026)
> deleted every test that only re-states production source — constant echoes
> (a literal copy of a prod constant/table/string/format), synthesized-Codable
> roundtrips, stub tautologies, duplicates of a stronger sibling, and
> source-text greps of same-build Swift whose string is not the call site.
> Don't write new ones; the plan docs with the worked examples are
> `claudedocs/audit/test-value-sweep-2026-08.md` and `tree-shake-2026-08.md`
> (whose "Deferred" list is the standing backlog of type-level refactors).
> The EXEMPT pins are cross-ARTIFACT consistency checks and stay: `*Parity*`
> suites, `KindCompositionRootTests`, `LocalizableStringsTests`, the two
> geometry suites, `StageRegistryTests`, `WaveKernelSourceTests`, and
> source-text pins against the unlinked `LunaSafari/` hand-copies. A production seam
> (`…ForTesting`, settable static, injected closure) may exist ONLY while a
> behavior-asserting test uses it — a seam whose tests die dies with them.
> **The package declares NO test targets**: `LunaLibraries/Tests/` was deleted
> 2026-08-09 (its suites never ran; the ONE suite is the `LunaTests` bundle
> hosted on the central app). Never re-add a `.testTarget` — that also means
> a fresh worktree builds with no `mkdir` workaround.

> **Looking at a screen, rather than testing it: `-LunaStage`.** Any app boots
> straight into any named screen in any named state — populated, empty, frozen
> mid-load, errored — with stubbed data and nothing to set up, so reviewing or
> driving a screen costs one `simctl launch` instead of a navigation script.
> DEBUG-only (the catalogs call the DEBUG fixture seams, so a release build
> cannot compile them). `xcrun simctl launch --console-pty <sim>
> com.hsanabria.luna -LunaStageList` prints the whole catalog as JSON; the same
> JSON is committed at `Luna/Stage/StageManifest.json` and pinned by
> `StageRegistryTests`. `scripts/stage_screenshots.py` captures every stage of
> every app and writes a review guide. Stages follow the kind-pack rule — a
> kind's stages live in `Stage/StageCatalog+<Kind>.swift`, compiled only into
> the targets that link the kind. Full detail, including what is out of scope
> (extensions, clips, the Live Activity — none launchable by argument), in
> `claudedocs/staging.md`.

Or by hand:

```sh
DD=<a derivedDataPath>
SIM=<a booted iOS 26.x simulator UDID>   # e.g. xcrun simctl list devices | grep -A8 'iOS 26'
xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM" \
  -configuration Debug -derivedDataPath "$DD" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO
```

> **`** TEST FAILED **` with zero test failures means the DIAGNOSTICS step, not
> the tests.** After the suite passes, xcodebuild may try to collect diagnostics
> from the simulator, time out after a fixed 600s, and fail the run on that alone
> — turning a ~105s suite into a ~12min one that reports exit 65. The log also
> goes silent for those ten minutes, which reads exactly like the hung-runner mode
> below and invites killing a healthy run. **Use `scripts/run_tests.sh`** — it
> waits for the ROOT suite to close (every individual suite prints its own
> `Executed N tests …` line, so those mean nothing), gives xcodebuild a grace
> period, then stops it and exits on what the TESTS reported: 0 clean, 1 real
> failures, 2 no summary at all. The scheme's
> `systemAttachmentLifetime`/`userAttachmentLifetime = "keepNever"` is kept but
> measured NOT sufficient on its own — xcodebuild was still busy 45s after a clean
> run — so the script, not the setting, is the fix. **Always read the `Executed N
> tests, with M failures` line; that, not the `** TEST` banner, is the result.**

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
  flagged target's sources at all (`LunaSaves`→`SwiftSoup`,
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
- **The executed-test COUNT varies between runs on different simulators — diff the
  failure list, not the total.** The same tree measured 2252/21/0 and, on a
  `simctl create`d sim later the same day, 2173/7/0: `ArticleAudioEngineTests` (14)
  did not register at all rather than skipping, and some 60 others likewise. No
  test files had been deleted (`git diff --diff-filter=D main..HEAD -- LunaTests/`
  is the check). **0 failures is the signal; the total is not.**
- **Current suite state on the iOS 26.x sim: 2992 tests, 20 skipped, 0 failures**
  (measured 2026-08-11 on a FRESH simulator and a fresh `-derivedDataPath`, with NO
  other simulator booted — see the load caveat below — after the Safari-setup-popup
  merge: the in-app Safari instructions became the shared popup + hosted setup pages,
  and the popup/loop suite plus main's Live-Activity wave landed together. The prior
  same-day measurement was 2951/20/0 after the onboarding/Safari/price wave — nine
  merged branches added ~550 tests over the 2379 the wave started from). That growth tipped one pre-existing race into a failure:
  `OnboardingHandoffFullContentTests` asserted the onboarding→deck handoff after a
  fixed 50ms pump, but the completion hops through `Task { @MainActor }` and lands
  ~360ms later under a saturated main thread. **A fixed-duration pump is not a wait** —
  poll the condition. **Load caveat, measured the same day: with three other
  simulators booted (parallel agents), the SAME tree reported 12 failures — all in
  WKWebView-driving suites (`SafariMediaPillTests`, `SafariIndexVetoParityTests`,
  `URLRescueCoordinatorTests`), every one a 10s `Asynchronous wait failed`, with 70
  `Failed to acquire RBS assertion` lines in the log.** That is WebContent being
  jetsammed for memory, not a regression; a parity suite in that state reports
  "Safari and Swift disagree" because the page never loaded at all. `simctl shutdown`
  the strays and re-run before reading anything into such a list. The older
  measurement, for contrast: 2253/21/0 on 2026-08-05
  after the card-presenter refactor and the test-suite trim,
  on a FRESH simulator, with **no `-skip-testing:` flags** — the plain recipe above
  is the whole of it). 91s of test execution, ~128s wall on a warm
  `-derivedDataPath`. The suite was 2453/9/0 at 261s before the trim; roughly 220
  method fixtures were folded into table-driven rows or merged area files, the
  Safari/JS suites went from ~159 WebContent spin-ups to 1, and ~5.4s of fixed
  sleeps became injected seams. Re-measured 2026-08-06 after the one-card-frame
  change, plain recipe on a warm existing sim: **2279/21/0** — 0 failures, and the
  ~20 extra registered tests over the fresh-sim run are the registration variance
  the bullet below describes rather than new coverage. Re-measured 2026-08-07
  after a second timing pass, `--fresh` on a warm `-derivedDataPath`:
  **2341/21/0 in 78s**, down from 140s for the SAME 2341 tests. Six suites were
  waiting out a production constant rather than the behaviour it guards, and each
  got a seam instead: a `now:` closure on `RSVPGazeCoordinator` (exposed as
  `RSVPViewController.gazeClockOverride`), `ShareReaderViewController
  .imagePreparationTimeout` and `WebArchiveCapturer.settleFirstTurn`/
  `.settlePollInterval` as writable statics, an `interval:` on
  `ArticleLoadingStatusCycler`, `BypassTests` moved onto the shared
  `SafariJSTestHarness` web view, and the setup-celebration test intercepting its
  `setTimeout` instead of sleeping through it. Nothing in the apps writes any of
  those; they exist so a test can afford the assertion it already makes.
- **The 21 skips are all intentional `XCTSkip`s, and all of them are env-gated
  tooling or on-demand coverage** — nothing is skipped because it is broken:
  `ArticleAudioEngineTests` (14, `RUN_AUDIO_ENGINE_TESTS=1`), the four
  `EclipsePreviewRecorderTests` corona/starfield/flare recorders
  (`RECORD_ECLIPSE_PREVIEWS=1` + `ECLIPSE_PREVIEW_DIR`), two
  `SocialMediaResolverTests` live-YouTube transfers
  (`RUN_LIVE_YOUTUBE{,_BACKGROUND}_TESTS=1`), and
  `ReaderLaunchArtRecorderTests.testRecordReaderLaunchArtworkWhenRequested`.
- **`ArticleAudioEngineTests` is gated rather than excluded on the command line.**
  It starts a real `AVAudioEngine` even in manual/offline rendering mode, and on at
  least one Mac it reproducibly aborts every test with a mediaserverd "RPC timeout,
  apparently deadlocked" — reproduced across a simulator reboot and a sandbox
  toggle, so not a code regression. Rather than everyone remembering a
  `-skip-testing:` flag, the class now `XCTSkipUnless`es on
  `RUN_AUDIO_ENGINE_TESTS=1` in `setUp`. Run `RUN_AUDIO_ENGINE_TESTS=1 xcodebuild
  test -only-testing:LunaTests/ArticleAudioEngineTests …` to exercise it, ideally
  alone or on another Mac. (`SpeechRendererSpikeTests`, which used to hang the whole
  run in the same family, was a Phase-1 spike and is deleted; its finding lives in a
  doc comment.)
- **A run that dies with "Test crashed with signal kill before establishing
  connection" — or hangs with "the test runner hung before establishing
  connection" — is the simulator, not the code**: create a FRESH simulator with
  `simctl create` and re-run. A reboot is not enough, and neither is `pkill
  dtpasteboardd`; the long-lived sim has produced the hang twice after both. Same for a run where WKWebView-backed suites mass-fail at
  ~10s each, and for a wedged pasteboard daemon deadlocking `UIPasteControl` at
  launch (`pkill dtpasteboardd`).
- **Snapshots**: 10 reference PNGs remain, all of views rather than decks
  (`LockedCardOverlayViewTests`, `UnsupportedSaveCardTests`, `ReaderScreenTests`,
  `AudioMiniPlayerTests`); 28 orphans with no test reading them were deleted. The
  long-standing `AudioMiniPlayerTests` drifts are gone: the set was re-recorded for
  the predawn palette and the harness now pins the same appearance the app does
  (dark style + `lunaSky = .predawn`, over `LunaColors.background`) instead of
  forcing a light style. References are device-specific — re-record after
  intentional UI changes with `TEST_RUNNER_RECORD_SNAPSHOTS=1 xcodebuild test …`
  (the build-setting form does NOT reach the runner's environment), and if they fail
  on a *different* device re-record there rather than treating it as a regression.
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
