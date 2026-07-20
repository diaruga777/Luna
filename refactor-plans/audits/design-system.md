# Audit: LunaDesignSystem + LunaTransitions

Scope: every `.swift` file in `LunaLibraries/Sources/LunaDesignSystem/` (27 files,
6093-24=6069 lines... see exact counts below) and `LunaLibraries/Sources/LunaTransitions/`
(2 files). All files were read in full. Read-only audit — no code was changed.
Every usage/dead-code claim below is backed by a repo-wide grep (command shown); greps
excluded `.build/` and the stray `.claude/worktrees/agent-a44f9578d823e01c8/` directory
(a different, unrelated agent's worktree checked out elsewhere in this repo — its copies
of `LunaTransitions` even contain extra files, `DotMatrixKeyboardReveal.swift` /
`DotMatrixModal.swift` / `DotMatrixTransitionCenter.swift`, that don't exist on this
branch; it is not part of this audit's scope and was ignored throughout).

Per CLAUDE.md: this repo has already had two review passes (`CODE_REVIEW_PLAN.md`,
`PERF_REVIEW_PLAN.md`). Nothing below repeats items those documents list as fixed or
deliberately deferred (Swift 6 concurrency, per-app dependency slimming, etc.).

---

## 1. Structure map

### CardCarousel/ (11 files, 3255 lines — the bulk of the module)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `CardCarouselViewController.swift` | 1134 | The root carousel screen: slot management, paging (eclipse + crossfade), scrub-strip wiring, immersion, mute/audio-session, gesture disambiguation, context menus. | `CardCarouselDataSource`, `CardCarouselDelegate` (protocols), `CardCarouselStyle`, `CardCarouselViewController` (~15 public methods/properties) | `Luna/Reader/ArticleCardsViewController.swift`, `Luna/Downloader/SavedMediaCardsViewController.swift`, `LunaTests/CardCarouselMetricsTests.swift` |
| `CardCarouselMetrics.swift` | 120 | Pure geometry: card/peek/slot layout math + `CarouselScrubberMath.index(forLocationX:)`. No UIKit state — intentionally unit-testable. | `CardCarouselMetrics`, `CarouselScrubberMath` | `CardCarouselViewController`, `CarouselScrubberView`, `LunaTests/CardCarouselMetricsTests.swift` |
| `CardContentViewController.swift` | 55 | Base class defining the playback contract (`isPlayable`, `setPlaying`, `seek`, `setMuted`, `cardDidBecomeCentered/LeaveCenter`) all card content subclasses implement. | `CardContentViewController` (open class) | Subclassed by the 3 content controllers below + `Luna/Reader/ArticleScrubPreview.swift` (a 4th, host-owned subclass) |
| `AnimatedImageCardContentViewController.swift` | 161 | GIF playback: ImageIO frame decode off-main + `CADisplayLink`-driven scrubbable playback. | `AnimatedImageCardContentViewController` | `Luna/Downloader/SavedMediaCardsViewController.swift` only |
| `ImageCardContentViewController.swift` | 40 | Static aspect-fit image, sync or async loader. | `ImageCardContentViewController`, `.Loader` | `Luna/Downloader/SavedMediaCardsViewController.swift` only |
| `VideoCardContentViewController.swift` | 149 | `AVPlayer`-backed video: autoplay/loop, frame-accurate scrub, poster image, async audio-track detection. | `VideoCardContentViewController`, `.ItemProvider` | `Luna/Downloader/SavedMediaCardsViewController.swift` only |
| `CarouselCardView.swift` | 256 | One card's chrome: rounded surface, dim overlay, glass rim, content edge-fade mask, mute button, top-leading accessory slot. | `CarouselCardView` (~15 public members) | `CardCarouselViewController`, `CardEclipseAnimator`, `HorizonScrollIndicator` (type-check only), **and, outside CardCarousel entirely:** `LunaReaderUI/InlineReaderEclipseTransition.swift`, `LunaReaderUI/SplitWebOverlayViewController.swift` |
| `CardEclipseAnimator.swift` | 439 | The carousel's page transition ("solar eclipse"): interactive/automatic `UIViewPropertyAnimator`-keyframed ingress, zenith swap callback, egress slide-in. Also draws the corona and the star-flare (`EclipseFlareView`). | `CardEclipseTransition`, `CardEclipseZenithResult`, `EclipseFlareView` | `CardCarouselViewController`; `EclipseFlareView`/`CardEclipseTransition.makeCorona`/`.duration` also reused directly by `LunaReaderUI/InlineReaderEclipseTransition.swift` |
| `CarouselScrubberView.swift` | 476 | The thumbnail/mini-card strip: native `UIScrollView`-based centering/snapping, live preview-on-scroll, edge fade+blur veils. | `CarouselScrubberView`, `.Style`, `CarouselScrubberView.onPreview`/`.onCommit` | `CardCarouselViewController`, `LunaTests/CardCarouselMetricsTests.swift` |
| `CarouselSourceBadge.swift` | 118 | Source-identity mark (favicon / sender initials / SF Symbol) + the view that renders it. | `CarouselSourceBadge` (enum), `CarouselSourceBadgeView` | `CardCarouselViewController`, `CarouselScrubberView`, `Luna/Reader/ArticleCardsViewController.swift`, `Luna/Reader/ArticleSourceBadge.swift`, `LunaReaderUI/SplitWebOverlayViewController.swift`, `LunaTests/SourceBadgeTests.swift` |

### Top-level DesignSystem files (16 files, 2814 lines)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `MoonHorizonProgress.swift` | 631 | Shared geometry+palette (`MoonHorizonStyle`) for the "moon horizon" motif, plus a UIKit determinate progress bar (`MoonHorizonProgressBar`) and a SwiftUI equivalent (`MoonHorizonProgressView`) for the Live Activity widget extension. | `MoonHorizonStyle`, `MoonHorizonProgressBar`, `MoonHorizonProgressView` | `HorizonScrollIndicator` (style only); `MoonHorizonProgressBar` used by `Luna/MiniPlayer/AudioMiniPlayerView.swift`, `LunaDownloaderClip/ClipDownloadViewController.swift`, `LunaReadingListUI/DownloaderProgressFooterView.swift`, `LunaReadingListUI/MediaDownloadStatusView.swift`, `LunaShareSurface/SavedNonTextualViewController.swift`, `Luna/Downloader/SavedMediaCardsViewController.swift`; `MoonHorizonProgressView` used only by `LunaDownloaderLiveActivity/LunaDownloaderLiveActivityWidget.swift` |
| `HorizonScrollIndicator.swift` | 287 | Custom vertical scroll indicator in the same visual language, in two install modes (self-installed vs. host-managed/hosted). | `HorizonScrollIndicator` | `Luna/Reader/ArticleCardsViewController.swift` (`.makeHosted()`), `LunaArchiveReader/OriginalPageViewController.swift`, `LunaReaderUI/InlineReaderPageViewController.swift`, `LunaReaderUI/RabbitHoleLayerViewController.swift`, `LunaReaderUI/ScrollReaderViewController.swift` (all `.install`), `LunaReaderUI/SplitWebOverlayViewController.swift` (`.makeHosted()`) |
| `DotMatrixSpinnerView.swift` | 367 | Indeterminate "dot matrix" spinner (drop-in for `UIActivityIndicatorView`) + a "resolve into a checkmark" success-beat animation. | `DotMatrixSpinnerView` | Widely used across `Luna/Mail`, `LunaArchiveReader`, `LunaReaderUI`, `LunaReadingListUI`, `LunaShareSurface`, `LunaReaderClip`; unit-tested (`DotMatrixSpinnerViewTests.swift`) |
| `LunaSegmentedControl.swift` | 334 | Snapshot-stable segmented control (owns its own selection indicator layer instead of `UISegmentedControl`). | `LunaSegmentedControl` | `Luna/Reader/ArticleCardsViewController.swift`, `Luna/ReadingList/ReadingListViewController.swift`, `LunaReaderUI/RabbitHoleLayerViewController.swift`, `LunaReaderUI/ReaderViewController.swift`; exercised (not unit-tested directly) via `LunaTests/ReaderScreenTests.swift` |
| `NavHeaderBar.swift` | 243 | Plain-`UIView` recreation of a small-title nav bar, used instead of `UINavigationController`'s own bar; scroll-driven fade-in of a solid background + separator; button factories. | `NavHeaderBar` | `Luna/Diagnostics/DiagnosticsViewController.swift`, `Luna/ReadingList/ReadingListViewController.swift`, `LunaPriceUI/PriceTrackingViewController.swift`, plus every screen that subclasses `NavHeaderTableController` |
| `NavHeaderHosting.swift` | 61 | Two `mount(in:)` extension methods wiring a `NavHeaderBar` into either a `UITableViewController` (frame-guide pinned) or a plain `UIViewController` (safe-area pinned). | `NavHeaderBar.mount(in:)` ×2 | `NavHeaderTableController` (table variant); `ReadingListViewController`, `DiagnosticsViewController`, `PriceTrackingViewController` (plain-VC variant) |
| `NavHeaderTableController.swift` | 92 | `UITableViewController` base class wiring `NavHeaderBar` + content-inset management + scroll-driven fade, with `makeLeadingControls()`/`makeTrailingControls()` hooks. | `NavHeaderTableController` | Base of 8 `Luna/Settings/*Screen.swift` controllers + `LunaSocialUI/{FriendDetailViewController,FriendsViewController,PendingRequestsViewController}.swift` |
| `GlassStyle.swift` | 141 | Central Liquid-Glass/solid-fallback styling helpers (reticule marks, focus panel, circular button configs, solid-fill fallbacks, brand accent, glass border color). | `GlassStyle` (enum of static members) | Extremely widely used — 25+ files across `Luna/CatchUp`, `Luna/Mail`, `Luna/MiniPlayer`, `LunaReaderUI`, `LunaPriceUI`, `LunaShareSurface`, `LunaSocialUI`, `LunaReadingListUI`, `LunaInteropUI`, `LunaArchiveReader` |
| `DownsampledImageLoader.swift` | 69 | Shared decode-off-main + `NSCache` + staleness-token pattern for on-disk thumbnails. | `DownsampledImageLoader.load`/`.cachedImage` | `Luna/Downloader/SavedMediaCardsViewController.swift` (only `load`); `LunaTests/DownsampledImageLoaderTests.swift` |
| `ImageDownsampling.swift` | 35 | Raw ImageIO downsampling decode primitive. | `ImageDownsampling.decode` | `DownsampledImageLoader`, `Luna/CatchUp/CatchUpSubviews.swift`, `Luna/MiniPlayer/AudioMiniPlayerView.swift`, `LunaAudioPlayback/NowPlayingCoordinator.swift`, `LunaReadingListUI/ReadingListItemCell.swift` |
| `ReaderAccent.swift` | 28 | Enum of 9 preset highlight colors. | `ReaderAccent` | `ReaderSettings.accent`, `Luna/Settings/SettingsViewController.swift` |
| `ReaderDepth.swift` | 24 | Background tint per nesting depth (0-4) for inline readers. | `ReaderDepth.backgroundColor(for:)` | `LunaPriceUI/ProductSearchOverlayViewController.swift`, `LunaReaderUI/{InlineReaderPageViewController,RabbitHoleLayerViewController,RabbitHoleLayout,RabbitHoleReaderViewController}.swift`; unit-tested (`ReaderDepthTests.swift`) |
| `ReaderModeIcons.swift` | 77 | Programmatic "Abc" glyphs for the reader mode switcher. | `ReaderModeIcons.image(for:)` | `Luna/Reader/ArticleCardsViewController.swift`, `LunaReaderUI/{RabbitHoleLayerViewController,ReaderViewController}.swift` |
| `ReaderSettings.swift` | 158 | App-Group-persisted reader preferences (RSVP WPM, font scale/serif, preload depth, accent, last mode, etc). | `ReaderSettings` (enum of static accessors), `RSVPDisplayMode` | Read/written by ~10 files across `Luna/` and `LunaLibraries/Sources/{LunaAudioPlayback,LunaReaderUI,LunaReadingList,LunaReadingListUI,LunaShareSurface}`; covered incidentally by `AudioPlaybackPersistenceTests.swift`, `PreloadStoreTests.swift`, `ReaderScreenTests.swift` |
| `AppearanceSettings.swift` | 55 | App-Group-persisted interface-style override + the Lunar Eclipse reader-transition opt-in flag. | `AppearanceSettings` | `Luna/SceneDelegate.swift`, `Luna/Settings/AppearanceSettingsScreen.swift`, `LunaTransitions/LunarEclipseTransition.swift` |
| `WeakScriptMessageHandler.swift` | 27 | Weak trampoline breaking the `WKUserContentController` retain cycle. | `WeakScriptMessageHandler` | `LunaPlatforms/PlatformEmbedViewController.swift`, `LunaPriceUI/ProductSearchOverlayViewController.swift` |
| `WebJunkBlocker.swift` | 115 | Content-rule-list + injected cleanup script hiding paywalls/consent/ad overlays in inline web previews; shared `WKProcessPool`. | `WebJunkBlocker.makeConfiguration`/`.applyRuleList` | `LunaPriceUI/ProductSearchOverlayViewController.swift`, `LunaReaderUI/{InlineReaderPageViewController,RabbitHoleLayerViewController}.swift` |

### LunaTransitions/ (2 files, 401 lines)

| File | Lines | Responsibility | Public API | Used by |
|---|---|---|---|---|
| `LunarEclipseTransition.swift` | 369 | A third, independent "eclipse" transition: reading-list-row → reader push/pop, using a rendered snapshot of the tapped row as the eclipsing body. Contains its own corona/flare/radial-light drawing code. | `LunarEclipseTransitionCenter` (`.prepare`, `.animator`) | `Luna/ReadingList/ReadingListViewController.swift` (`.prepare`); `LunarEclipseNavigationDelegate.swift` (`.animator`) |
| `LunarEclipseNavigationDelegate.swift` | 32 | `UINavigationControllerDelegate` that asks `LunarEclipseTransitionCenter` for an animator; installs itself via an `objc_setAssociatedObject`-retained extension method. | `LunarEclipseNavigationDelegate`, `UINavigationController.installLunarEclipseTransition()` | `Luna/SceneDelegate.swift` (×2, push nav + a second nav controller) |

`LunaTransitions` has **zero test coverage** — no test file imports it, `@testable
import LunaTransitions` appears nowhere in `LunaTests/` (`grep -rl "import LunaTransitions" LunaTests/*.swift` → empty).

---

## 2. Findings

### 2.1 Stored-callback communication

| Callback | Declared | Set by | Invoked by | Verdict |
|---|---|---|---|---|
| `CardContentViewController.audioAvailabilityChanged: (() -> Void)?` | `CardContentViewController.swift:32` | `CardCarouselViewController.mount(index:existingContent:)` L516 | `VideoCardContentViewController.install(_:)` L106 (only subclass that fires it) | Single cross-component callback (content → carousel). Legitimate — no protocol needed for one call. |
| `CarouselCardView.onMuteToggle: (() -> Void)?` | `CarouselCardView.swift:22` | `CardCarouselViewController.mount(index:existingContent:)` L517-520 | `CarouselCardView.muteTapped()` L221 | Single callback, fine as-is. |
| `CarouselScrubberView.onPreview: ((Int) -> Void)?` and `.onCommit: ((Int) -> Void)?` | `CarouselScrubberView.swift:45,47` | `CardCarouselViewController.viewDidLoad` L264-265 | `CarouselScrubberView.scrollViewDidScroll`/`handleTap`/`commitCenteredChip` (3 call sites) | **Two closures for one component pair, both fired from multiple internal call sites.** Candidate for a `CarouselScrubberViewDelegate` protocol (`scrubber(_:didPreview:)`, `scrubber(_:didCommit:)`) — would also let `CardCarouselViewController` avoid two ad-hoc `[weak self]` closures in `viewDidLoad`. |
| `CardCarouselViewController.onImmersionChanged: ((Bool) -> Void)?` | `CardCarouselViewController.swift:384` | **nobody** | `applyImmersionLayout()`'s `apply` closure, L427 | **Dead** — see 2.5. |
| `CardEclipseTransition.atZenith`/`.completion` (init params) | `CardEclipseAnimator.swift:60-61` | `CardCarouselViewController.makeEclipseTransition` (per-transition, one-shot) | Internally, once each, at zenith/finish | Genuine one-shot completion handlers — excluded per the audit brief, not flagged. |
| `InlineReaderEclipseAnimator.onTransitionStart`/`.atZenith` | `InlineReaderEclipseTransition.swift:281-282` (LunaReaderUI, out of scope but referenced by this module) | host of the animator | once each | One-shot, not flagged (noted only because it pairs with the eclipse duplication in 2.3). |

**Net:** only one real consolidation candidate in this module — `CarouselScrubberView.onPreview`/`.onCommit` — and it is low value (2 closures, 1 consumer, both already named consistently). Not worth a protocol on its own merits; worth doing only if `CarouselScrubberView` picks up a third callback later.

### 2.2 View/container boundary violations

1. **`HorizonScrollIndicator` has a hard-coded dependency on `CarouselCardView`, a type from a different subsystem it should not know about.**
   `HorizonScrollIndicator.swift:178-185`:
   ```swift
   private var isInsideCarouselCard: Bool {
       var ancestor = superview
       while let current = ancestor {
           if current is CarouselCardView { return true }
           ancestor = current.superview
       }
       return false
   }
   ```
   `HorizonScrollIndicator` is documented as a general-purpose scroll indicator ("A custom vertical scroll indicator..."), but its `didMoveToWindow` self-removal logic special-cases exactly one container type from `CardCarousel/`. Any future card-hosting container needs this same escape hatch and won't get it without editing this file. The `.makeHosted()` / `.install()` split already exists to let a host opt out of self-installation — the `CarouselCardView` type-check duplicates what the host already knows to do explicitly (see `ArticleCardsViewController`/`SplitWebOverlayViewController`, which both already use `.makeHosted()` for exactly this reason). This look-up-the-superview-chain check is therefore fully redundant with the caller-side `.makeHosted()` opt-out and only exists as an automatic safety net for callers that use `.install()` inside a card by mistake.

2. **`CarouselCardView` is reused wholesale, outside any `CardCarousel`, as generic bordered/fading card chrome — a boundary crossing that drags carousel-specific API surface (mute button, dim overlay, top-leading accessory) into a use site that needs none of it.**
   `LunaReaderUI/SplitWebOverlayViewController.swift:65,123-138,224,273` instantiates `CarouselCardView` directly for the nested-reader tab surface, using only `setBorderEnabled`, `setContentEdgeFadeHeight`, `installContentView`, and `contentContainer` — never `onMuteToggle`, `dimAlpha`, `chromeAlpha`, or `setTopLeadingAccessory`. Likewise `LunaReaderUI/InlineReaderEclipseTransition.swift:108` reaches for `CarouselCardView.cornerRadius` purely as a magic-number source, with no `CarouselCardView` instance in sight. `CarouselCardView` is a **CardCarousel/-scoped type conflating two responsibilities**: (a) a generic bordered/edge-fading card surface, and (b) carousel-specific chrome (mute, dim, accessory). Two different modules (`LunaReaderUI`) now depend on responsibility (a) while paying for (b) unconditionally (allocating a `UIButton`, `dimOverlay`, glass border machinery, etc. that are simply never shown). This is the strongest boundary-violation finding in the module: it means `CardCarousel/`'s "private" chrome view is actually a load-bearing public type for an unrelated feature area.

3. **`CardEclipseTransition` mutates `CarouselCardView` internals directly instead of through an API.**
   `CardEclipseAnimator.swift:120,128` calls `outgoing.addSubview(whitening)` and `oppositePeek.addSubview(veil)` — inserting its own temporary dressing subviews directly into a `CarouselCardView`'s subview tree, and elsewhere directly sets `incoming.dimAlpha`, `card.transform`, `card.center`, `card.bounds` (also done by `CardCarouselViewController.applyRestingLayout`/`applyImmersionLayout`). `CarouselCardView`'s layout/animation state (`transform`, `center`, `bounds`, `dimAlpha`, `borderAlpha`, `chromeAlpha`) is a public read/write surface driven by **two different external orchestrators** (the carousel's own resting-layout code, and the eclipse transition) rather than being owned by the card itself. Not urgent to fix (both orchestrators are first-party and coordinate correctly today, verified by reading `settleAfterTransition`/`performZenithSwap`), but any future third driver (e.g. a different transition) inherits the same "reach in and set everything" contract with no encapsulation boundary to catch misuse.

### 2.3 Duplicated or disjoint-but-related logic

**Three independent hand-rolled "solar eclipse" transitions exist in the app, each drawing its own corona/flare/radial-light dressing:**

| # | File | Module | Trigger | Corona impl | Flare/point-light impl |
|---|---|---|---|---|---|
| 1 | `CardEclipseAnimator.swift` | `LunaDesignSystem/CardCarousel` | Carousel card-to-card paging | `CardEclipseTransition.makeCorona` — two stacked `UIView` shadow glows | `EclipseFlareView` — `CGContext` radial gradient + 8 drawn diffraction spikes |
| 2 | `InlineReaderEclipseTransition.swift` | `LunaReaderUI` | Inline nested-reader push/pop | **reuses** `CardEclipseTransition.makeCorona` directly | **reuses** `EclipseFlareView` directly, but re-implements its own circle-reveal ingress/egress keyframe timeline from scratch (`InlineReaderEclipseScene`, ~190 lines) |
| 3 | `LunarEclipseTransition.swift` | `LunaTransitions` | Reading-list row → reader push (opt-in setting) | **independent** `EclipseInteriorCoronaView`/silhouette-shadow `UIImageView` halo — a third corona technique | **independent** `EclipseRadialLightView` — its own `CGContext` radial-gradient point light (no diffraction spikes) |

Transition #2 already shows the right instinct (reuse `makeCorona`/`EclipseFlareView` rather than re-drawing them), but transition #3 duplicates both drawing primitives from scratch with a different visual technique (silhouette-shadow corona vs. stacked-glow corona; plain radial gradient vs. gradient-plus-spikes flare) for what is conceptually the same "eclipse" effect family. If the visual intent is genuinely the same motif (the module doc comments for both #1 and #3 use identical language — "corona", "flare", "zenith", "diamond ring point light") this is a strong candidate to extract one shared `EclipseCoronaView`/`EclipseFlareView` (or generalize the existing `CardEclipseAnimator` primitives to be reusable without a `CarouselCardView`) that all three transitions draw from. If the visual intents have actually diverged (silhouette-following corona for arbitrary source shapes vs. rounded-rect corona for cards), that divergence should at minimum be a documented, deliberate decision rather than an accretion from three separate feature commits — currently nothing in the code says which.

**Secondary, smaller duplication:** `CardCarouselMetrics`'s side-slot geometry (`centerX(forSlotOffset:)`, peek math) and `CarouselScrubberView`'s centering math (`centeringOffsetX(forIndex:)`, `nearestIndex(toOffsetX:)`) are both "map a linear index to a screen position with symmetric edge insets," solved twice with different techniques (closed-form peek arithmetic vs. `UIScrollView` content-inset + conversion). This is likely appropriate (one is driven by Auto Layout/native scrolling, the other by manual transforms) but is worth a one-line note in whichever refactor plan follows, since a reader coming from one will expect the same vocabulary in the other and won't find it.

### 2.4 Overly complex code

1. **`CardCarouselViewController` is a 1134-line god class** covering: slot mount/unmount, two paging mechanisms (eclipse + crossfade `jump`), scrub-strip wiring, scrub-preview overlay mount/promote/take, immersion layout, mute state + `AVAudioSession` management + hardware-volume observation, 4 gesture recognizers with a shared `UIGestureRecognizerDelegate`, and `UIContextMenuInteractionDelegate`. It carries 20 stored properties spanning all of the above concerns in one flat namespace (`slots`, `count`, `metrics`, `isTransitioning`, `isViewVisible`, `pendingReload`, `activeTransition`, `isActiveTransitionInteractive`, `interactiveTravel`, `pagePanConsumed`, `scrubStartFraction`, `wasPlayingBeforeScrub`, `volumeObservation`, `previewOverlay`, `previewImageView`, `previewTitleLabel`, `previewContent`, `previewContentIndex`, `stripLoadGeneration`, `isStreamingLongPress`). The file is already organized with `// MARK:` sections (Slots / Paging / Scrub-strip preview / Card gestures / Mute + audio session), which suggests the natural seams for splitting into cooperating objects (e.g. a `CarouselSlotManager`, a `ScrubPreviewController`, a `CarouselAudioSessionCoordinator`) already exist as comment boundaries, not yet as types.

2. **Redundant/coupled state flags for transition tracking.** `activeTransition: CardEclipseTransition?` and `isActiveTransitionInteractive: Bool` are two separate variables that must be kept in lock-step by convention (`makeEclipseTransition` always sets the bool `false`; `beginInteractivePage` immediately flips it to `true` right after calling `makeEclipseTransition`; nothing enforces that the flag can only be `true` when `activeTransition != nil`). A `enum TransitionMode { case none, case automatic(CardEclipseTransition), case interactive(CardEclipseTransition) }` would make the illegal states (interactive-with-no-transition) unrepresentable. Similarly `pendingReload: (deferred: Bool, index: Int?)` (`CardCarouselViewController.swift:196`) encodes "no pending reload" as `(false, nil)` and "pending, keep current index" as `(true, nil)` — a plain `Int??`-flavored enum (`case none, case pending(Int?)`) would remove the implicit invariant that `index` is only meaningful when `deferred` is true.

3. **`GlassStyle.solidButtonFill` is `public` but has exactly one caller, itself (`solidCircularButtonConfiguration`), and no external reader** (verified: `grep -rn "solidButtonFill"` matches only its own declaration and use inside `GlassStyle.swift`). Minor over-exposure — should probably be `private`.

4. **`CardCarouselViewController.handleTap`'s control-hit-test walk** (`sequence(first: hit, next: { ... })` walking the view chain up to `cardArea` looking for a `UIControl`, `CardCarouselViewController.swift:917-922`) is a reasonable but non-obvious workaround, documented adequately by its own comment — flagged here only as a complexity data point, not a defect.

None of `CardContentViewController`'s three concrete subclasses, `CardCarouselMetrics`, `CarouselSourceBadge`, `NavHeaderBar`/`NavHeaderHosting`/`NavHeaderTableController`, `GlassStyle`, `ReaderSettings`, or the `LunaTransitions` files show god-method or dead-branch problems — they are appropriately sized for what they do.

### 2.5 Dead/unused code

Every item below was verified with the grep shown (all run from the repo root, excluding `.build/` and the stray worktree).

1. **`CardCarouselViewController.onImmersionChanged` is entirely dead.**
   `grep -rn "onImmersionChanged" --include="*.swift" .` → only 2 hits, both inside `CardCarouselViewController.swift` itself (the declaration at L384 and the fire site at L427). Its only two potential external consumers, `ArticleCardsViewController.swift` and `SavedMediaCardsViewController.swift`, were checked directly (`grep -n "setImmersed\|isImmersed\|onImmersionChanged" Luna/Reader/ArticleCardsViewController.swift Luna/Downloader/SavedMediaCardsViewController.swift`) and neither sets it — `ArticleCardsViewController` only *reads* `carousel.isImmersed` and *calls* `setImmersed(...)`. The doc comment ("hosts fade any bottom chrome of their own... in step with the carousel's") describes an integration that was never built.

2. **`CardCarouselViewController.isSoundMuted` (public getter) and `setSoundMuted(_:)` (public setter) are never called from outside the class.**
   `grep -rn "isSoundMuted" --include="*.swift" .` and `grep -rn "setSoundMuted" --include="*.swift" .` both return hits only from within `CardCarouselViewController.swift` (the mute button's own tap handler and the volume-observation auto-unmute). Neither host (`ArticleCardsViewController`, `SavedMediaCardsViewController`) reads or drives carousel mute state externally — mute is fully self-contained via the per-card mute button. The public getter/setter pair is unused API surface; not certain garbage (a host could legitimately want an external mute toggle later) but currently exercises no code path that isn't already reachable via the mute button/hardware-volume paths.

3. **`DownsampledImageLoader.cachedImage(path:pointSize:scale:)` has no production caller.**
   `grep -rn "DownsampledImageLoader\.\(cachedImage\|load\)" --include="*.swift" .` shows `load` called once in production (`Luna/Downloader/SavedMediaCardsViewController.swift:518`) but `cachedImage` appears only in `LunaTests/DownsampledImageLoaderTests.swift`. The doc comment explicitly motivates it as letting "a caller show an already-decoded bitmap instantly... before falling back to `load(...)` on a miss, mirroring `ReadingListItemCell.configureArt`" — but `SavedMediaCardsViewController`, the one production adopter, never takes that fast path; it only calls `load`. Either a caller should adopt the documented fast path, or the method (and its doc comment's justification) is aspirational dead code.

4. **`LunarEclipseNavigationDelegate` (the type) is never referenced by name outside its own file.**
   `grep -rl "LunarEclipseNavigationDelegate" --include="*.swift" .` → only `LunarEclipseNavigationDelegate.swift` itself. This is *not* a defect — it's intentionally encapsulated behind the `installLunarEclipseTransition()` extension method (`SceneDelegate.swift` calls only the method) — noted here only because a naive dead-code grep would flag it; on inspection it's correctly used, just indirectly.

No dead code was found in `CardCarouselMetrics`, `CarouselScrubberView`, `CarouselSourceBadge`, `CardEclipseAnimator`, `MoonHorizonProgress`, `HorizonScrollIndicator`, `DotMatrixSpinnerView`, `LunaSegmentedControl`, `NavHeaderBar`/`NavHeaderHosting`/`NavHeaderTableController`, `ImageDownsampling`, `ReaderAccent`, `ReaderDepth`, `ReaderModeIcons`, `ReaderSettings`, `WeakScriptMessageHandler`, `WebJunkBlocker`, `AppearanceSettings`, or `LunarEclipseTransition.swift` — every public symbol in those files has at least one real external caller or an active internal use.

### 2.6 Comment hygiene

| File:line | Comment | Problem | Fix |
|---|---|---|---|
| `NavHeaderBar.swift:15-17` | `//  Restyle note (Task 3): the button factories below produce PLAIN system-styled\n//  controls (no liquid-glass coupling), so they can be freely restyled.` | Narrates a work-tracking event ("Task 3") rather than describing the code. Task numbers have no meaning to a future reader. | Delete the "Restyle note (Task 3)" framing; keep only the substantive fact as a doc comment on the button factories: `/// Plain, system-styled controls (no liquid-glass coupling) — restyle freely.` |
| `NavHeaderBar.swift:30-31` | `// De-glassed (Task 3): a solid, trait-aware fill that fades in on scroll instead of\n// a live blur. The header sits on a solid screen background, so the blur added little` | Same "Task 3" tag; also the second sentence trails off ("...so the blur added little" — missing an object, reads as truncated/edited-in-place). | Rewrite: `// A solid, trait-aware fill that fades in on scroll (mirrors a standard nav bar\n// over a scroll view). The header sits on a solid screen background, where a live\n// blur would have added little visual benefit.` |
| `GlassStyle.swift:97-102` | `// These approximate the glass bar/button materials with solid, trait-aware colors,\n// for chrome that sits on SOLID color backgrounds where the live blur adds little\n// where a live blur adds little. They read like the material\n// they replace in both light and dark mode.` | Literal duplicated clause — "where the live blur adds little" appears twice back to back, an evident copy/paste-and-edit leftover, not narration but a broken sentence. | Rewrite to one clean sentence: `// These approximate the glass bar/button materials with solid, trait-aware colors\n// for chrome that sits on solid backgrounds, where a live blur would add little.\n// They read like the material they replace in both light and dark mode.` |
| `MoonHorizonProgress.swift:120-123` | `// The sun point and the traveling pulse. The head's bloom was brightened a\n// step when the pulse landed (the inner/outer head alphas below); the pulse\n// itself glows at the head's former brightness, and the merge flare when\n// the two meet briefly outshines both.` | "was brightened a step when the pulse landed" and "the head's former brightness" narrate a *tuning history* rather than stating the current invariant between the two constant sets. | Rewrite to state the relationship directly: `// The sun point and the traveling pulse. headBloom{Inner,Outer}Alpha are brighter\n// than pulseBloom{Inner,Outer}Alpha, so the head reads as more lit than the\n// traveling pulse; the merge flare briefly outshines both.` |

Everything else flagged by the narration-keyword sweep (`instead of`, `rather than`, rows in `CardEclipseAnimator.swift`, `CarouselScrubberView.swift`, `CarouselCardView.swift:168`, `LunarEclipseTransition.swift`, `VideoCardContentViewController.swift:61`, `CardCarouselViewController.swift:125,446`, `ReaderSettings.swift:47-50,61`, `DownsampledImageLoader.swift:12`) is describing a **present-tense design choice and its rationale** ("X instead of Y, because Z"), which is exactly the kind of comment CLAUDE.md and this brief want kept — none of those describe a change to *this* code or narrate its history, so none are flagged for rewrite. `ReaderSettings.swift:47-50`'s "retired... now lives as..." is the one borderline case: it reads like history, but it is in fact load-bearing documentation for *why* `lastReaderMode`'s getter silently remaps a persisted `.highlight` value to `.rsvp` — removing the "retired" framing would leave a future reader unable to tell why that remap exists. Left as-is.

### 2.7 Animation structure

**Under-structured:** `CardCarouselViewController`'s non-eclipse `jump(to:)` (crossfade, `UIView.transition(...)`, `duration: 0.28`) and `promoteScrubPreview`'s chrome fade (`UIView.animate(..., duration: 0.22, ...)`) each hard-code their own duration/curve inline, distinct from `CardEclipseTransition.duration` (0.62) and from each other, with no shared naming (a `0.28` and a `0.22` sitting a few hundred lines apart with no visible relationship). This is a minor case for a small `CarouselAnimationTiming` namespace of named constants (mirroring what `MoonHorizonStyle` already does well for its own module — see below) so a future tuning pass touches one place instead of grepping for magic numbers.

**Well-structured (worth preserving as the model, not changing):** `MoonHorizonStyle` centralizes every timing/alpha constant used by both `MoonHorizonProgressBar` (UIKit) and `MoonHorizonProgressView` (SwiftUI) — `pulseCycleDuration`, `pulseTravelDuration`, `pulseFadeDuration`, `pulseFlareDuration`, `headBloomInnerAlpha`, etc. — so the two renderers of the same motif can't drift out of sync on timing even though they're built with entirely different animation systems (Core Animation vs. SwiftUI `keyframeAnimator`). `CardEclipseAnimator`'s `CardEclipseTransition.duration`/`.zenithScale` static constants, reused directly by `InlineReaderEclipseTransition.swift`, are a smaller-scale version of the same good pattern (see 2.3 for why it isn't extended to the third eclipse implementation).

**Not over-structured anywhere in this module:** no animator/curve abstraction here is speculative or unused — `CardEclipseTransition`'s `UIViewPropertyAnimator`-wrapping-`animateKeyframes` structure is exactly as complex as its interactive-scrub requirement demands (verified: every public method — `update(fraction:)`, `finishInteractive()`, `cancelInteractive()` — is called from `CardCarouselViewController`'s pan handler, none are unused hooks).

---

## 3. Test coverage note

Grepped by `import LunaDesignSystem`/`import LunaTransitions` (incl. `@testable`) across `LunaTests/*.swift`, and by type name.

**Has direct unit tests:**
- `CardCarouselMetrics` / `CarouselScrubberMath` / `CarouselScrubberView` (layout only) / `CardCarouselDataSource` (a test double) — `LunaTests/CardCarouselMetricsTests.swift` (12 tests: peek/aspect/scale/centering geometry, thumbnail-index mapping, scrub-preview-promotion behavior).
- `DotMatrixSpinnerView` — `LunaTests/DotMatrixSpinnerViewTests.swift` (10 tests: sizing, dot count, start/stop lifecycle, color, snapshot, checkmark-resolve geometry).
- `CarouselSourceBadge` (+ the reader's own `ArticleSourceBadge` logic it backs) — `LunaTests/SourceBadgeTests.swift` (14 tests).
- `DownsampledImageLoader` (+ transitively `ImageDownsampling`) — `LunaTests/DownsampledImageLoaderTests.swift` (3 async tests: downsampling, caching, stale-delivery discard).
- `ReaderDepth` — `LunaTests/ReaderDepthTests.swift` (4 tests: light/dark ramps, clamping).

**Touched only indirectly**, via screen-level tests that exercise a host controller which happens to use the type: `ReaderSettings`/`AppearanceSettings` (`ReaderScreenTests.swift`, `AudioPlaybackPersistenceTests.swift`, `PreloadStoreTests.swift`), `LunaSegmentedControl` (`ReaderScreenTests.swift` — locates the control by type and drives it, but doesn't unit-test `LunaSegmentedControl` itself), `NavHeaderBar` (`CatchUpAndPriceScreenTests.swift` — comments note the header's controls are exercised via "action seams," not the bar's own layout/scroll behavior).

**No test coverage at all** (no unit test, no incidental exercise found by type-name grep in `LunaTests/`):
- `CardCarouselViewController` itself — no test drives paging, scrubbing, immersion, mute, or the eclipse transition end-to-end; `CardCarouselMetricsTests.swift` only reaches its data-source protocol and geometry, not the view controller.
- `CardEclipseAnimator` (`CardEclipseTransition`, `EclipseFlareView`) — no test at all (animation-heavy, plausibly hard to test, but zero coverage today).
- `CarouselCardView` — no test (mute button wiring, border/dim/edge-fade state).
- `CardContentViewController` and its 3 concrete subclasses (`AnimatedImageCardContentViewController`, `ImageCardContentViewController`, `VideoCardContentViewController`) — no test.
- `MoonHorizonProgress.swift` (`MoonHorizonStyle` geometry, `MoonHorizonProgressBar`, `MoonHorizonProgressView`) — no test, despite `MoonHorizonStyle` containing testable pure geometry (`horizonControlPoints`, `point(atFraction:)`, `horizonPath(toFraction:)`) in the same style as the already-tested `CardCarouselMetrics`.
- `HorizonScrollIndicator` — no test.
- `NavHeaderHosting`, `NavHeaderTableController` — no direct test (only the indirect `NavHeaderBar` exercise above).
- `GlassStyle` — no test (arguably fine; it's mostly `UIButton.Configuration`/color factories with no branching logic worth unit-testing beyond the `#available` fallback, which no test currently exercises either).
- `ReaderAccent`, `ReaderModeIcons` — no test.
- `WeakScriptMessageHandler`, `WebJunkBlocker` — no test.
- **`LunaTransitions` as a whole (`LunarEclipseTransition.swift`, `LunarEclipseNavigationDelegate.swift`) — zero test coverage; not even a compile-time `@testable import`.**

---

## Top 10 highest-value changes (ranked)

1. **Split `CardCarouselViewController` into cooperating objects** (slot/paging manager, scrub-preview controller, mute/audio-session coordinator), using its existing `// MARK:` sections as the seams. Highest leverage — it's the largest, least-tested, most stateful file in the module, and every other CardCarousel finding (state-flag redundancy, boundary reach-ins) gets easier once responsibilities are separated. **Effort: L.**
2. **Delete `onImmersionChanged`, or wire it up** — it's dead, verified two ways (no setter anywhere, no consumer in either host). Whichever way this goes, it should stop being unreconciled public API. **Effort: S.**
3. **Decide and document the relationship between the three eclipse-transition implementations** (`CardEclipseAnimator`, `InlineReaderEclipseTransition`, `LunarEclipseTransition`) — either consolidate the corona/flare drawing primitives into one shared piece all three transitions use (as #2 already partly does for #1), or add a comment at each site explaining why it's deliberately independent. This is the single biggest "should this be one abstraction" question in the audited code. **Effort: M** (drawing-primitive extraction) **to L** (if the timelines/choreography are also unified).
4. **Resolve `CarouselCardView`'s split identity** (generic bordered/fading card chrome vs. carousel-specific mute/dim/accessory chrome) — extract a base card-surface view that `SplitWebOverlayViewController` and the carousel both use, leaving mute/dim/accessory on a carousel-specific subclass or wrapper. Removes the clearest module-boundary violation found. **Effort: M.**
5. **Remove `HorizonScrollIndicator`'s `is CarouselCardView` check**, relying solely on the caller-side `.install()`/`.makeHosted()` choice that already exists and is already used correctly by every current call site. **Effort: S.**
6. **Add tests for `CardEclipseAnimator`, `CarouselCardView`, and the three `CardContentViewController` subclasses** — the entire paging-transition and per-card-chrome layer of the carousel has zero direct test coverage today. **Effort: M.**
7. **Add `LunaTransitions` test coverage** — currently exactly zero; even a couple of tests around `LunarEclipseTransitionCenter.animator(for:from:to:)`'s gating logic (Reduce Motion, the settings flag, push vs. pop vs. other operations) would catch regressions in logic that's otherwise silent-fails-to-nil by design. **Effort: S/M.**
8. **Fix the `GlassStyle.swift:97-102` duplicated-clause comment and the two "Task 3" comments in `NavHeaderBar.swift`** — trivial but currently misleading/broken prose in widely-read files. **Effort: S.**
9. **Consolidate `CardCarouselViewController`'s paging/transition state** (`activeTransition` + `isActiveTransitionInteractive` → one enum; `pendingReload`'s tuple → one enum) to make illegal combinations unrepresentable. **Effort: S/M.**
10. **Decide whether `isSoundMuted`/`setSoundMuted(_:)` and `DownsampledImageLoader.cachedImage` are meant to be used externally**; either wire up a real caller (the loader's own doc comment already describes the intended call pattern) or narrow the API/remove the unused fast path. **Effort: S.**
