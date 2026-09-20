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
which per-kind modules the app's kit carries and which composition root the target
compiles. There is no purchase, no runtime
entitlement, and no per-source exemption — email and friend-share ingestion drop
foreign kinds too, and the owning app's own import picks the same link up when
it's installed.

## The two gates (both compile-time-shaped)

1. **Pipeline processors (`IngestKindProcessors`, LunaIngest).** Article
   resolution (`LunaArticleIngest`) and product price extraction
   (`LunaPriceIngest`) sit in the kits of the apps that handle those kinds.
   Each target's composition root
   installs exactly the KIND PACKS its app handles (see "Kind packs" below); a
   classified kind with no registered processor becomes
   `Outcome.unsupported(owner:)` — the page is never processed at all in an app
   that can't handle it. Media/social recognition is URL-only classification and
   needs no processor.
2. **`SurfaceSupport` (LunaIngest).** `Outcome.owningApp` maps every outcome to
   its owning app (`.unsupported` carries its owner; `.failed` has none and is
   never dropped). `SurfaceSupport.evaluate(owner:current:)`: the central Luna
   app supports everything; otherwise the outcome must belong to the running app,
   else `.unsupported(owner:)` → the save is DROPPED. The old gate's invariant
   holds: **dropped means nothing remains** — the placeholder row (and any copied
   document file) is deleted before any store write.

A **Luna file** (`.luna` / `.lunar` / `.lunad` / `.lunas`) meets the same gate
by its header's `kind`, and a plugin draft outside central Luna is refused the
same way — the format, the exported types and all four intake routes are in
`claudedocs/luna-file.md`.

## Drop presentation — ONE card, everywhere

Every surface that can draw shows the SAME screen,
`UnsupportedSaveCardViewController` (**LunaDesignSystem** — below both the app
shell and LunaShareSurface, so all three hosts present one type): the in-app
interactive save (`SavesIngestor.unsupportedSavePresenter`, installed by
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
1024px masters the appiconsets use. Every kit carries LunaDesignSystem, so any
app can show whichever sibling owns a dropped link. The Safari extensions need none of this: they never inject a pill for a
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
  compiled like the wiring); kind-specific shell FILES (each kind's card
  presenter — see "Card presenters" below — plus the article chrome deck,
  mini-player, audio wiring and reader/email settings screens; the media
  auto-download settings and `MediaIntentHandoff`; and the product card
  content) are excluded from foreign targets through the same
  membership-exception mechanism. `ReadArticleIntent` is one of
  those files: it calls `AudioPlaybackCenter` directly and compiles only in the
  two apps that link read-aloud, so the two apps without it also compile a
  `LunaShortcuts` variant that omits the shortcut. Intent seams:
  `ActionButtonIntentSupport.mediaHandoff` (media) and URL Rescue's
  `URLRescueWiring.mediaRescueStarter` / `rescueProductInfo` legs.
- Share/action extensions: `LunaShare/ShareEntry+*.swift` and
  `LunaAction/ActionEntry+*.swift` — the extension principal class
  (Info.plist names the stable @objc names `LunaShareEntry`/`LunaActionEntry`)
  is a per-target `ShareViewController` subclass that installs its app's kind
  packs in `init`, before any ingest can run.

## Kind packs — one definition per kind, shared by every surface

An app has SEVERAL composition roots, one per surface, running in separate
processes with no shared launch code: the app shell, the share extension and
the action extension. **Six roots for the article kind alone.**

Those roots used to each hand-list their `IngestKindProcessors` /
`ShareKindPresenters` entries, and that broke exactly as you'd expect: when
long-form X posts were added (`claudedocs/x-posts.md`), the new
`IngestKindProcessors.socialText` entry went into the two `KindWiring+*` app roots
only. A long X post read fine saved inside the app and was rejected from the share
sheet as Downloader-owned. The same copy-paste also had each of the three
`Share*Presenting` adapters duplicated across four roots — twelve near-identical
definitions.

Now each kind owns ONE pack, in the kind's own top module, holding both its
registrations and its presenter adapter:

| Kind | Pack | Module | Registers |
| --- | --- | --- | --- |
| article | `ArticleKindComposition` | LunaReaderUI | `IngestKindProcessors.article` + `.socialText`, `ShareKindPresenters.article` |
| media | `MediaKindComposition` | LunaMediaDownload | `ShareKindPresenters.media` (no processor — URL-only classification) |
| product | `ProductKindComposition` | LunaPriceUI | `IngestKindProcessors.product`, `ShareKindPresenters.product` |

Every root then makes one call per kind — `ArticleKindComposition.install()` —
and nothing else. Adding a processor to a kind is a one-line change in its pack,
picked up by all its surfaces at once.

**The per-app split does not collapse, and that is the point.** The pack lives in
the kind's own module, so only a target that LINKS that kind can call it: the link
set still decides what an app handles, and a single-content app still drops
foreign kinds. What is now shared is the *definition* of a kind's wiring, not
which apps use it.

Two consequences worth knowing:

- The packs became possible because `LunaShareSurface` is kind-agnostic — it
  depends on no kind module — so a kind module can import it and own its own
  `Share*Presenting` conformance. The old comment claiming a composition root was
  "the one place allowed to see the surface protocol and the kind module at once"
  was simply not true. `LunaReaderUI` gained `LunaArticleIngest` +
  `LunaShareSurface` deps, and LunaMediaDownload/LunaPriceUI gained
  `LunaShareSurface`.
- An app installing a pack also sets the extension presenter it never reads.
  That is a deliberate trade: one uniform call is worth far more than a
  per-surface list each root can get wrong.

`KindCompositionRootTests` enforces all of this by reading the composition-root
source — no unit test can load the real roots, since each registry is set in a
principal class's initializer in a different process. It fails when a root
registers a kind directly, when a root's installed packs don't match its app's
kinds (missing OR foreign), when an expected root disappears, and when a new
unlisted root installs a pack.

**Still per-root, by necessity:** `IngestorKindHandlers` (the app-shell
persistence handlers — `ArticleKindHandler` and friends) is built from app-shell
types the library layer can't see, so it stays in each `KindWiring+*`. Those four
roots live in one folder and are app-only, so the surface-mismatch hazard the
packs remove doesn't apply to it.

## Card presenters — the same contract, for what a save LOOKS like

Kind packs answer "what does this app DO with this link". A second, parallel
registry answers "what does this save look like on a card", and it exists for
the same reason and was created by the same bug.

Every app's root is a card deck. The deck machinery is shared
(`CardCarouselHostViewController`), but the kind-specific half used to be a
`CardDeckProviding` conformance on each root VIEW CONTROLLER — so three deck
subclasses each answered the same questions about the same saves, and the
central app, which shows all of them, needed a FOURTH hand-listed adapter
(`AllKindsCardProviding`) to forward the kinds it could not name. Anything not
explicitly forwarded diverged in silence: a failed download's red rim existed
only in the Downloader, archiving wrote a different store in each app, deleting
an archived media save centrally leaked its file and its Photos asset, and a
tracked product rendered as a generic link card in the central app while the
real product editor sat compiled into the same binary, unreachable.

So a kind's CARD behavior is now defined once too, in
`CardKindPresenting` (`Luna/CardCarouselHost/CardKindPresenter.swift`):

| Kind | Presenter | File | Luna | Reader | Downloader | PriceTracker |
| --- | --- | --- | --- | --- | --- | --- |
| article | `ArticleCardPresenter` | `Luna/Reader/ArticleCardPresenter.swift` | ✓ | ✓ | ✗ | ✗ |
| media | `MediaCardPresenter` | `Luna/Downloader/MediaCardPresenter.swift` | ✓ | ✗ | ✓ | ✗ |
| product | `ProductCardPresenter` | `Luna/PriceTracker/ProductCardPresenter.swift` | ✓ | ✗ | ✗ | ✓ |

Gated by the SAME membership-exception mechanism as every other per-target file
(`#if canImport` is not target-reliable here), and installed by the same roots
that install the packs — one line each in `KindWiring+<App>`. Only the app shell
draws cards, so unlike a pack, no extension installs a presenter.

Two rules make the old bug unrepresentable, and `KindCompositionRootTests`
enforces both by reading source:

- **The deck never asks what kind a save is.** Resolution lives once, in
  `CardKindPresenters.presenter(for:)`, in a fixed order: a FAILED save is
  kind-less by definition (the classifier never got one) and returns nil, which
  is exactly why the deck draws its error card itself and why every app shows
  failed saves; then product, then media, then article. A file under
  `Luna/CardCarouselHost/` that mentions `isPriceTracker` or `contentPlatform`
  fails the build.
- **Only an app root writes the registry.** Reading it is how the deck works;
  a second write is how a surface gets a different card for the same save.

A presenter answers questions about a `SavedItem`, never about a slot
index — slot arithmetic, the util-card offset, the fingerprint diff and the
centering ladder stay in the host, which is the only thing that ever needed
them. Media joins use `media_saves.save_id`, not URL text. The save may retain a
Reddit `/r/…/s/` wrapper while its media row records the resolved permalink; the
shared id still produces one card and one archive identity. `unbackedItems()` is
only a defensive protocol escape hatch now: the foreign key makes every valid
media row a child of a real save, and its id-based membership test prevents a
differently-shaped URL from manufacturing a duplicate stand-in slot.

A third registry, **`ShareKindPresenters` (LunaShareSurface)**, mirrors
`IngestKindProcessors`/`IngestorKindHandlers` for extension PRESENTATION:
LunaShareSurface is kind-neutral (host chrome + `ShareSurfaceDriver` only), and
the kind-specific UI lives in the kind modules — `ExtensionArticlePresenter`
(LunaReaderUI, in-sheet reader / archive-CAPTCHA reader / article-save extras),
`ExtensionMediaPresenter` (LunaMediaDownload, saved-non-textual screen +
auto-download handoff), `ExtensionProductPresenter` (LunaPriceUI, price
editor). The implementations are protocol-free; each kind's PACK owns the one
adapter conforming to the matching `Share*Presenting` protocol (the driver's gate
has already dropped foreign kinds before a presenter is consulted, so a missing
presenter for an admitted kind is a composition-root bug and asserts).
Tests register production-shaped presenters explicitly in `setUp`
(`ShareKindPresenterTestSupport`), like the pipeline processors.

`ShareMediaPresenting` carries two DEFAULTED asks the shared app shell makes of
whatever media presenter is registered — `preloadDownload(forURLString:)` and
`deleteSavedContents(forURLString:)`, used by the onboarding save lesson to start
and undo a media save. The shell reaches them through `ShareMediaSideEffects`, a
thin façade in LunaShareSurface, rather than by naming `ShareKindPresenters`: every
mention of the registry inside a composition-root DIRECTORY is what
`KindCompositionRootTests` forbids, and keeping that rule as "no root says the word"
is sharper than narrowing it to assignments. Three of the four kits carry no media
module, so both asks are no-ops there, which is correct — they have no media to
preload or delete.
- A Safari extension USES only the Foundation-only floor (`LunaAppConfig`,
  `LunaModels`, `LunaURLClassification`, `LunaMediaResolve`, `LunaStorage`) plus
  `LunaPriceCompare` — no kind UI, and no kind processor. Its kit holds more than
  that (one kit serves the app and every extension), so reachability is not the
  gate: all four appexes share one source file and derive their host's kinds from
  their own bundle id, with `hostHandlesArticles`/`hostHandlesMedia`/
  `hostHandlesProducts` gating every branch, including the in-page video player's
  `resolveMedia` (media hosts only). `LunaMediaResolve` is deliberately
  kind-neutral machinery — post URL to CDN URL — shared so the extension can never
  disagree with the app about what a link resolves to (see
  `claudedocs/safari-extension.md`, "Where the work runs").

## Regression coverage

`SurfaceSupportTests` (decision matrix + `Outcome.owningApp`), `LunaAppTests`
(bundle-id derivation), `SavesIngestorSurfaceTests` (dropped-save
invariants incl. email/friend-share), `ShareSurfaceDriverSurfaceTests`
(extension drop UI + wrapper-dedup edge), `IntentIngestSurfaceTests` (intent
error mapping + save verification), `IntentURLPrecheckTests` (per-app kind
prediction), `UnsupportedSaveCardTests` (the shared card's copy, the
sibling-app icons resolving from LunaDesignSystem's bundle in every target, the
carousel dress, and the header-only fallback), and `SurfaceParityTests`
(presentation parity across surfaces). `KindCompositionRootTests` covers both
registries: the ingest packs (no root registers a kind directly, each root
installs exactly its app's packs, no expected root has vanished, no unlisted
root installs one) and the card presenters (each app root installs exactly its
app's presenters, nothing else writes that registry, the deck never branches on
kind).
Keep the "dropped means nothing remains" invariant explicit when adding a
capture source or a new direct-write path.
