# Per-app content kinds (SurfaceSupport)

Luna is four apps over one shared store. The central **Luna** app (bare bundle id
`com.hsanabria.luna`, a paid app) handles EVERY content kind; each single-content
app handles exactly one:

| App | Bundle id | Handles |
| --- | --- | --- |
| Luna (central, paid) | `<prefix>` | everything |
| Luna Reader | `<prefix>.reader` | articles, paywalled articles, documents |
| Luna Downloader | `<prefix>.downloader` | social / video media |
| Luna Price Tracker | `<prefix>.pricetracker` | product price trackers |

Every app runs the SAME classification pipeline (`LunaIngest`: unwrap → classify,
including the page fetch and HTML heuristics) on any incoming URL from any surface
(paste, share/action extension, app intent, Safari extension, email, friend share).
What differs per app is HANDLING, and that difference is fixed at build time by
which per-kind packages the target links. There is no purchase, no runtime
entitlement, and no per-source exemption — email and friend-share ingestion drop
foreign kinds too, and the owning app's own import picks the same link up when
it's installed.

## The two gates (both compile-time-shaped)

1. **Pipeline processors (`IngestKindProcessors`, LunaIngest).** Article
   resolution (`LunaArticleIngest`) and product price extraction
   (`LunaPriceIngest`) are link-optional modules. Each target's composition root
   registers exactly the processors its app handles; a classified kind with no
   registered processor becomes `Outcome.unsupported(owner:)` — the page is never
   processed at all in an app that can't handle it. Media/social recognition is
   URL-only classification and needs no processor.
2. **`SurfaceSupport` (LunaIngest).** `Outcome.owningApp` maps every outcome to
   its owning app (`.unsupported` carries its owner; `.failed` has none and is
   never dropped). `SurfaceSupport.evaluate(owner:current:)`: the central Luna
   app supports everything; otherwise the outcome must belong to the running app,
   else `.unsupported(owner:)` → the save is DROPPED. The old gate's invariant
   holds: **dropped means nothing remains** — the placeholder row (and any copied
   document file) is deleted before any store write.

Drop presentation: in-app interactive saves show a generic alert
(`ReadingListIngestor.unsupportedSavePresenter`, installed by AppDelegate);
extensions present `UnsupportedSaveViewController` (never a "Saved" checkmark);
App Intents throw an error dialog (`IntentIngestHelper.unsupportedDialogText`) —
including the on-screen-URL path, whose pre-check (`IntentURLPrecheck`) skips
links this app doesn't own BEFORE saving, so a drop that still happens is a
mis-prediction worth reporting rather than a fall-through (see
`app-intents.md`, "Error reporting").
The copy is generic for now — the owning app's App Store upsell slots into
`SurfaceSupport.unsupportedMessage` once those store pages exist.

## Composition roots (how "which kinds" is wired)

`#if canImport(...)` LEAKS across targets in this project's package setup
(verified — all package modules share one build products dir), so per-target
behavior is done with per-target COMPILED FILES instead: synchronized-group
membership exceptions in `project.pbxproj` ensure each target compiles exactly
one variant, and the variants reference the kind modules' symbols directly
(which also guarantees linkage).

- Apps: `Luna/KindWiring+{Luna,Reader,Downloader,PriceTracker}.swift` — one per
  app target; `AppDelegate` calls `KindWiring.install()` first thing. Beyond the
  registries, each variant is its app's static composition API: the root
  view-controller shape (`makeRootViewController()` /
  `mainNavigationController(of:)`), the kind rows of Settings
  (`settingsCategories()`), and the kind-specific lifecycle work AppDelegate /
  SceneDelegate invoke at fixed points (media purge/Live-Activity resume,
  article send-retry/preload resume, the price-refresh BGTask's
  `priceRefreshRunner` — nil ⇒ the task is never registered). The shared list
  UI consults a third shell registry, `ListKindSupport`
  (`ArticleListSupport` / `MediaListSupport` / `ProductListSupport`, per-target
  compiled like the wiring); kind-specific shell FILES (article card deck +
  mini-player + audio wiring + reader/email settings screens; saved-media deck +
  auto-download settings + `MediaIntentHandoff`; the central-only
  `UITestScreen` / `NonArticleCardOpening`) are excluded from foreign targets
  through the same membership-exception mechanism. Intent seams:
  `ActionButtonIntentSupport.mediaHandoff` (media),
  `ReadArticleIntent.playArticle` (article; nil throws a friendly
  "not available in this app" error — the intent TYPE ships everywhere because
  the AppShortcuts metadata is shared), and URL Rescue's
  `URLRescueWiring.mediaRescueStarter` / `rescueProductInfo` legs.
- Share/action extensions: `LunaShare/ShareEntry+*.swift` and
  `LunaAction/ActionEntry+*.swift` — the extension principal class
  (Info.plist names the stable @objc names `LunaShareEntry`/`LunaActionEntry`)
  is a per-target `ShareViewController` subclass that registers processors AND
  extension presenters in `init` before any ingest can run.

A third registry, **`ShareKindPresenters` (LunaShareSurface)**, mirrors
`IngestKindProcessors`/`IngestorKindHandlers` for extension PRESENTATION:
LunaShareSurface is kind-neutral (host chrome + `ShareSurfaceDriver` only), and
the kind-specific UI lives in the kind modules — `ExtensionArticlePresenter`
(LunaReaderUI, in-sheet reader / archive-CAPTCHA reader / article-save extras),
`ExtensionMediaPresenter` (LunaMediaDownload, saved-non-textual screen +
auto-download handoff), `ExtensionProductPresenter` (LunaPriceUI, price
editor). The implementations are protocol-free; each entry class wires them up
through small private adapters conforming to the `Share*Presenting` protocols,
registering exactly its app's kinds (the driver's gate has already dropped
foreign kinds before a presenter is consulted, so a missing presenter for an
admitted kind is a composition-root bug and asserts). The apps' `KindWiring`
variants do NOT register extension presenters — nothing in-app runs the driver.
Tests register production-shaped presenters explicitly in `setUp`
(`ShareKindPresenterTestSupport`), like the pipeline processors.
- The Safari extensions link no packages; the native handler derives its host's
  kinds from its own bundle id (see `claudedocs/safari-extension.md`).

## Regression coverage

`SurfaceSupportTests` (decision matrix + `Outcome.owningApp`), `LunaAppTests`
(bundle-id derivation), `ReadingListIngestorSurfaceTests` (dropped-save
invariants incl. email/friend-share), `ShareSurfaceDriverSurfaceTests`
(extension drop UI + wrapper-dedup edge), `IntentIngestSurfaceTests` (intent
error mapping + save verification), `IntentURLPrecheckTests` (per-app kind
prediction), and `SurfaceParityTests` (presentation parity across surfaces).
Keep the "dropped means nothing remains" invariant explicit when adding a
capture source or a new direct-write path.
