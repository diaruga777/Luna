# UI Testing — Seeding Harness, Snapshots, Navigation

In-process UI coverage for every screen: a deterministic **app-state seeding
harness** (reused by the in-app screenshot flow and the unit tests), **snapshot
tests** (render a VC, compare to a committed reference PNG), and **navigation/layout
tests** (assert the right control lands on the right screen with sane frames).

Everything runs in the existing **`ClipTests`** target (host app = `Clip.app`) — no
separate UI-test target, no external SPM dependency. Reference images live in
`ClipTests/ReferenceImages/`.

## Build & test

```bash
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  xcodebuild test -project Clip.xcodeproj -scheme Clip -configuration Debug \
  -destination 'platform=iOS Simulator,id=AA3C058C-9671-4448-9F53-510DED654FE5' \
  -derivedDataPath /tmp/clipDD-uitests 2>&1 | tail -50
```

Record / re-record reference images by prefixing `RECORD_SNAPSHOTS=1`. First run of
a new snapshot test auto-records its baseline (then commit it).

## Seeding harness (DEBUG-only)

Deterministic fixtures with **stable ids** (seed-derived UUIDs) and **stable dates**
(offsets from `UITestFixtures.baseDate` = 2025-01-15 12:00 UTC), so renders are
byte-reproducible. No `Date()`/`UUID()` at fixture build time.

| File | Role |
|---|---|
| `ReaderKit/UITestFixtures.swift` | `UITestState` enum + `UITestFixtures` builders (pure, shared by app + tests). |
| `ReaderKit/ReadingListItem.swift` | DEBUG `init(seed:…)` fixture initializer + `deterministicUUID(from:)`. |
| `ReaderKit/ReadingListStore.swift` | DEBUG `seedForTesting(items:contents:)` / `wipeForTesting()`. |
| `Clip/UITestSeeder.swift` | Launch-arg driver: `-uiTestState <name>` / `-uiTestOnboardingStep <n>`. |
| `Clip/SceneDelegate.swift` | Calls `UITestSeeder.applyIfNeeded()` + forces a UI-test root. |

### Named states (`UITestState`)

- **`empty`** — no items (empty-state rendering).
- **`mixed`** — one of **every** save type: ready article, opened article,
  needsCaptcha (locked) article, failed article, friend-shared article, PDF
  document, YouTube, X / Bluesky / Reddit / TikTok / Instagram / Facebook posts,
  Spotify music, Apple podcast, a normal price tracker, an **alerting** price tracker.
- **`catchUpEligible`** — 12 unread ready articles (catch-up dot + queue).
- **`priceTracking`** — 3 trackers (steady, dropped/alerting, never-refreshed).

### In-app seeding (screenshot agent)

Launch the app with `-uiTestState mixed` (optionally `-uiTestOnboardingStep 0` to
show onboarding instead of the list). The seeder wipes + seeds
`ReadingListStore.shared`, disables animations, **pins the reading-list sectioning
clock** to `UITestFixtures.baseDate` (`UITestSeeder.sectioningNow`) so fixed-date
fixtures land in the **Reading** section instead of Archive, **resets persisted list
prefs** (selected filter → All, default collapsed set), and `SceneDelegate` forces
the right root VC. No-op (production paths unchanged) when the arg is absent or in
release. Verified live: `simctl launch com.hpiddy.clip -uiTestState mixed`.

### Test seeding

```swift
UITestSupport.seedSharedStore(.mixed)       // seeds ReadingListStore.shared
// ... build a VC that reads .shared ...
UITestSupport.wipeSharedStore()             // in tearDown
```

`UITestSeeder.seedSharedStore(_:)` and `UITestSeeder.seed(_:into:)` are the same
seam the app uses. Read items back from `ReadingListStore.shared.items()` when you
need the on-disk `contentFileName` (the in-memory fixture copies don't carry it).

## Snapshot testing (`ClipTests/SnapshotTesting.swift`)

`SnapshotTesting.assertSnapshot(of: vc, named: "…")` hosts the VC in a fixed-size
window (393×852 @1x, light mode), runs a real layout pass, rasterizes via
`view.layer.render(in:)` (NOT `drawHierarchy` — that captures blank for off-screen
test windows), and compares to `ReferenceImages/<name>.png`. Pixel diff allows
`pixelTolerance` per-channel AA slack and a `precision` fraction of differing pixels
(defaults 24 / 2%). On mismatch it writes `<name>.actual.png` (gitignored) next to
the reference for inspection.

## Navigation / layout (`ClipTests/UITestSupport.swift`)

- `UITestSupport.host(vc)` → hosts in a window, forces layout, returns the window
  (keep it alive for the assertions). Returns the window — `_ = window` at the end.
- `LayoutAssertions.assertVisibleAndInBounds(view, in: container)` — not hidden,
  non-zero, intersects container bounds.
- `LayoutAssertions.assertNoOverlap(a, b)`.
- Routing is asserted by invoking the **real** seam: `ReadingListViewController.open(_:presenter:)`
  / `openItem(_:presentingFrom:)`, a table's `didSelectRowAt`, a control's
  `sendActions(for:)`, or a private `@objc` handler via `perform(Selector(("…")))`,
  then checking `nav.topViewController is X` / `presentedViewController is X`.

## What's covered

| Test file | Snapshot | Navigation / layout |
|---|---|---|
| `ReadingListScreenTests` | each state + each filter segment | row tap → reader / tracker editor / archive reader / openItem (video, platform); settings/friends/catch-up buttons; table layout |
| `SettingsScreenTests` | menu + all 12 subscreens | each top-level row → correct subscreen; email/boox → AutoSendBySource |
| `OnboardingScreenTests` | every step (username + setup steps) | flow root shows username first; step buttons in-bounds |
| `ReaderScreenTests` | scroll / highlight / rsvp / inline-header / standalone scroll + rsvp | mode switcher swaps hosted child VC; reader child in-bounds |
| `CatchUpAndPriceScreenTests` | catch-up cards (eligible + mixed/locked); price editor (normal + alerting) | catch-up + price-editor layout/store list |
| `ShareKitScreenTests` | action-reader loading; SavedNonTextual (YouTube + platform) | Done item; layout sanity |
| `SocialAndSeederTests` | — | friends-screen layout; seeder contract (every state ↔ fixture, mixed covers all types, deterministic ids, wipe) |

### Not snapshotted (flagged, with reason)

- **Friends screen** — renders a per-device keychain-identity QR code (not
  pixel-stable). Covered by a layout-sanity assertion + the reading-list "friends
  button" navigation test instead.
- **`SplitWebOverlayViewController`** — a transition overlay needing a live cut
  position + rendered top/bottom halves from the host scroll reader + a WKWebView
  (no network in tests). Covered by the scroll reader's simulator "Split High/Low"
  hooks (see `simulator-testing.md`).
- **Replays screen** (`ReplaysViewController`) — lists the device's real accumulated
  diagnostic replays (live save URLs + wall-clock timestamps), not pixel-stable.
  Covered by a layout-sanity assertion + the Settings → Diagnostics nav test.
- **WKWebView content** (archive reader, platform embeds, share-reader after fetch)
  — no network in tests; only the deterministic loading/chrome state is snapshotted.

## Adding a new state

1. Add a `case` to `UITestState` (ReaderKit/UITestFixtures.swift) and return its
   `Fixture` from `UITestFixtures.fixture(for:)` using `ReadingListItem(seed:…)` +
   `sampleArticleContent` (stable dates via `UITestFixtures.ago(days:…)`).
2. Reference it in a test via `UITestSupport.seedSharedStore(.newState)`.
3. The screenshot agent gets it for free via `-uiTestState newState`.

## Adding a new snapshot

1. Build the VC (seed `.shared` first if it reads the store), then
   `SnapshotTesting.assertSnapshot(of: vc, named: "screen-name")`.
2. Run once with `RECORD_SNAPSHOTS=1` to write the reference; eyeball
   `ReferenceImages/screen-name.png`; commit it.
3. Subsequent runs assert equality. To intentionally update, re-record with
   `RECORD_SNAPSHOTS=1` and commit the new reference.
