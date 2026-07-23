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
entitlement, and no per-source exemption (the old Luna Interoperability purchase
and its `.email`/`.friendShare` exemptions are gone — the owning app's own import
picks the same message up when it's installed).

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
App Intents throw an error dialog (`IntentIngestHelper.unsupportedDialogText`).
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
  app target; `AppDelegate` calls `KindWiring.install()` first thing.
- Share/action extensions: `LunaShare/ShareEntry+*.swift` and
  `Luna Action Extension/ActionEntry+*.swift` — the extension principal class
  (Info.plist names the stable @objc names `LunaShareEntry`/`LunaActionEntry`)
  is a per-target `ShareViewController` subclass that registers processors in
  `init` before any ingest can run.
- The Safari extensions link no packages; the native handler derives its host's
  kinds from its own bundle id (see `claudedocs/safari-extension.md`).

## Regression coverage

`SurfaceSupportTests` (decision matrix + `Outcome.owningApp`), `LunaAppTests`
(bundle-id derivation), `ReadingListIngestorSurfaceTests` (dropped-save
invariants incl. email/friend-share), `ShareSurfaceDriverSurfaceTests`
(extension drop UI + wrapper-dedup edge), `IntentIngestSurfaceTests` (intent
error mapping), and `SurfaceParityTests` (presentation parity across surfaces).
Keep the "dropped means nothing remains" invariant explicit when adding a
capture source or a new direct-write path.
