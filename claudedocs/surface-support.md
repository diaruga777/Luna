# Per-app content kinds (SurfaceSupport)

Luna is four apps over one shared store. The central **Luna** app (bare bundle id
`com.hsanabria.luna`, a paid app) handles EVERY content kind; each single-content
app handles exactly one:

| App | Bundle id | Handles | Email |
| --- | --- | --- | --- |
| Luna (central, paid) | `<prefix>` | everything | yes |
| Luna Reader | `<prefix>.reader` | articles, paywalled articles, documents | yes |
| Luna Downloader | `<prefix>.downloader` | social / video media | no — URL sharing only |
| Luna Price Tracker | `<prefix>.pricetracker` | product price trackers | no — URL sharing only |

Email is a second, independent per-app capability, `LunaApp.sharesByEmail`:
connecting an account, sending saves to contacts, and importing shares/newsletters
from a mailbox. It is a runtime property of the surface rather than a link-set
decision, because the shell files that offer those affordances are universal —
see `claudedocs/social-sharing.md` and `claudedocs/incoming-mail.md`.

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

## Drop presentation — ONE card, everywhere

Every surface that can draw shows the SAME screen,
`UnsupportedSaveCardViewController` (**LunaDesignSystem** — below both the app
shell and LunaShareSurface, so all three hosts present one type): the in-app
interactive save (`ReadingListIngestor.unsupportedSavePresenter`, installed by
AppDelegate, presented full screen), the share extension, and the action
extension. Never a "Saved" checkmark — nothing was saved — and its only action
is its own glass Done pill (it hides a host's navigation bar so the app's bare
presentation and the extensions' wrapped one look identical).

It is dressed as the root card deck, because that is what a Luna app looks
like: `StarfieldView` behind, one 9:16 `CardSurfaceView` with the Liquid Glass
rim at the carousel's own `CardCarouselMetrics` geometry, both tinted per app
by `LunaSurfacePalette` (which resolves from the bundle id, so an extension
inherits its host app's colour). Content is two statements:

- the **header**, shown for EVERY drop — "Unable to save this link in
  \<current app>";
- when a sibling Luna app owns the kind, **that app's real icon** and "You can
  get the \<owner> app for this type of link" underneath. A drop with no
  sibling owner (defensive; today's gate always names one) shows the header
  alone.

The wording lives once, in `UnsupportedSaveCopy` (**LunaModels**).
`SurfaceSupport.unsupportedMessage` is now just its `sentence(owner:current:)`
flattening, for the one surface that can't draw: App Intents throw an error
dialog (`IntentIngestHelper.unsupportedDialogText`) — including the
on-screen-URL path, whose pre-check (`IntentURLPrecheck`) skips links this app
doesn't own BEFORE saving, so a drop that still happens is a mis-prediction
worth reporting rather than a fall-through (see `app-intents.md`, "Error
reporting").

**Every app bundles every app's icon.** A target's own `AppIcon*` appiconset
only yields its own artwork at runtime, so the four icons ship separately as
96pt PNG trios in LunaDesignSystem's resource bundle
(`LunaAppIconImage` / `LunaAppIconView`), downscaled from the same committed
1024px masters the appiconsets use. LunaDesignSystem is on every app's and
extension's link path, so any app can show whichever sibling owns a dropped
link. The Safari extensions need none of this: they never inject a pill for a
kind their host doesn't handle, so they have no drop UI to show.

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
  UI consulted a third shell registry, `ListKindSupport` (DELETED — it served only the removed sectioned list; nothing ever read it from the decks)
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
prediction), `UnsupportedSaveCardTests` (the shared card's copy, the
sibling-app icons resolving from LunaDesignSystem's bundle in every target, the
carousel dress, and the header-only fallback), and `SurfaceParityTests`
(presentation parity across surfaces).
Keep the "dropped means nothing remains" invariant explicit when adding a
capture source or a new direct-write path.
