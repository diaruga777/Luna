# App-shell audit — ReadingList / CatchUp / Reader (cards) / Settings / Diagnostics / top-level `Luna/`

Scope: everything directly under `Luna/` EXCEPT `Luna/Downloader/`, `Luna/MiniPlayer/`, `Luna/Mail/`,
`Luna/Social/` (owned by other agents). 33 files read in full:

- `Luna/ReadingList/ReadingListViewController.swift` (1918 lines)
- `Luna/CatchUp/{CatchUpViewController,CatchUpCardView,CatchUpDeleteReadView,CatchUpSubviews}.swift` (4 files)
- `Luna/Reader/{ArticleCardsViewController,ArticleScrubPreview,ArticleSourceBadge,SourceIconCache}.swift` (4 files, 1091-line VC)
- `Luna/Settings/*.swift` (11 files, incl. 4 screens nested inside `SettingsViewController.swift`)
- `Luna/Diagnostics/DiagnosticsViewController.swift`
- 12 loose top-level files: `AppDelegate`, `SceneDelegate`, `AppSurfaceConfig`, `ArticleSpotlightIndexWiring`,
  `AudioPlaybackWiring`, `AudioScriptPipelineWiring`, `BundledShortcut`, `OnboardingGuideVideo`,
  `SystemSettingsLink`, `UITestFixtures`, `UITestScreen`, `UITestSeeder`

Note: CLAUDE.md's "Module structure" section mentions "the App Intent **definitions** (`Luna/Intents/*`)"
as part of the app shell. That directory does **not exist** in this worktree — only
`Luna/Mail/Intents/` (Mail's scope) exists. Either the doc is stale or the definitions live elsewhere;
flagged for the doc owner, not fixed here (read-only audit).

Read against `CODE_REVIEW_PLAN.md` and `PERF_REVIEW_PLAN.md` headers first; nothing below duplicates an
item those list as fixed or deliberately deferred (dead-code sweep, retain cycles, store-cache, batched
deletes, reload coalescing, etc. are already done — this audit looks for what's accumulated since).

---

## 1. Structure map

### ReadingList

**`ReadingListViewController.swift`** (1918 lines) — the combined/per-surface sectioned list: pasteboard
suggestion row, FIFO sections (Reading/Read/Archive/Error/priceAlert/priceTracking), Articles/Media/Price
filter, edit-mode multi-select + drag-anywhere reorder, row long-press menu, item open routing (reader /
archive-unlock / platform embed), media-to-Photos, send-to-friend/Kindle/eBook.
Public surface: `init(surface:)`, `static rendersAsReader(_:)`, `static normalizedTypedURL(_:)`,
`static let filterDefaultsKey/collapsedDefaultsKey`, `func open(_:presenter:transitionSourceView:)`,
`@discardableResult func openItem(_:presentingFrom:)`, `func configureItemCell(_:for:)`,
`@objc func friendsTapped()`, `@objc func settingsTapped()`, `@objc func catchUpTapped()`.
Conforms to `CatchUpRouting` (extension in `CatchUpViewController.swift`) and
`UITableViewDragDelegate`/`UITableViewDropDelegate`.
Used by: `SceneDelegate.makeMainRootViewController()` (Downloader/PriceTracker root... actually
PriceTracker root), `SceneDelegate.openReader`, `SceneDelegate.uiTestRootViewController`,
`UITestScreen.swift` (5 call sites), `LunaTests/CatchUpAndPriceScreenTests.swift` (as router + `.open`
harness), `CatchUpViewController.swift` (`CatchUpRouting` conformance).
`configureItemCell` and `open(_:presenter:transitionSourceView:)` are non-private with doc comments
saying they're "shared with the search screen" / used by "the reading list, or the search screen" — **no
search screen exists anywhere in the repo** (see Comment hygiene, §2.6). Only call sites are internal to
this file, `SceneDelegate`, and one test.

### CatchUp

**`CatchUpViewController.swift`** (763 lines) — the Slack-style unread-catch-up modal: swipe-card deck
over the reading list's unread items, end screens (voice-install nudge → delete-read prompt → done+undo).
Public: `init(unread:router:)`; protocol `CatchUpRouting` (defined here, adopted by
`ReadingListViewController`). Used by `ReadingListViewController.catchUpTapped()`,
`UITestScreen.swift` (2 call sites: `.catchUp`, `.priceCatchUp`), `LunaTests/CatchUpAndPriceScreenTests.swift`.

**`CatchUpCardView.swift`** — the swipeable card chrome: pan-gesture-driven tint/badge/rotation, fly-off
commit, spring-back, rasterize-during-transform. `Action` enum `{keep, bump, archive, unlock}`. Used only
by `CatchUpViewController`.

**`CatchUpDeleteReadView.swift`** — the "delete read items?" mini table (reuses `ReadingListItemCell`),
all-selected-by-default. Used only by `CatchUpViewController`.

**`CatchUpSubviews.swift`** (585 lines, 5 types) — `CatchUpMessageView` (end-screen glyph/text incl. the
hand-drawn `CAShapeLayer` checkmark celebration), `CatchUpCardHeader` (date/sender strip, also called by
`ReaderViewController`'s inline header via `CatchUpCardHeader.text(for:)` — cross-library reuse of a pure
static func, fine), `CatchUpMediaCardBody`, `PriceTrackerStoreRowsView`, `CatchUpPriceTrackerCardBody`.
All used only by `CatchUpViewController`/`CatchUpCardView`.

### Reader (cards)

**`ArticleCardsViewController.swift`** (1091 lines) — Reader's root screen: `CardCarouselViewController`
(from `LunaDesignSystem`) driving one full-live-reader-embedded card per article, chrome fade on
immersion, RSVP long-press preview, pasteboard leading card. Public: `func openExternally(_:)` (used by
`SceneDelegate.openReader`); conforms to `CardCarouselDataSource`/`CardCarouselDelegate`. Contains 3
private nested types: `PasteboardCardContentViewController`, `ReaderCardContentViewController` (~340
lines — the bulk of the file's complexity), `EmptyArticlesView`.
**Zero references anywhere in `LunaTests/`** (see §3).

**`ArticleScrubPreview.swift`** — `ArticleScrubPreviewText` (pure excerpt-around-word-index logic, unit
tested by `ArticleScrubPreviewTextTests.swift`) + `ArticleScrubPreviewViewController` (the scrub-strip
preview card). Used by `ArticleCardsViewController.carousel(_:previewContentControllerForCardAt:)`.

**`ArticleSourceBadge.swift`** — pure mapping `ReadingListItem → CarouselSourceBadge` fallback (sender
initials / mail / doc / globe). Unit tested by `SourceBadgeTests.swift`. Used only by
`ArticleCardsViewController`.

**`SourceIconCache.swift`** — favicon memory+disk+negative cache, in-flight de-dup. Used only by
`ArticleCardsViewController.carousel(_:loadSourceBadgeForCardAt:)`. No dedicated test file (only
exercised transitively, if at all).

### Settings (11 files)

**`SettingsViewController.swift`** (497 lines, 4 types) — top-level settings menu (`SettingsViewController`)
+ 3 nested screens: `ReaderSettingsScreen` (RSVP speed/serif/text-size/accent), `ReadingListSettingsScreen`
(reading-time/progress + preload depth/Wi-Fi), `ShortcutSettingsScreen` (Safari-suggestion mode + Action
Button shortcut). Also hosts the shared `UITableViewController` extension (`makeToggle(isOn:action:)`,
`presentInfoAlert`) used across every settings screen in this directory. Tested (one row) by
`InteropSettingsTests.testSharedSettingsRowShowsEntitlementAndOpensPaywall`/`testFriendsIsASettingsSubpage`.

**`AppearanceSettingsScreen.swift`** — theme (System/Light/Dark) + Reader-only Lunar Eclipse toggle.

**`AudioSettingsScreen.swift`** — autoplay-next toggle, Apple-Intelligence cleanup toggle, link to Voice.

**`AutoDownloadSettingsScreen.swift`** (276 lines) — Downloader-vs-sibling-app branch: retention/network/
shortcuts/completion/preview sections (Downloader) vs. auto-download + per-platform toggles (siblings).
Underlying model (`AutoDownloadSettings`) tested by `AutoDownloadSettingsTests.swift`; the screen itself is not.

**`AutoSendBySourceScreen.swift`** — per-destination (Kindle/friend) auto-send source toggles.

**`DoubleSaveRecipientsScreen.swift`** — double-save friend-recipient picker.

**`EmailAndKindleSettingsScreen.swift`** (409 lines) — largest settings screen: Luna account, Kindle,
double-save, mail-import allow-list + subject filters, all in one 5-section table.

**`InstalledAppMarkers.swift`** — App-Group "which sibling apps are installed" markers (read by native
Safari-extension handlers via raw key strings). `isInstalled(_:)` used by `Luna/Mail/Intents/
ProvideContextIntent.swift`; `key(for:)` has **zero call sites** anywhere (only referenced in doc comments
— see §2.5 dead code).

**`SafariSuggestionSettings.swift`** — `SafariSuggestionMode` enum + App-Group-backed setting, read by
`ShortcutSettingsScreen`.

**`VoiceInstallLink.swift`** — deep-link to iOS Settings for enhanced voices. Used by
`VoiceSettingsScreen` and `CatchUpViewController.secondaryTapped()`.

**`VoiceSettingsScreen.swift`** — informational enhanced-voice status + install link.

### Diagnostics

**`DiagnosticsViewController.swift`** — read-only log viewer + share/clear, custom `NavHeaderBar` instead
of the nav-bar. Used by `SettingsViewController` category list. Underlying `DiagnosticLog` model tested by
`DiagnosticLogTests.swift`; the VC itself is not.

### Top-level loose files

**`AppDelegate.swift`** — launch wiring: 9 injected-closure DI seams (§2.1), BGTask registration/scheduling
for mail-fetch (universal) and price-refresh (Price-Tracker-only), notification delegate, one
`.readingListChanged` observer that bundles two unrelated follow-ups (documented as deliberate).

**`SceneDelegate.swift`** — window/root construction per surface, onboarding gate, URL routing
(`lunareader://read`, interop deep link), pending-route stashing (read-URL / interop / friend-prompt /
notification-tap), UI-test root override.

**`AppSurfaceConfig.swift`** — `current: AppSurface` from bundle-id suffix; `AppSurface.storageIdentifier`.
Single source of truth, widely used (grep hits in every scope file).

**`ArticleSpotlightIndexWiring.swift`** — Spotlight index sync, debounced on `.readingListChanged`,
main-app-only. Self-contained; installed once from `AppDelegate`.

**`AudioPlaybackWiring.swift`** — Reader-only install of `AudioPlaybackCenter.shared.nextItemProvider` +
`ReaderAudioLauncher.center`; also hosts `AudioQueueRule` (pure, tested by `AudioQueueRuleTests.swift`).

**`AudioScriptPipelineWiring.swift`** — universal install of `AudioPlaybackCenter.shared.scriptProvider`
+ `scriptPrefetchHandler`.

**`BundledShortcut.swift`** — shortcut-file share-sheet installer. Used by `ShortcutSettingsScreen` and
(per its own doc comment) onboarding.

**`OnboardingGuideVideo.swift`** — muted looping guide clip + PiP hand-off, used by onboarding (Social,
out of scope) but the type itself lives here.

**`SystemSettingsLink.swift`** — best-effort Settings deep-link cascade. `open()` used by... (see §2.5,
not found in this scope — likely Social); `openActionButton()` used by `Luna/Social/OnboardingFlow.swift`.

**`UITestFixtures.swift` / `UITestScreen.swift` / `UITestSeeder.swift`** — DEBUG-only deterministic
fixture/seeding/screen-deep-link harness for snapshot tests and the screenshot agent. `ActionHostViewController`
in `UITestScreen.swift` has **zero instantiation sites** (§2.5).

---

## 2. Findings

### 2.1 Stored-callback / injected-closure communication

**AppDelegate injection points (the documented "cross-tier wiring" pattern):**

| Seam (file:line) | Target | Cluster? | Assessment |
|---|---|---|---|
| `AppDelegate.swift:73` `PriceTrackingViewController.defaultSaveAsArticle` | 1 closure on that VC | no | Legitimate — extensions need it too, closure is the only DI a static type in a lower-layer-adjacent target can take. |
| `AppDelegate.swift:82` `ReadingListIngestor.interopPromptPresenter` | 1 closure | no | Legitimate — `LunaReadingList` can't present UI. |
| `AppDelegate.swift:92` `DiagnosticLog.exportIdentityProvider` | 1 closure | no | Legitimate — `LunaStorage` can't see `EmailAccountStore`'s consumer-facing address format. |
| `AppDelegate.swift:98` `SendToFriendSheet.accountSetupLauncher` | 1 closure | no | Legitimate. |
| `AppDelegate.swift:105` `ArticleEmailTransportProvider.make` | 1 closure (factory) | no | Legitimate — nil in extensions is an intentional no-op gate. |
| `AppDelegate.swift:134` `VoiceFirstRunPrompt.openVoiceSettings` | 1 closure | no | Legitimate. |
| `AudioPlaybackWiring.swift:29` `AudioPlaybackCenter.shared.nextItemProvider` | **3rd of a cluster** | **yes** | See below. |
| `AudioPlaybackWiring.swift:43` `ReaderAudioLauncher.center` | config value (not a callback) | no | Fine — it's a reference assignment, not a callback. |
| `AudioScriptPipelineWiring.swift:18-22` `AudioPlaybackCenter.shared.scriptProvider` + `scriptPrefetchHandler` | **cluster** | **yes** | See below. |

**Cluster worth consolidating:** `AudioPlaybackCenter` (in `LunaAudioPlayback`, outside this scope) ends
up with **3 stored closures** (`nextItemProvider`, `scriptProvider`, `scriptPrefetchHandler`) set from two
different app-shell installers (`AudioPlaybackWiring.swift` Phase 2, `AudioScriptPipelineWiring.swift`
Phase 4) at the same launch moment, always together, always Reader-relevant. A single delegate protocol
(e.g. `AudioPlaybackCenterDataSource { nextCandidate() -> QueueCandidate?; script(for:content:) -> AudioScript;
prefetch(item:content:) }`) implemented by one app-shell composition type and assigned once
(`AudioPlaybackCenter.shared.dataSource = ...`) would replace 3 independently-nil-able closures with one
non-optional conformance — removing the possibility of one being installed and another forgotten. This
touches `LunaAudioPlayback` (outside my scope) as well as both Wiring files (in scope); flagged, not fixed.

**Not a cluster (verified, no action needed):** every other AppDelegate seam is a single closure on a
distinct target type — genuinely one dependency each, not a family that would benefit from a shared
protocol. `DiagnosticLog.export*` is one closure (`exportIdentityProvider`); "export*" in CLAUDE.md refers
to the naming convention (`exportIdentityProvider`/`exportFile()`), not multiple stored closures.

**Within-scope closure clusters (not AppDelegate-level, but same pattern):**

- `ArticleCardsViewController.swift:791-794` — `ReaderCardContentViewController` exposes **4** stored
  closures/providers set together, once, from the single call site
  `ArticleCardsViewController.carousel(_:contentControllerForCardAt:)` (lines 539-566):
  `onImmersionChange`, `onReaderReady`, `onInlineReaderChange`, `inlineReaderCardFrameInWindowProvider`.
  All 4 are set in the same 25-line block, all consumed only by the same host. This is the clearest
  delegate-protocol candidate in the whole scope: a `ReaderCardContentDelegate` (3 push methods + 1 pull
  method, or split the pull side into a separate `frameProvider` since it's not push/notify) would
  collapse 4 optional `var`s into 1 `weak var delegate:` — same call sites, no behavior change. **Effort: M.**
- `CatchUpCardView.onAction` (single closure, one-shot per card instance) — fine, genuine one-shot.
- `CatchUpDeleteReadView.onSelectionChanged` (single closure) — fine.
- `CatchUpPriceTrackerCardBody.onChangeThreshold` (single closure) — fine.
- `ReadingListViewController.pendingContextMenuAction` (`:200`) — not cross-component; a same-object
  deferred-action buffer (documented rationale: can't present while a context menu is collapsing). Fine.

### 2.2 View/container boundary violations

- **`ReadingListViewController` reaches directly into cell/menu construction it should delegate.**
  `rowMenu(for:at:)` (`:1606-1733`, ~130 lines) builds a `UIMenu` with 8+ possible actions by hand-testing
  `item.priceTracker`/`canShareToFriends`/`isShareable`/`isPlatformItem`/`readState` — this is *content
  policy* (which actions apply to which item shape) living inside the *view controller*, not a
  `ReadingListItemCell` or a policy object. It duplicates knowledge already encoded on `ReadingListItem`
  (the various `is*`/`can*` computed properties) into a giant switch, and nothing else can reuse "what
  actions apply to this item" (e.g. a hypothetical multi-select batch-action bar would have to re-derive
  it). Not currently a *bug* — just a container reaching past its own concern.
- **`ArticleCardsViewController`'s `ReaderCardContentViewController`** (nested, `:782-1056`) owns real
  reader-lifecycle logic that arguably belongs one layer down: `observeReaderScrollViews`,
  `handleOffsetChange` (a bespoke direction-accumulation algorithm, `:1009-1036`), and
  `rsvpControllers`/`scrollViews` (recursive view-tree walks, `:1038-1055`) are generic "detect reading
  direction / find nested scroll views and RSVP controllers under an arbitrary reader" concerns that have
  nothing to do with being a *carousel card* specifically — they'd work identically hosted anywhere. Right
  now they're inseparable from the card (private nested class), so nothing else in the app can reuse
  "is the user scrolling down through this reader" (e.g. a future non-carousel reader chrome would
  reimplement it). See §2.4 extraction seam.
- **`CatchUpViewController.populate(_:with:)`** (`:315-377`) directly constructs 3 completely different
  card-body view hierarchies (price tracker / embedded `ReaderViewController` / media-or-locked) inline in
  the view controller rather than delegating to a factory — the VC knows the internal layout rules of all
  three body kinds (anchor to `card.contentContainer.topAnchor` vs `header.bottomAnchor`, etc.).

### 2.3 Duplicated or disjoint-but-related logic

- **Triplicated archive-unlock presentation** (highest-value duplication in this scope). The
  "present `ArchiveWebReaderViewController`, wire `onClose`/`onOpenInBrowser`/`onExtracted`, dismiss and
  reopen the now-`.ready` item" sequence is implemented **three separate times**, each ~25-30 lines,
  divergent only in trivial ways:
  - `ReadingListViewController.presentArchiveReader(for:articleURL:presenter:)` (`:1437-1469`)
  - `ArticleCardsViewController.presentArchiveReader(for:articleURL:)` (`:497-520`)
  - `CatchUpViewController.presentUnlock(_:)` (`:442-463`) — same shape, differs only in
    `modalPresentationStyle = .fullScreen` and calling `reloadCurrentCard()` instead of reopening in a reader.
  A shared helper (e.g. `ArchiveUnlockFlow.present(item:articleURL:store:from:onUnlocked:)` returning
  through a completion once extraction succeeds) would let all three callers supply just "what happens on
  success," eliminating ~70 lines of near-identical wiring. **Effort: M.**
- **Two independent pasteboard-URL-detection state machines.** `ReadingListViewController` tracks
  `pasteboardCandidate`/`evaluatingPasteboardURL`/`lastCheckedPasteboardChangeCount` and calls
  `PasteboardSuggester.shared.evaluate(urlString:)` for a rich preview (thumbnail/title/platform).
  `ArticleCardsViewController` separately tracks `pasteboardURL`/`renderedPasteboardURL`/
  `consumedPasteboardChangeCount` and only detects *whether* a URL pattern exists
  (`detectPatterns(for: [.probableWebURL])`), rendering a plain placeholder card instead of a preview. Both
  re-derive "did the pasteboard's `changeCount` actually change" independently, and both call
  `URLUnwrapper.ingestURL` at save time. The UX is legitimately different (row-with-preview vs.
  leading-card-placeholder), so this is *disjoint-but-related* rather than a mechanical duplicate — but the
  low-level "has the pasteboard changed to a new ingestable URL since I last looked" primitive is
  reimplemented twice with two different change-count variables. Lower-value than the archive-unlock case
  because unifying it would require a product decision (does Reader's card carousel get a real preview?).
- **Two empty-state idioms for the same conceptual state.** `ReadingListViewController.emptyStateView`
  (`:555-584`, lazy `UIView` + centered label, only for `.reader`/`.priceTracker` surfaces) vs.
  `ArticleCardsViewController.EmptyArticlesView` (`:1060-1091`, private class, icon + title + subtitle
  stack). Both mean "this surface currently has nothing saved" but are built via unrelated code with
  unrelated visual language (plain label vs. icon+title+subtitle). Not mechanically duplicated (worth
  merging only if product wants one visual treatment); flagged as disjoint-but-related per the prompt.
- **Two `makeToggle` helpers.** `SettingsViewController.swift:18` defines a shared
  `UITableViewController.makeToggle(isOn:action:)` (Selector-based) used by every other settings screen in
  this directory. `AutoSendBySourceScreen.swift:91` defines a private, differently-signed
  `makeToggle(isOn:onChange:)` (closure-based) used only in that one file. Minor — folding the
  closure-based overload into the shared extension (so it's `UITableViewController.makeToggle(isOn:onChange:)`)
  would remove the one-off private duplicate and make the closure flavor available to every future screen.
  **Effort: S.**
- **Store-reload "did anything actually change" logic, reinvented twice.** `ReadingListViewController`
  uses the shared `ReadingListDiff` (id-keyed section/row diff) in `applyReloadedGroups`/`applyFilteredGroups`.
  `ArticleCardsViewController.reload()` (`:436-459`) instead builds its own ad hoc `fingerprint: [String]`
  (`"\(id)|\(title)|\(state)|\(thumbnailFileName)"` per item + a leading pasteboard marker) and does a
  flat `!=` comparison to short-circuit. Both exist to solve the same problem ("don't churn the UI on a
  no-op notification") with two different techniques. Not a bug, and the carousel's model (index-based,
  not section-based) doesn't map cleanly onto `ReadingListDiff`'s section/row shape — but worth knowing
  these are two independently-maintained mechanisms for the same purpose if either needs a fix.
- **Five `X()`/`X(items:)` wrapper pairs in `ReadingListViewController`** (`updateFilterVisibility`,
  `updateCatchUpButton`, `buildGroups`, `visibleFilters`, `presentPendingSendFailureNoticeIfNeeded`) — each
  no-arg form just calls `store.items()` and forwards. This is a deliberate, already-reviewed idiom (see
  PERF_REVIEW_PLAN.md item 7, "one store read per reload() instead of one per helper") — not a finding,
  noted here only so it isn't mistaken for accidental duplication when reading the file.

### 2.4 Overly complex code — region maps + extraction seams

**`ReadingListViewController.swift` (1918 lines).** Internal regions (by `// MARK:` and de facto grouping):

| Lines | Region | Extraction seam |
|---|---|---|
| 1-207 | Properties/init/state (surface, filter/collapsed UserDefaults, header views, groups model) | — |
| 209-322 | Lifecycle + pinned-header inset math (`updateHeaderInsets`, layout passes) | Could become a small `PinnedHeaderInsetController` — self-contained scroll-offset math, no other state touched. **S.** |
| 324-472 | **Pasteboard suggestion** (`checkPasteboard`, `surfaceAllows`, `dropPasteboardRow`, `savePasteboardCandidate`, `previewPasteboardCandidate`, `scheduleReload`) | Extract to `PasteboardSuggestionController` owning the 3 pasteboard `var`s, exposing `evaluate()`/`save()`/`preview()`/`drop()`, calling back through a small delegate/closure pair (`onChange: () -> Void`, `onOpenTransient: (ReadingListItem) -> Void`). **M** — ~150 lines, well-isolated already. |
| 474-646 | **Reload/diffing** (`reload`, `applyReloadedGroups`, `buildGroups(items:)`, `displayItem(for:)`, `emptyStateView`/`updateEmptyState`) | `buildGroups` is already a pure function of `(items, filter, surface, pasteboard state)` → could move to a free function/struct (`ReadingListGroupBuilder`) fully unit-testable without a `UIViewController`. **M.** |
| 648-736 | **Filter** (`priceTrackerSavedInteractively`, `filterChanged`, `applyFilteredGroups`, `reconfigurePersistingCells`) | `reconfigurePersistingCells` and the diff-apply blocks in `applyFilteredGroups`/`applyReloadedGroups` are near-identical `performBatchUpdates` shapes (see also §2.3) — could share one `applyGroupDiff(old:new:rowAnimation:)` helper. **S.** |
| 738-801 | **Filter bar UI** (`filterControl`/`filterScrollView`/`filterWidthConstraint`, `visibleFilters`, `updateFilterVisibility`, `measureFilterNaturalWidth`, `applyFilterWidth`) | Self-contained enough to become a `ReadingListFilterBar: UIView` (owns its own scroll view, segmented control, width math) exposing `selectedFilter`/`onChange`/`setOptions(_:)`. **M.** |
| 803-874 | Pull-to-refresh, friends nav, catch-up button + badge | Small; leave in place. |
| 876-1017 | **Header controls + table-header construction** (`setDefaultHeaderControls`, `rebuildTableHeader` — 90 lines of manual Auto Layout for 3 header shapes, `setEditing`) | `rebuildTableHeader` is the single most Auto-Layout-dense function in the file; extracting a `ReadingListTableHeaderBuilder.make(showsLargeTitle:showsCatchUpRow:showsFilter:catchUpButton:filterRow:width:) -> (UIView, height)` pure builder would let it be exercised without a live table view. **M.** |
| 1019-1093 | Edit-mode select-all/delete, Add-a-link alert, `deleteAllArchiveTapped` | Small; leave in place. |
| 1095-1130 | Animated single-item delete | Small, already isolated. |
| 1132-1221 | Section/collapse helpers + table header view/height | Small. |
| 1223-1337 | **Cell configuration** (`cellForRowAt`, `configureItemCell`, `configurePriceTrackerCell`) | `configureItemCell` is already `func` (non-private) for reuse — but its only real caller besides this file is nobody (see §2.6); either it's dead API surface or the "search screen" it was built for never shipped. |
| 1339-1374 | `secondaryText(for:)` | Small, pure-ish. |
| 1376-1483 | **Open routing** (`didSelectRowAt`, `open(_:presenter:transitionSourceView:)`, `presentArchiveReader`, `openItem`) | `presentArchiveReader` → shared helper, see §2.3. |
| 1484-1511 | Platform-item launch ladder | Small, pure-ish policy already (`openPlatformItem`). |
| 1513-1541 | Thumbnail state helper | Small, pure. |
| 1542-1601 | Editing-row protocol methods + context-menu lifecycle | Small. |
| 1603-1740 | **`rowMenu(for:at:)`** (~130 lines) | See §2.2 — extract to a pure `ReadingListRowMenuFactory.menu(for: ReadingListItem, actions: RowMenuActions) -> UIMenu` where `RowMenuActions` bundles the callback closures; makes the action-set logic unit-testable independent of `UIContextMenuConfiguration` plumbing. **M.** |
| 1742-1864 | Media-to-Photos, send-failure notice pill, ereader send, ebook share | `saveMediaToPhotos`/`saveLocalDownloaderMediaToPhotos`/`mediaDownloadStatusView`/`presentPendingSendFailureNoticeIfNeeded` (~120 lines) are a self-contained "status pill" concern → `MediaActionStatusCoordinator`. **M.** |
| 1866-1918 | Drag/drop reorder extension | Already well-isolated in its own `extension`. |

Net: the file's true "irreducible" view-controller-only content (lifecycle, table data source/delegate
glue, editing mode) is maybe 500-600 lines; the rest is 5-6 cleanly-bounded subsystems (pasteboard,
filter bar, table-header builder, row-menu factory, media-status pill, group-diff application) each
already delimited by its own `// MARK:` section, meaning the extraction cost here is mostly mechanical
(move + inject callbacks), not a redesign.

**`ArticleCardsViewController.swift` (1091 lines).**

| Lines | Region | Note |
|---|---|---|
| 39-153 | Properties/init/viewDidLoad | — |
| 155-183 | Lifecycle + top-inset math | Small. |
| 185-249 | Top chrome mount (back/paste/audio buttons + mode segmented control) | Fairly mechanical Auto Layout; low complexity per line despite length. |
| 251-334 | **Scroll-indicator hosting** (`layoutCardScrollIndicator`, immersion-aware frame math) | Genuinely tricky (interpolates between "resting card edge" and "screen edge" during immersion); already isolated behind one function — fine as is. |
| 336-384 | Bottom controls mount | Small. |
| 385-459 | Data (`refreshPasteboardURL`, `reload`) | See §2.3 (fingerprint mechanism). |
| 461-520 | Opening/immersion (`unlockCurrentCardIfNeeded`, `makeReader`, `openExternally`, `presentArchiveReader`) | `presentArchiveReader` → shared helper, see §2.3. |
| 522-635 | Carousel data source | Mechanical adapter; low complexity. |
| 637-706 | Carousel delegate (incl. RSVP long-press state machine) | Reasonably sized already. |
| 708-775 | `PasteboardCardContentViewController` | Small, self-contained. |
| **782-1056** | **`ReaderCardContentViewController`** (~275 lines) | The real complexity concentration. Sub-regions: reader-embed lifecycle (`embedReaderIfPossible`, ~50 lines), inline-reader-coordinator protocol conformance (~30 lines), and **scroll-direction/immersion detection** (`observeReaderScrollViews`/`handleOffsetChange`/`scrollRuns`/`rsvpControllers`/`scrollViews`, ~90 lines) — this last group is generic tree-walking + a bespoke directional-accumulator algorithm with real subtlety (documented re-entrancy guard at `:1024-1028`). Extracting it to a standalone `ScrollDirectionImmersionTracker` (inputs: a root view, callbacks: `onImmersionChange`) would make that algorithm unit-testable with synthetic `UIScrollView` offsets instead of only being exercisable through a live carousel. **M, worth doing** — it's the one truly non-trivial piece of business logic trapped inside a view class in this file. |
| 1058-1091 | `EmptyArticlesView` | Small. |

**`CatchUpViewController.swift` (763 lines).** Already the best-organized file in scope (explicit
`// MARK:` sections: Layout / Cards / End screens / Chrome / Actions). The one region worth flagging:
`populate(_:with:)` (`:315-377`, ~60 lines) inlines 3 divergent card-body constructions — see §2.2. Effort
to extract a `CatchUpCardBodyFactory.make(for: ReadingListItem, store:, host: UIViewController,
callbacks...) -> (body: UIView, bodyTop: NSLayoutYAxisAnchor)` is **S-M**; low urgency since the function
itself is already short and each branch is only a few lines of dispatch before delegating to an existing
type (`CatchUpPriceTrackerCardBody`, `ReaderViewController`, `CatchUpMediaCardBody`).

**Settings screens** — no file exceeds ~410 lines and each is a flat, single-purpose table data source;
no extraction seams warranted beyond the `makeToggle` duplication (§2.3).

### 2.5 Dead/unused code

Every claim below is a repo-wide grep (`grep -rn "<symbol>" --include="*.swift" .`), excluding the stale
parallel worktree at `.claude/worktrees/agent-a44f9578d823e01c8/` (a different agent's copy, not this
tree):

- **`InstalledAppMarkers.key(for:)` (`Luna/Settings/InstalledAppMarkers.swift:34-40`) — zero call sites.**
  `grep -rn "InstalledAppMarkers\.key("` matches only doc comments (`AppSurfaceConfig.swift:28`,
  `LunaLibraries/Sources/LunaInterop/InteropSurface.swift:57,67` — all `///` prose citing the *convention*,
  never actually calling the function). The function exists to document a string convention that native
  Safari-extension handlers replicate as raw literals (per its own doc comment, "the extensions don't
  share a framework") — but no Swift code in this repo calls it. Either dead code, or it was meant to be
  called from somewhere that never materialized. `isInstalled(_:)` on the same type IS used
  (`Luna/Mail/Intents/ProvideContextIntent.swift:111`), so the enum itself isn't fully dead — only this one
  static func.
- **`ActionHostViewController` (`Luna/UITestScreen.swift:222-250`) — zero instantiation sites.**
  `grep -rn "ActionHostViewController("` finds only the `init` declaration itself; no `UITestScreen` case
  or any other caller constructs one (compare `PresentingHostViewController`, defined right above it at
  `:186-217`, which IS constructed 3 times by `UITestScreenBuilder`). A full DEBUG-only scaffolding class
  with no caller.
- **No search screen exists** despite two doc comments in `ReadingListViewController.swift` (`:1278`,
  `:1388`) and one in-line comment (`:1425`) referring to "the search screen." `grep -rln
  "class.*Search.*ViewController"` across `Luna/` and `LunaLibraries/` finds only
  `LunaLibraries/Sources/LunaPriceUI/ProductSearchOverlayViewController.swift` (price-tracker product
  search, unrelated). `ReadingListViewController` itself has no `UISearchController`/search bar
  (`grep -in "search"` inside the file returns only the 3 comment lines). Whatever screen these comments
  describe does not exist in this codebase — either removed without updating the comments, or never
  built. This also means `configureItemCell(_:for:)` and `open(_:presenter:transitionSourceView:)` are
  broader-than-needed API surface (non-`private`) for a consumer that doesn't exist; their actual callers
  are internal to the file plus `SceneDelegate` plus one test file.

**Checked and confirmed NOT dead** (to head off false positives): `SystemSettingsLink.openActionButton()`
(used by `Luna/Social/OnboardingFlow.swift:265`), `CatchUpDeleteReadView.selectedCount`/`.total` (used
internally by its own `notifySelection()`, just could be `private`), `ArticleSourceBadge`/
`ArticleScrubPreviewText` (both used + both unit-tested), `VoiceInstallLink.open()` (2 call sites).

### 2.6 Comment hygiene

The codebase's established idiom (confirmed by `CODE_REVIEW_PLAN.md`'s own commit-message style and
consistent throughout this scope) is "X instead of Y" / "rather than Z" used as **design rationale** —
explaining a non-obvious performance or correctness choice by naming the rejected alternative. That is
deliberate, valuable, and not a hygiene problem; it is NOT blanket-flagged below. Two genuine issues found:

1. **`Luna/ReadingList/ReadingListViewController.swift:1278, 1388` (+ `:1425`)** — "shared with the search
   screen" / "the reading list, or the search screen" / "search, deep links, the two sibling apps" all
   reference a search screen that doesn't exist (§2.5). Rewrite `:1278`'s doc comment from:
   > "Configures a row cell for `item` (shared with the search screen so its rows look identical to the list's)."

   to:
   > "Configures a row cell for `item`."

   (and drop `func` visibility to `private` unless a real external consumer is confirmed). Similarly reword
   `:1388`'s "the reading list, or the search screen" → "the reading list" (or whichever screens actually
   call `open(_:presenter:)` today — `SceneDelegate` and one test), and `:1425`'s "search, deep links, the
   two sibling apps" → "deep links, the two sibling apps".

2. **`Luna/Reader/ArticleCardsViewController.swift:149`** — pure historical narration with no forward
   design value: "The pasteboard probe below is async... it used to be the ONLY caller of `reload()` on
   launch, so the cards didn't appear until it returned and the empty state showed until then." This
   describes a bug that was fixed, not a constraint on the current code. Rewrite to state the invariant
   being protected, e.g.:
   > "`reload()` must run synchronously here, before the async pasteboard probe: `store.items()` serves an
   > in-memory cache, so this shows saved articles immediately instead of waiting on the probe's
   > round-trip."

All other "instead of"/"rather than"/"previously" hits found by grep (listed for completeness — every one
reviewed and judged to be load-bearing rationale, not narration, so no action proposed): `ReadingListViewController.swift:340,460,480,490,552-553,761,781,783,1033,1097,1319-1321,1780`;
`ArticleCardsViewController.swift:69,96,180,756`; `ArticleScrubPreview.swift:74`; `CatchUpSubviews.swift:293`;
`CatchUpViewController.swift:66,757`; `SceneDelegate.swift:211`; `AppSurfaceConfig.swift:31`;
`AppDelegate.swift:297,341`; `AudioPlaybackWiring.swift:40`; `ArticleSpotlightIndexWiring.swift:16`;
`UITestFixtures.swift:97`; `UITestScreen.swift:18,221`; `UITestSeeder.swift:80,105`;
`DiagnosticsViewController.swift:18`. No `TODO`/`FIXME`/`HACK`/`XXX` markers anywhere in scope; the few
"legacy" mentions (`ReadingListViewController.swift:40`, `CatchUpViewController.swift:17`,
`OnboardingGuideVideo.swift:59`, `AppDelegate.swift:116`, `AudioPlaybackWiring.swift:19,40,42`) all name a
currently-existing alternate code path (the pre-surface combined list, the pre-audio-stack
`SpeechController`), not dead narration.

### 2.7 Animation structure

Three independent hand-rolled animation systems in scope, none sharing infrastructure, none obviously
over-structured (each is proportionate to what it does):

- **`CatchUpCardView`** (`:161-289`) — manual `UIPanGestureRecognizer` → `CGAffineTransform`
  translate+rotate, a `Zone` enum for live tint/badge selection, `layer.shouldRasterize` toggling around
  the transform to avoid glass-effect "ballooning" (documented, deliberate), spring-back via
  `UIView.animate(usingSpringWithDamping:)`, fly-off via `UIView.animate` + completion calling `onAction`.
  Self-contained, proportionate to a Tinder-style card; no reuse opportunity elsewhere in scope (nothing
  else in this scope needs drag-to-commit cards).
- **`ArticleCardsViewController`'s immersion fade** — chrome visibility is driven by
  `carousel.setImmersed(_:extendsCard:animated:)` (in `LunaDesignSystem`, outside scope) plus this file's
  own `layoutCardScrollIndicator(animated:)` (`:261-300`, a manual `UIView.animate` sliding one indicator
  between two computed frames, guarded by `isIndicatorSliding` so layout passes mid-flight don't cut it
  short). Proportionate — one bespoke animation for one bespoke widget (the host-tracked scroll
  indicator), not a pattern that recurs.
- **`CatchUpMessageView.playDoneCheckmark`** (`:78-202`) — a genuinely hand-built `CAShapeLayer` ring+tick
  stroke-on animation with a spring "pop," Reduce-Motion short-circuit, and `CATransaction` completion
  callback. This is meaningfully more elaborate than everything else in scope (~90 lines for one
  celebration), but it's a one-off "done!" moment used exactly once — not duplicated, not reused, and not
  over-structured relative to what a hand-drawn checkmark draw-on requires. No finding; flagging only
  because it's the most complex single animation in the audited scope.

No shared "glass card" or "commit-gesture" animation helper exists across `CatchUpCardView` and any other
in-scope file, but there is currently only one card type that needs drag-to-commit, so this is not (yet) a
duplication — it would become one if a second swipeable-card surface is added later.

---

## 3. Test coverage note

Grepped `LunaTests/*.swift` for every view-controller name in scope. Results:

- **`ReadingListViewController`** — exercised only as a `router:`/`presenter:` dependency inside
  `LunaTests/CatchUpAndPriceScreenTests.swift` (catch-up flow tests, price-tracker `open()`/interactive-pop
  tests). None of its own ~1900 lines of pasteboard/filter/header/drag-drop/row-menu logic are directly
  tested.
- **`CatchUpViewController`** — the best-covered file in scope: `CatchUpAndPriceScreenTests.swift` covers
  card-stack/locked-card/price-tracker-card snapshots, on-screen-content layout assertion, and (via the
  price-tracking editor) existing/creation/merge mode + interactive-pop + alert-viewed behavior.
- **`ArticleCardsViewController`** — **zero references anywhere in `LunaTests/`.** Its ~1090 lines
  (including the non-trivial `ReaderCardContentViewController` scroll-direction/immersion logic, §2.4) have
  no test coverage at all in the unit-test target.
- **`SettingsViewController`** — one row's behavior tested by `InteropSettingsTests.swift`
  (`testSharedSettingsRowShowsEntitlementAndOpensPaywall`, `testFriendsIsASettingsSubpage`). The other 10
  settings screens (`AppearanceSettingsScreen`, `AudioSettingsScreen`, `AutoDownloadSettingsScreen`,
  `AutoSendBySourceScreen`, `DoubleSaveRecipientsScreen`, `EmailAndKindleSettingsScreen`,
  `ShortcutSettingsScreen`, `ReaderSettingsScreen`, `ReadingListSettingsScreen`, `VoiceSettingsScreen`) have
  no VC-level tests. `AutoDownloadSettingsTests.swift` and `DiagnosticLogTests.swift` test the underlying
  model/store types (`AutoDownloadSettings`, `DiagnosticLog`) these screens read/write, not the screens.
- **`DiagnosticsViewController`** — no test references the VC itself (only its underlying `DiagnosticLog`).
- **`AppDelegate` / `SceneDelegate`** — no test file references either type by name.
- Reference PNGs exist for several settings screens (`settings-top.png`, `settings-appearance.png`,
  `settings-shortcut.png`, `settings-auto-download.png`, `settings-auto-send-by-source.png`,
  `settings-email-kindle.png`, `settings-reader.png`, `settings-reading-list.png`,
  `settings-media-provider.png`, `settings-experimental.png` under `LunaTests/ReferenceImages/`) but no
  `LunaTests/*.swift` file's `func test*` matches those names or references those settings-screen types —
  these are most likely captured by an external screenshot harness (the "screenshot agent" referenced in
  `UITestScreen.swift`'s doc comments and `claudedocs/ui-testing.md`) rather than the XCTest snapshot
  mechanism used elsewhere (e.g. `CatchUpAndPriceScreenTests`'s `assertSnapshot`-style calls). Not
  confirmed either way without access to that harness's config; flagged as an open question rather than a
  finding.
- Pure/model-adjacent pieces in scope ARE well covered: `ArticleScrubPreviewTextTests.swift`,
  `SourceBadgeTests.swift`, `ReadingListDiffTests.swift`, `AudioQueueRuleTests.swift`,
  `OnboardingScreenTests.swift` (onboarding flow, not in my scope but shares `UITestFixtures`/`UITestSeeder`).

---

## Top 10 highest-value changes (ranked)

1. **Consolidate the triplicated archive-unlock presentation** (`ReadingListViewController.swift:1437-1469`,
   `ArticleCardsViewController.swift:497-520`, `CatchUpViewController.swift:442-463`) into one shared
   helper. Removes ~70 lines of near-identical, easy-to-desync wiring; any future change to the
   unlock flow currently requires editing 3 call sites correctly. **Effort: M.**
2. **Add unit/snapshot coverage for `ArticleCardsViewController`.** It's Reader's actual root screen (1091
   lines), has zero test references, and hosts the one genuinely tricky algorithm in this scope
   (`handleOffsetChange`'s directional accumulator). Highest risk-reduction-per-effort item on this list.
   **Effort: M.**
3. **Fix the stale "search screen" comments + tighten `configureItemCell`/`open(_:presenter:)` visibility**
   in `ReadingListViewController.swift` (§2.5, §2.6). Cheap, removes a misleading reference to
   nonexistent functionality that could send a future reader chasing a screen that doesn't exist. **Effort: S.**
4. **Remove `InstalledAppMarkers.key(for:)`** (`Luna/Settings/InstalledAppMarkers.swift:34-40`) — verified
   zero call sites repo-wide; the convention it documents is otherwise fine as a doc comment on the enum.
   **Effort: S.**
5. **Remove `ActionHostViewController`** (`Luna/UITestScreen.swift:222-250`) — verified zero instantiation
   sites; dead DEBUG-only scaffolding. **Effort: S.**
6. **Extract `ReaderCardContentViewController`'s scroll-direction/immersion tracker** into a standalone,
   unit-testable type (`ArticleCardsViewController.swift:1009-1055`). It's the one piece of real algorithmic
   complexity trapped inside a view class with no test coverage (see #2 — doing this alongside adding tests
   compounds the value). **Effort: M.**
7. **Consolidate `ArticleCardsViewController`'s 4-closure `ReaderCardContentViewController` cluster**
   (`onImmersionChange`/`onReaderReady`/`onInlineReaderChange`/`inlineReaderCardFrameInWindowProvider`,
   `:791-794`, all set from one call site at `:539-566`) into a single delegate protocol. Same call sites,
   removes 3 of 4 optional-closure footguns. **Effort: M.**
8. **Extract `ReadingListViewController.rowMenu(for:at:)`** (`:1606-1733`, ~130 lines) into a pure
   `ReadingListRowMenuFactory`. Makes "which actions apply to which item shape" independently testable and
   shrinks the view controller by a meaningful chunk. **Effort: M.**
9. **Fold `AutoSendBySourceScreen`'s private `makeToggle(isOn:onChange:)`** into the shared
   `UITableViewController` extension in `SettingsViewController.swift:18`. Trivial, removes the one
   duplicate helper found in Settings. **Effort: S.**
10. **Extract `ReadingListViewController`'s pasteboard-suggestion subsystem** (`:324-472`, ~150 lines
    already delimited by its own `// MARK:`) into a `PasteboardSuggestionController`. Largest single
    mechanical size reduction available in the file's biggest region map, low risk since the region is
    already well-isolated behind its own state and its own methods. **Effort: M.**

*(Not ranked but worth a mention if anyone touches `AudioPlaybackCenter`: consolidating its 3-closure
DI cluster set from `AudioPlaybackWiring.swift`/`AudioScriptPipelineWiring.swift` into one delegate — see
§2.1 — but the target type lives in `LunaAudioPlayback`, outside this scope, so it's out of place in a
top-10 for the app shell specifically.)*
