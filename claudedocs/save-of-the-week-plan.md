# Save of the Week — CloudKit-driven, signed, per-kind (implementation plan)

Replaces the hardcoded util-card "Save of the Week" row with a live, signed,
CloudKit-public-database-driven value: one entry per save type (article / media /
product) at any time, readable by every Luna app install, writable only by the
holder of a private key, with a public "propose" channel for everyone else.

This plan was produced from a full code survey; all file:line anchors below were
verified against this worktree at `4b984426`. Work happens in the worktree
`/Users/hsp/Desktop/Luna/.claude/worktrees/save-of-the-week` on branch
`worktree-save-of-the-week`. Another session is actively committing onboarding
work to `main` in the primary checkout — touch `Luna/Reader/Onboarding/*` and
`CLAUDE.md` as little as possible to keep the final merge small.

## 1. Current state (what exists, what goes away)

- `Luna/UtilCard/UtilCardContentViewController.swift:26` — `static let
  saveOfTheWeekURLString = "https://www.lewissociety.org/innerring/"` (DELETE).
  L79–89 seeds a hardcoded fallback preview ("The Inner Ring") (DELETE).
  L318–331 `loadSaveOfTheWeekPreview()` refetches metadata via
  `RecentURLMatcher.evaluate(urlString:surface: .luna)` on every construction,
  uncached (REPLACE with store-cached metadata).
- The row itself, `UtilURLRow` (same file, L337–428, `style: .saveOfTheWeek`,
  accessibility id `utilCard.saveOfTheWeek`), its glass rim, its tap-to-save
  handoff (`save(_:source:sourceView:)` → `UtilCardSaveTransition`) all stay.
- Subtitle today: `host + "  •  " + L10n.string("Save of the week")` (L396–398).
  `"Save of the week"` is in NO string catalog today.
- `LunaTests/UtilCardTests.swift:72` pins the literal Lewis Society URL; L33/L48
  assert the weekly row is always present in both launch variants; L78 pins the
  tap→save callback. These tests get rewritten (row is now conditional).
- There is ZERO CloudKit in the repo: no `import CloudKit`, no iCloud
  entitlement anywhere, no container id in `Config/Luna.xcconfig` or
  `AppConfig`. Every "CloudKit" string is a stale comment.
- Docs to update at the end: `claudedocs/util-card.md` (L32–45 "For now its
  canonical URL is…"), `CLAUDE.md` surface-gating paragraph ("Paste and the
  fixed Save of the Week remain in both states" — reword to "Paste remains in
  both states; the Save of the Week row appears whenever a live signed entry
  exists"), plus a new `claudedocs/save-of-the-week.md` feature doc.

## 2. Decisions already made (do not re-litigate; flag in the final report)

1. **"Parallel but separate database" = a second record type in the same public
   CloudKit database.** CloudKit gives one public DB per container; the
   proposals channel is `WeeklySaveProposal` records alongside `WeeklySave`.
2. **Central Luna keeps the noun "Save"** ("Save of the week" / "Save of the
   month") for all three kinds as it cycles; only the faceted apps rename
   (Read / Download / Deal). The spec assigned nouns per app, not per kind.
3. **Signature scheme is Ed25519** (`CryptoKit.Curve25519.Signing`), signing the
   canonical UTF-8 message `"\(kind.rawValue)\n\(urlString)\n\(ISO8601 date)"`.
   Verification failure = the record does not exist, silently.
4. **The pasted private key lives in the shared Keychain**
   (`CredentialKeychain`, access group = App Group, so all four of the user's
   own apps become key-holders after one paste per device... per app is still
   one paste each ONLY if apps didn't share the group — they do share it, so one
   paste unlocks all four apps on that device).
5. **Container id derives from the namespace**: `iCloud.$(PRODUCT_BUNDLE_PREFIX)`
   → `iCloud.com.hsanabria.luna`, plumbed exactly like the App Group (xcconfig →
   Info.plist key → `AppConfig`).
6. **CloudKit is never exercised by unit tests.** Everything CloudKit-facing
   hides behind a small protocol; tests use fakes. The implementation must not
   attempt live CloudKit verification (no container exists yet — see §12).

## 3. New module: `LunaWeekly` (LunaLibraries)

Tier-4-style target, deps: `LunaAppConfig`, `LunaModels`, `LunaStorage` (same
shape as `LunaSocial`, Package.swift:115). Links `CloudKit`, `CryptoKit`,
`UserNotifications` (system frameworks — no Package.swift dependency entries
needed). Added to the UNIVERSAL link set of all four app targets (pbxproj: add
the product to each app's Frameworks phase; extensions do NOT link it). Public
API + explicit public inits (package is Swift 5 mode).

Contents:

### 3a. Model
```swift
public enum WeeklySaveKind: String, Codable, CaseIterable, Sendable {
    case article, media, product
}
public struct WeeklySave: Codable, Equatable, Sendable {
    public let kind: WeeklySaveKind
    public let urlString: String
    public let date: Date          // when it became "of the week"
    public let signature: Data     // Ed25519 over canonical message
}
```
- `WeeklySave.canonicalMessage` -> `Data` (kind + "\n" + urlString + "\n" +
  ISO8601(date, no fractional seconds — pick ONE formatter and use it for both
  sign and verify; store `date` in CK as `Date` but sign the formatted string).
- Age helpers with injected clock: `isExpired(now:)` (> 30 days),
  `isMonthTier(now:)` (>= 9 days).
- Per-app kind ownership: `.luna` → all three; `.reader` → `[.article]`;
  `.downloader` → `[.media]`; `.priceTracker` → `[.product]` (switch on
  `LunaApp`).

### 3b. Signing (`WeeklySigning`)
- Embedded public key: `public static let publicKeyBase64: String` — the REAL
  key generated in §11, not a placeholder.
- `verify(_ save: WeeklySave) -> Bool` via `Curve25519.Signing.PublicKey`.
- `sign(kind:urlString:date:privateKey:) throws -> WeeklySave`.
- `privateKeyMatchesBundledPublicKey(_ base64: String) -> Bool` (derive public
  from private, compare raw representations) — used by the diagnostics paste.

### 3c. Key store (`WeeklyPromotionKeyStore`)
- Wraps `CredentialKeychain` (LunaStorage — `CredentialKeychain.swift:25`,
  access group `AppConfig.appGroupID`), service `"weeklyPromotionKey"`.
- `storedPrivateKey() -> Curve25519.Signing.PrivateKey?` (validates against the
  bundled public key on read; a mismatched stored key reads as nil),
  `store(base64:) -> Bool` (validate first), `var isKeyHolder: Bool`.

### 3d. Local store (`WeeklySaveStore`)
Sidecar-JSON pattern copied from `SaveFailureStore.swift:62–77` (NSLock +
in-memory dict + `containerURL: URL? = nil` and `now: @escaping () -> Date =
Date.init` injection seams; `BackupPolicy.includeInBackups`). File
`weeklySaves.json` in the App Group container. Persists per kind:
```swift
public struct WeeklySaveDisplay: Codable, Equatable {
    public var save: WeeklySave
    public var title: String
    public var subtitleHost: String
    public var imageData: Data?      // already downscaled by the fetch path
}
```
- `display(for kind: WeeklySaveKind) -> WeeklySaveDisplay?` — returns nil when
  absent OR expired (>30d against injected clock).
- `setDisplay(_:for:)`, `clear(kind:)`; posts
  `WeeklySaveStore.didChange` (main thread) with the kind in userInfo.
- Also persists the seen-proposal-ID set for notification dedup (§8).

### 3e. CloudKit client (`WeeklyCloudClient`)
Protocol-first:
```swift
public protocol WeeklyCloudDatabase {           // the seam tests fake
    func fetchWeeklySaves(for kinds: [WeeklySaveKind]) async throws -> [WeeklySave]
    func saveWeekly(_ save: WeeklySave) async throws
    func fetchProposals() async throws -> [WeeklyProposal]
    func createProposal(_ proposal: WeeklyProposal) async throws
    func deleteProposal(recordName: String) async throws
    func accountStatus() async throws -> Bool   // signed-in?
}
```
Concrete `CKWeeklyCloudDatabase`:
- `CKContainer(identifier: AppConfig.cloudKitContainerID).publicCloudDatabase`,
  created LAZILY on first use only (CKContainer traps if the entitlement is
  missing; never touch it from tests — tests always inject fakes).
- Record type `WeeklySave`, fixed record names `weekly-article` /
  `weekly-media` / `weekly-product` → reads are `fetch(withRecordID:)` (no
  queryable-index requirement), one per kind. Fields: `kind: String`,
  `url: String`, `date: Date`, `signature: Data`.
- Promotion writes: fetch existing record by ID, mutate fields (or create new
  `CKRecord` with the fixed ID on `.unknownItem`), save with
  `savePolicy = .changedKeys`.
- Record type `WeeklySaveProposal`, recordName `proposal-<hex>` where hex =
  first 32 hex chars of SHA-256 of the trimmed absolute URL string — this IS
  the URL dedup (a second proposal of the same URL overwrites/no-ops; treat
  `serverRecordChanged` as success). Fields: `kind: String`, `url: String`,
  `date: Date` (proposed-at). `WeeklyProposal` struct mirrors those + recordName.
- Proposal fetch: `CKQuery(recordType:predicate: NSPredicate(value: true))`
  sorted by date desc (needs the dashboard indexes in §12; failure surfaces as
  an empty list + DiagnosticLog entry, never a crash).
- ALL CK errors are caught at the call sites below and reduced to
  no-op + `DiagnosticLog.shared.record(_:category: "weekly")`. This feature
  must never crash an app that has no network, no iCloud account, or no
  container provisioned yet.

### 3f. Refresher (`WeeklySaveRefresher`)
The launch/foreground orchestration, `@MainActor`, singleton with injected
database + store + clock + a `metadataFetcher: (String) async -> (title:
String, host: String, imageData: Data?)?` closure (installed from the app shell
— see §5a — because the module cannot see LunaIngest):
- `refreshWeeklySaves()`: for `LunaApp.current`'s kinds → fetch → verify
  signature → drop expired (>30d) → compare `(urlString, date)` against store →
  if new: fetch metadata FIRST, then `store.setDisplay(...)` (so the UI animates
  in a fully-formed row); if the cloud says absent/invalid/expired where the
  store has a value: `store.clear(kind:)`.
- Debounce: at most one in-flight refresh; skip if the last completed refresh
  was < 60s ago (foreground spam guard).
- `checkProposalsIfKeyHolder()` — §8.

## 4. Configuration plumbing (container id)

Mirror the App Group exactly:
- `Config/Luna.xcconfig`: nothing new needed — the container string derives
  from `PRODUCT_BUNDLE_PREFIX` which already exists.
- `Luna/Info.plist` (shared by all four app targets): add
  `LunaCloudKitContainerID` = `iCloud.$(PRODUCT_BUNDLE_PREFIX)`.
- `AppConfig` (LunaAppConfig/AppConfig.swift): add `public static var
  cloudKitContainerID: String` reading that key, fallback
  `"iCloud.com.hsanabria.luna"` (same shape as `appGroupID`, L22/L53).
- Entitlements — add to the FOUR APP files only (`Luna/Luna.entitlements`,
  `Luna/LunaReader.entitlements`, `Luna/LunaDownloader.entitlements`,
  `Luna/LunaPriceTracker.entitlements`; never share one file — CLAUDE.md
  documents why):
  ```xml
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudKit</string></array>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>iCloud.$(PRODUCT_BUNDLE_PREFIX)</string></array>
  ```
  Extensions/clips/widgets get nothing. Simulator ad-hoc signing tolerates
  these; live CK calls will just error (handled per §3e) until the user does
  the portal step (§12).

## 5. Util card integration (all four apps)

### 5a. Wiring
- `UtilCardContentViewController` gains injectable deps with defaults:
  `weeklyStore: WeeklySaveStore = .shared`. Replace the hardcoded row seeding +
  `loadSaveOfTheWeekPreview()` with a `WeeklySaveRowHost` (new file
  `Luna/UtilCard/WeeklySaveRowHost.swift`, shared shell — compiled into all
  four targets, no membership exceptions).
- Install `WeeklySaveRefresher.metadataFetcher` once at launch (AppDelegate,
  next to the other closure seams ~L57): wrap
  `RecentURLMatcher.evaluate(urlString:surface: .luna)` (RecentURLMatcher.swift:227
  — `.luna` deliberately, so a faceted app can render any kind) and map
  `RecentURLPreview` → (title, host, imageData).
- Fetch triggers: `AppDelegate.didFinishLaunching` (deferred to the existing
  utility-queue block at L194–199, then hop to MainActor) and
  `SceneDelegate.sceneWillEnterForeground` (L187–200) → `Task {
  WeeklySaveRefresher.shared.refreshWeeklySaves() }`. These are shared-shell
  files: every app gets the behavior, each fetches only its own kinds (§3a).

### 5b. Row presence & layout
- The weekly row is now CONDITIONAL: present iff
  `weeklyStore.display(for:)` is non-nil for ≥1 of the app's kinds. Both
  util-card layout branches (`viewDidLayoutSubviews` L135–169) reflow when it
  is absent: first-run state shifts safari/save-setup buttons up by the row's
  slot; completed state starts recent rows at the row's y. Keep the existing
  metrics (row height 82, spacings) when present.
- Row content comes from `WeeklySaveDisplay` (cached title/host/image) —
  configure a `RecentURLPreview` from it for the existing
  `UtilURLRow.configure` path; kind maps to the SF-symbol fallbacks already in
  place. Tap keeps the existing `save(urlString, source: .manual, ...)` path.
- Subtitle label text (replaces the bare `L10n.string("Save of the week")`):
  per app × per age tier, via `L10n.string` with catalog entries added per
  `claudedocs/strings.md` ownership rules:
  | app | < 9 days | ≥ 9 days |
  |---|---|---|
  | Luna | Save of the week | Save of the month |
  | Reader | Read of the week | Read of the month |
  | Downloader | Download of the week | Download of the month |
  | Price Tracker | Deal of the week | Deal of the month |
  Age tier computed from `save.date` with the injected clock at configure time.
- Live change handling: observe `WeeklySaveStore.didChange` in the util card.
  - Row absent → value appears: lay the row in with a simple fade/settle
    (0.24s easeOut, matching ArticleCardsViewController.swift:702 conventions),
    reflowing the other rows.
  - Row present → value REPLACED (different url/date): the eclipse animation,
    §6.
  - Value cleared → fade the row out and reflow.
  - Reduce Motion (`UIAccessibility.isReduceMotionEnabled`): plain crossfade
    everywhere (carousel precedent, CarouselAnimationTiming.crossfadeDuration).

## 6. Row-replacement eclipse animation

Goal (spec): the NEW row slides over the OLD one exactly like the carousel's
card-swipe eclipse: new row starts at `x = +30%` of row width, `alpha = 0`,
quickly fades to 1, completes the translation, hits the corona at full cover,
corona fades, done.

Build a small `WeeklyRowEclipseTransition` in `Luna/UtilCard/` following the
established copy-the-choreography pattern (`InlineReaderEclipseScene`,
LunaReaderUI/InlineReaderEclipseTransition.swift:104, and the row-sized
`LunarEclipseTransition`, LunaTransitions/LunarEclipseTransition.swift):
- Corona: `EclipseCoronaView(bodySize: rowSize, cornerRadius: <the row's actual
  corner radius>, tint: LunaSurfacePalette.atmosphereTint, reach: ~30)`. The
  reach override is REQUIRED at row scale — precedent + rationale at
  `MessagesReplicaViewController.swift:1760` ("EclipseCorona's own default has
  a 56pt floor sized for a card"). Do NOT use `CardEclipseTransition.makeCorona`
  (hardcodes card cornerRadius 22 + card reach).
- Choreography (total ≈ 0.62s = `CardEclipseTransition.duration`, ingress 66% /
  egress 34%, `UIView.animateKeyframes` with `.calculationModeCubic`):
  1. New row view (a second fully-configured `UtilURLRow`) added above the old
     one at `transform = translationX(rowWidth * 0.3)`, `alpha = 0`. Corona
     view behind it at the OLD row's frame, `alpha 0`.
  2. Ingress keyframes: alpha 0→1 in the FIRST ~25% (the "quickly fades in"),
     translation → .identity over the full ingress; old row holds then
     whitens late (white overlay 0.06 → 0.92 at the 80% break) and corona
     0.08 → 1.0 at the same late break — the same 0.80/0.20 keyframe split the
     card transition uses (CardEclipseAnimator.swift:173–215).
  3. Zenith: remove the old row, new row is in place.
  4. Egress: corona alpha → 0, done. (No flare, no dimmer, no peeks — this is a
     row, not a card; the corona IS the effect. Skip `EclipseFlareView` unless
     it reads well at 82pt — implementer's call, it's a one-liner to add at the
     covered edge per CardEclipseAnimator.swift:139.)
- Prewarm is unnecessary at this size (visual-effects.md: card raster ~100ms at
  1x; an 82pt row is far cheaper) but `EclipseCorona.prewarm` is available.
- The util card must retain the transition object for its whole run (the
  carousel learned this the hard way — CardCarouselViewController.swift:351).

## 7. Central-app kind cycling (Luna only)

Only the central app has >1 kind. `WeeklySaveRowHost` (§5a) manages N
configured row views (one per kind with a live display), in the single row slot:
- **Auto-advance**: every 2.0s, advance forward. `Timer.scheduledTimer(2.0,
  repeats: true)` with `tolerance`, gated by ALL of: ≥2 live kinds, card is
  centered (`cardDidBecomeCentered` / `cardDidLeaveCenter`,
  CardContentViewController.swift:65), view in window (cleanest precedent:
  `MoonHorizonProgress.didMoveToWindow`, MoonHorizonProgress.swift:265–283),
  app active (`didEnterBackground` stops, `willEnterForeground` restarts —
  which also RE-ENABLES auto after a manual gesture, per spec), no replacement
  transition in flight, and Reduce Motion off (RM: no auto-cycling; swipe still
  works with crossfade).
- **Manual swipe**: `UIPanGestureRecognizer` on the row host, horizontal-intent
  gate `abs(v.x) > abs(v.y) * 1.5` (the in-card policy the carousel uses,
  CardCarouselPagePanStartPolicy, CardCarouselViewController.swift:224–244) so
  it coexists with the deck's own page-pan (which requires that same test —
  verify the deck still pages when the gesture starts vertical/outside). It
  must NOT fight `pagePan`: return `false` from
  `gestureRecognizerShouldBegin` for non-horizontal, and let simultaneous
  recognition stay off so whoever wins the intent test owns the touch.
  Interactive: finger drags current row (full-width travel mapping), neighbor
  row tracks alongside; release commits past 50% or velocity > 350pt/s toward
  target, else springs back — the carousel's exact thresholds
  (CardCarouselViewController.swift:1333–1364). Wraps around (3 kinds cycle).
- **First manual interaction disables auto-advance** until: the card leaves
  center, or the app backgrounds→foregrounds (both simply reset the
  "userTookControl" flag and restart the timer when gates re-open).
- **Transition look** (auto and committed swipe settle): horizontal slide, NOT
  eclipse. Apple-quality spec: incoming slides in from the direction of travel
  at full width offset, outgoing slides out the other side; both via one
  `UIViewPropertyAnimator(duration: 0.55, timingParameters:
  UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: <from
  gesture>))` (precedent LinkRSVPPreview.swift:567–570); outgoing picks up a
  slight alpha dip (→ 0.85) and the incoming a 12–16pt parallax lag on its
  internal content (thumbnail+labels move ~0.85× of the row shell) for depth.
  Clip to the row slot's bounds (a container with `clipsToBounds = true`,
  corner radius matching the row) so rows never bleed onto the card.
  Interruptible: a new swipe mid-flight grabs the running animator
  (`pauseAnimation`, retarget) rather than queuing.
- The label ("Save of the week" etc.) and rim tint stay constant in the central
  app (decision §2.2), so only row content slides.
- The 2s cadence pauses while the row is mid-replacement (eclipse) and while
  the user is touching the row.

## 8. Promotion & proposals

### 8a. Long-press menu items (all three decks)
The Archive/Delete tail is triplicated; add the new item in all three builders:
- `Luna/Reader/ArticleCardsViewController.swift:1115–1148` (skip the
  failed-save branch),
- `Luna/PriceTracker/PriceTrackerCardsViewController.swift:404–430`,
- `Luna/Downloader/SavedMediaCardsViewController.swift:1086–1139`.

One shared factory (new file `Luna/UtilCard/WeeklyPromotionMenu.swift`, shell):
`WeeklyPromotionMenu.action(for item: ReadingListItem, presenter:
UIViewController) -> UIAction?`:
- nil for failed saves and for items whose kind doesn't map to a
  `WeeklySaveKind` (map from the item's own kind: article-ish → `.article`,
  social/video → `.media`, product → `.product` — reuse the
  `ReadingListSectioning`/item-kind helpers the decks already use).
- Key-holder (`WeeklyPromotionKeyStore.isKeyHolder`): title "Promote to
  {Save|Read|Download|Deal} of the Week" (app-appropriate noun), symbol e.g.
  `crown` / `star.circle`. Runs: confirmation alert → sign `WeeklySave(kind:,
  urlString: item's url, date: now)` with the stored key →
  `database.saveWeekly` → on success also update the LOCAL store + display
  immediately (self-promotion shows up without waiting for the next fetch) and
  if it was promoted from a proposal, delete that proposal record. Errors →
  alert with the CK error's localizedDescription.
- Non-key-holder: title "Propose Save of the Week", runs `createProposal`
  (kind, url, now). No iCloud account (`accountStatus` false or CK
  `.notAuthenticated`) → alert "Sign in to iCloud to propose…". Success → brief
  confirmation alert (the decks already use `presentInfoAlert`-style alerts).
- Menu placement: above Archive/Delete, below kind actions.

### 8b. Proposal inbox (key-holder only)
- Settings page `WeeklyProposalsScreen` (new shell file under
  `Luna/Settings/`), a `NavHeaderTableController` dynamic list (pattern:
  `EmailAndKindleSettingsScreen.swift:113–120`): one row per proposal — title =
  URL host + path, subtitle = kind + relative date. Swipe-to-delete deletes the
  CK record; tapping a row offers Promote / Delete / Cancel (action sheet).
  Promote = sign + `saveWeekly` + delete proposal + refresh local store.
  Empty state: a footer "No proposals right now."
- Category appended in `SettingsViewController.swift:56–67`'s universal tail,
  ONLY when `WeeklyPromotionKeyStore.isKeyHolder`: `SettingsCategory(title:
  "Save of the Week", symbol: "crown")`. (The categories array is `let` built
  at init; the screen is constructed fresh each visit so key-holder status at
  Settings-open time is fine.)
- Opportunistic fetch: `WeeklySaveRefresher.checkProposalsIfKeyHolder()` called
  from the same launch/foreground hooks (§5a). Diffs fetched proposal
  recordNames against the store's seen-ID set; NEW ones → local notification
  ("New Save of the Week proposal: <host>", one per batch is fine:
  "3 new proposals") via a `NotificationManager`-style helper in LunaWeekly
  (immediate `UNNotificationRequest`, no trigger — pattern
  NotificationManager.swift:78–83, userInfo type key
  `"weeklyProposal"`), then marks seen. Tapping the notification just opens the
  app (routing to Settings is a nice-to-have; skip unless trivial via the
  existing `didReceive` router, AppDelegate.swift:368–378).
- Background refresh: new `BGAppRefreshTask` id
  `com.hsanabria.luna.weeklyProposalCheck`:
  - Info.plist `BGTaskSchedulerPermittedIdentifiers` (+ the new id; plist
    shared by all four apps).
  - Register unconditionally in `AppDelegate.didFinishLaunching` next to the
    existing registrations (L147–161); the handler AND the scheduler both
    no-op unless `isKeyHolder`. Schedule (earliest = now + 4h) from launch and
    `applicationDidEnterBackground`, following the idempotent
    `getPendingTaskRequests` guard pattern of `schedulePriceRefresh`
    (AppDelegate.swift:260–302). Handler: expiration handler first, then
    `checkProposalsIfKeyHolder()`, `setTaskCompleted`, reschedule.
- Pasting the key (§9) calls `NotificationManager.requestAuthorization()`
  (LunaSocial/NotificationManager.swift:30) — the spec's "paste triggers the
  notification permission prompt".

## 9. Diagnostics: private-key entry

`Luna/Diagnostics/DiagnosticsViewController.swift` (reached by 5 taps on blank
space in Settings — SettingsViewController.swift:77–89):
- Add a second body button "Enter Weekly Key" above/beside Reset Onboarding
  (small `UIStackView` refactor of the bottom buttons is acceptable; keep
  `diagnostics.resetOnboarding`'s accessibility id and behavior intact).
- Tap → alert with a secure text field (paste target) → trim → validate via
  `WeeklySigning.privateKeyMatchesBundledPublicKey` → on success: store in
  `WeeklyPromotionKeyStore`, `NotificationManager.requestAuthorization()`,
  schedule the proposal BG task, confirmation alert ("This device can now
  promote Saves of the Week"), and log to DiagnosticLog. On mismatch: error
  alert, nothing stored.
- When a key is already stored, the button reads "Weekly Key ✓" and offers
  Replace / Remove (remove deletes from Keychain).

## 10. Expiry & absence rules (single source of truth: `WeeklySaveStore`)

- No CK record / bad signature / `date` > 30 days old → that kind has no
  entry: store cleared, row (or that kind's slot in the central cycle) absent.
- ≥ 9 days old → label switches to "… of the month" (§5b table). Both
  thresholds live on `WeeklySave` with an injected clock (§3a) — the ONLY
  place they're written.
- Central app: kinds drop out of the cycle individually; 1 live kind = no
  cycling; 0 = no row.
- Expiry is evaluated at render/refresh time (store `display(for:)` checks the
  clock); no live countdown needed.

## 11. Key generation (one-time, done by the implementer, on this machine)

1. In the scratchpad (NOT the repo), run a tiny `swift` script (macOS CryptoKit):
   generate `Curve25519.Signing.PrivateKey`, print private + public raw
   representations base64.
2. Embed the PUBLIC key in `WeeklySigning.publicKeyBase64`.
3. Write the PRIVATE key to `/Users/hsp/Desktop/luna-save-of-the-week-private-key.txt`
   (plain text: the base64 line plus one comment line saying what it is and
   where it's pasted — Settings → 5-tap diagnostics → Enter Weekly Key).
4. NEVER write the private key anywhere inside the repo/worktree, any commit,
   or the plan/docs. Verify with `git grep` of the first 8 chars of the private
   key base64 before the final commit.
5. Unit test pins that `publicKeyBase64` decodes into a valid
   `Curve25519.Signing.PublicKey`.

## 12. Manual deployment steps (report to the user at the end; NOT automatable)

1. Developer portal: create iCloud container `iCloud.com.hsanabria.luna`;
   enable the iCloud/CloudKit capability on all four app IDs and assign the
   container. (Known limitation — the ASC API can't do these; same class of
   step as the App Group memory note.)
2. CloudKit Dashboard (dev env schema then deploy to production):
   - `WeeklySave`: fields kind(String), url(String), date(Date/Time),
     signature(Bytes). World read; creator-only write is fine (only the
     key-holder's own account writes).
   - `WeeklySaveProposal`: same fields minus signature. Security role change
     REQUIRED: Authenticated → Create AND Write (the key-holder must be able
     to delete OTHER users' proposal records; CloudKit's default is
     creator-only write). Add queryable index on `recordName` +
     sortable on `date` (the proposals CKQuery needs them).
   - First-run alternative: running a device build signed with the real team
     will auto-create the schema in the dev environment on first write; the
     security-role and index edits are still manual.
3. Copy the private key from the Desktop file into your own installs via the
   diagnostics screen (once per device; the Keychain entry is shared across
   the four apps through the app-group access group).
4. Until step 1 exists, every CK call in the apps fails softly by design (§3e)
   — the row simply never appears; nothing else regresses.

## 13. Tests (LunaTests, hosted on central Luna; CloudKit always faked)

- `WeeklySigningTests`: sign→verify round trip; tampered url/date/kind fails;
  bundled public key decodes; `privateKeyMatchesBundledPublicKey` accepts a
  matching pair and rejects a fresh random key.
- `WeeklySaveStoreTests` (scratch `containerURL`, injected clock): persistence
  round trip; `display(for:)` nil at 30d+1s and present at 29d; month tier at
  9d; didChange posting; seen-proposal set.
- `WeeklySaveRefresherTests` (fake `WeeklyCloudDatabase`): new value → metadata
  fetched → store updated; same value → no store write, no metadata fetch;
  invalid signature → treated as absent (clears); expired → clears; per-app
  kind filtering (fetch asks only for `LunaApp.current`'s kinds — test via the
  fake's recorded requests); CK error → store untouched.
- `WeeklyRowHostTests`: row absent with empty store; appears with a display;
  central-app cycling logic — extract the pacer into a plain
  `WeeklyCyclePacer` type (injected clock/timer) and test: 2s advance, manual
  interaction latches auto off, foreground/leave-center resets the latch,
  single-kind = no cycling.
- `UtilCardTests` rewrite: drop the Lewis-Society pin + "always present"
  asserts; new: hidden with empty store / present with seeded store (inject
  store into the VC); tap routes the stored URL into the save handler; per-app
  subtitle labels (week + month tiers).
- Menu: extend the existing `cardContextMenuForTesting` coverage
  (ArticleCardsChromeTests.swift:495): non-key-holder sees "Propose…",
  key-holder (seeded keychain/fake store) sees "Promote…", failed saves see
  neither.
- Keep `KindCompositionRootTests` green — this feature must NOT touch
  `IngestKindProcessors`/`ShareKindPresenters` or add composition roots.

## 14. Docs & strings

- New `claudedocs/save-of-the-week.md`: architecture, record schema, key
  handling, expiry rules, the manual deployment steps (§12).
- Update `claudedocs/util-card.md` (weekly-row section) and the one CLAUDE.md
  sentence (§1). Update `claudedocs/settings.md` (new conditional category) and
  the BG-task list in whatever doc mentions the two existing ids.
- New user-facing strings go through `L10n.string` with catalog entries per
  `claudedocs/strings.md`.

## 15. Implementation order (commit-sized chunks, compile-gate each)

1. `LunaWeekly` module: model + signing + key store + local store + tests.
   (Generate the real keypair, §11, in this step.)
2. Config plumbing: Info.plist key, AppConfig accessor, four entitlements,
   pbxproj link edits. Compile all four apps
   (`xcodebuild build -scheme AllLunaApps` or per-scheme) — entitlement typos
   surface here.
3. CloudKit client + refresher + fakes + tests.
4. Util card: conditional row driven by the store, per-app/per-age labels,
   appear/disappear animations, metadata closure install, launch/foreground
   hooks. Rewrite UtilCardTests.
5. Eclipse replacement transition (§6).
6. Central-app cycling host + pacer + tests (§7).
7. Menus: shared factory + three deck integrations + tests (§8a).
8. Key-holder surface: diagnostics entry (§9), proposals screen, settings
   category, notifications, BG task (§8b).
9. Docs + strings sweep + private-key file on Desktop + final full-suite run.

## 16. Build & environment notes (read before building)

- Worktree: run everything from
  `/Users/hsp/Desktop/Luna/.claude/worktrees/save-of-the-week`. The
  `mkdir -p LunaLibraries/Tests/LunaURLClassificationTests` fresh-worktree
  workaround is no longer needed as of the August 2026 tree-shake, which
  deleted `LunaLibraries/Tests/` and all its `.testTarget` declarations
  entirely.
- Compile gate per commit:
  `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS
  Simulator' -derivedDataPath <DD> DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`.
  Full `LunaTests` suite ONCE at the end on a booted iOS 26.x simulator (see
  CLAUDE.md recipe; never pass `CODE_SIGNING_ALLOWED=NO`). Baseline
  2026-08-01: 2079 passed / 9 skipped / 1 known ArticleCardsChromeTests inset
  failure — any OTHER new failure is yours. "signal kill" = WebKit jetsam →
  re-run. `ArticleAudioEngineTests` may deadlock mediaserverd on this Mac →
  if it aborts, verify the rest with
  `-skip-testing:LunaTests/ArticleAudioEngineTests` and note it.
- A failure naming types that plainly exist (`cannot find type 'LunaApp'`) in
  files you didn't touch, with DIFFERENT files across runs, is the documented
  swift-build flake: re-run, don't wipe.
- pbxproj edits: only link-phase additions for LunaWeekly (no file deletions,
  so no membership-exception cleanup needed). New `Luna/` shell files are
  picked up by the synchronized group automatically and compile into ALL FOUR
  targets — keep them free of kind-module imports (LunaWeekly + universal
  modules only).
- Commit style: small logical chunks per §15, present-tense repo style (see
  `git log`), no bundling unrelated changes. Do not commit the plan-execution
  scratch files; DO commit this plan file and doc updates.
