# UI Testing — Seeding Harness, Snapshots, Navigation

In-process UI coverage for every screen: a deterministic **app-state seeding
harness** (reused by the in-app screenshot flow and the unit tests), **snapshot
tests** (render a VC, compare to a committed reference PNG), and **navigation/layout
tests** (assert the right control lands on the right screen with sane frames).

Everything runs in the existing **`LunaTests`** target (host app = `Luna.app`) — no
separate UI-test target, no external SPM dependency. Reference images live in
`LunaTests/ReferenceImages/`.

## Build & test

```bash
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  xcodebuild test -project Luna.xcodeproj -scheme Luna -configuration Debug \
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
| `Luna/UITestSeeder.swift` | Launch-arg driver: `-uiTestState <name>` / `-uiTestScreen <name>`. Exposes `isUITestLaunch`. |
| `Luna/UITestScreen.swift` | `UITestScreen` enum + `UITestScreenBuilder`: deep-links the window root to any named screen for the screenshot agent. DEBUG-only. |
| `ReaderKit/UITestFixtures.swift` | Also defines `UITestLaunch.isActive` (reads the harness launch args; usable from ReaderKit, which can't import the app target). |
| `Luna/SceneDelegate.swift` | Calls `UITestSeeder.applyIfNeeded()` + forces a UI-test root (deep-linked screen or reading list). |

### Named states (`UITestState`)

- **`empty`** — no items (empty-state rendering).
- **`mixed`** — one of **every** save type: ready article, opened article,
  needsCaptcha (locked) article, failed article, friend-shared article, PDF
  platform posts, a normal price tracker, and an **alerting** price tracker.
- **`priceTracking`** — 3 trackers (steady, dropped/alerting, never-refreshed).

### In-app seeding (screenshot agent)

Launch the app with `-uiTestState mixed`. The seeder wipes + seeds
`ReadingListStore.shared`, disables animations, **pins the reading-list sectioning
clock** to `UITestFixtures.baseDate` (`UITestSeeder.sectioningNow`) so fixed-date
fixtures land in the **Reading** section instead of Archive, **resets persisted list
prefs** (selected filter → All, default collapsed set), and `SceneDelegate` forces
the right root VC. No-op (production paths unchanged) when the arg is absent or in
release. Verified live: `simctl launch com.hsanabria.luna -uiTestState mixed`.

### Screen deep-linking (`-uiTestScreen <name>`)

For capturing a specific screen across many device sizes without fragile
coordinate-tapping, launch with `-uiTestScreen <rawValue>` (seeds `.mixed`
automatically if no `-uiTestState` given). `UITestScreenBuilder` builds that screen
(or presents it over a host) as the window root using the **same construction seams
the snapshot tests use**. Cases: `friends`, `friendDetail`, `settings`,
`priceTrackingEditor`, `readerScroll`/`readerHighlight`/`readerRSVP`/
`readerOriginal`/`readerInlineHeader`/`readerNested`/
`shareMediaPlatform`. Share/action-extension screens are hosted in-app (the
real share sheet can't be driven on a simulator).

### Suppressing simulator debug hooks in captures

The simulator-only debug tap targets (reading-list row ellipsis, reader "Split
High/Low") overlay real content. They are gated on
`!UITestLaunch.isActive`, so they vanish for any `-uiTestState`/`-uiTestScreen`
launch (the screenshot agent) but remain for interactive
simulator automation (no launch arg) and for unit/snapshot tests (which build VCs
directly, so reference images are unaffected).

### Test seeding

```swift
UITestSupport.seedSharedStore(.mixed)       // seeds ReadingListStore.shared
// ... build a VC that reads .shared ...
UITestSupport.wipeSharedStore()             // in tearDown
```

`UITestSeeder.seedSharedStore(_:)` and `UITestSeeder.seed(_:into:)` are the same
seam the app uses. Read items back from `ReadingListStore.shared.items()` when you
need the on-disk `contentFileName` (the in-memory fixture copies don't carry it).

## Snapshot testing (`LunaTests/SnapshotTesting.swift`)

`SnapshotTesting.assertSnapshot(of: vc, named: "…")` hosts the VC in a fixed-size
window (393×852 @1x, light mode), runs a real layout pass, rasterizes via
`view.layer.render(in:)` (NOT `drawHierarchy` — that captures blank for off-screen
test windows), and compares to `ReferenceImages/<name>.png`. Pixel diff allows
`pixelTolerance` per-channel AA slack and a `precision` fraction of differing pixels
(defaults 24 / 2%). On mismatch it writes `<name>.actual.png` (gitignored) next to
the reference for inspection.

## Navigation / layout (`LunaTests/UITestSupport.swift`)

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
| `ReadingListScreenTests` | each state + each filter segment | row tap → reader / tracker editor / archive reader / openItem (video, platform); settings/friends buttons; table layout |
| `ReaderScreenTests` | scroll / highlight / rsvp / inline-header / standalone scroll + rsvp | mode switcher swaps hosted child VC; reader child in-bounds |
| `PriceTrackingScreenTests` | — | price-editor layout/store list |
| `SocialAndSeederTests` | — | friends-screen layout; seeder contract (every state ↔ fixture, mixed covers all types, deterministic ids, wipe) |

### Extension surface fixture (the `ExtensionHost` / `ShareSurfaceDriver` seam)

The share/action extension's ingest+present flow is extracted into the host-agnostic
**`ShareSurfaceDriver`** (`ShareKit/`), driven by an injected **`ExtensionHost`** (the only
seams the real `NSExtensionContext` harness provides — `isActionExtension`/`readerMode`,
`presentModally`, `confirmSavedThenComplete`, `autoDownloadThenComplete`, `failOrComplete`).
A `FakeExtensionHost` records what the driver asked for, so the whole "URL → pipeline →
Outcome → present" flow is asserted in `LunaTests` without the real share sheet (which a
simulator can't drive). The real `ShareViewController` is a thin `ExtensionHost` adapter.

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
