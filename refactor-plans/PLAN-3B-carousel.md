# Wave 3B — CardCarousel decomposition + card-surface split

Read `PLAN.md` hard rules and `audits/design-system.md` §2.2, §2.4, §2.7 first. Wave 1
already removed the dead API; Wave 3A already ran (it touches
`SplitWebOverlayViewController`, which item 4 here edits again — work from HEAD).
Files: `LunaDesignSystem/CardCarousel/*`, `LunaDesignSystem/HorizonScrollIndicator.swift`,
plus adopters (`LunaReaderUI/SplitWebOverlayViewController.swift`,
`LunaReaderUI/InlineReaderEclipseTransition.swift`). One commit per item.

**The carousel view controller has NO direct test coverage** (only its geometry does), so
every step here must be a conservative, mechanical transformation. When in doubt, smaller.

## 1. Make illegal states unrepresentable (audit §2.4.2)

- `activeTransition: CardEclipseTransition?` + `isActiveTransitionInteractive: Bool` →
  `enum PagingTransition { case none; case automatic(CardEclipseTransition); case interactive(CardEclipseTransition) }`.
- `pendingReload: (deferred: Bool, index: Int?)` →
  `enum PendingReload { case none; case pending(centerIndex: Int?) }`.
Update every read/write site; behavior identical.

## 2. Extract `CarouselScrubPreviewController` (audit §2.4.1)

The scrub-preview overlay concern (stored props `previewOverlay`, `previewImageView`,
`previewTitleLabel`, `previewContent`, `previewContentIndex`, `stripLoadGeneration` and
the mount/promote/take methods) moves into one internal final class owned by the
carousel VC. Contract: the VC hands it `(cardArea, dataSource lookups it needs)` via
init/protocol; the controller exposes the same operations the VC's own code called
(`showPreview(at:)`, `promote(...)`, `takeScrubPreviewContent(...)` etc. — derive exact
names from the current methods). The promote-without-rebuilding invariant (the comment
about "no player swap … keeps playing") must move with the code. The scrubber→preview
flow is exercised by `CardCarouselMetricsTests`' preview-promotion tests — green.

## 3. Extract `CarouselAudioSessionCoordinator`

Mute state + `AVAudioSession` management + hardware-volume observation
(`volumeObservation`, the auto-unmute logic) into one internal object. The carousel VC
keeps its public surface unchanged.

## 4. `CardSurfaceView` / `CarouselCardView` split (audit §2.2.2)

New `public class CardSurfaceView: UIView` in `LunaDesignSystem` owning the generic
chrome that non-carousel users need: rounded surface, `installContentView`,
`contentContainer`, `setBorderEnabled`, `setContentEdgeFadeHeight`, the corner-radius
constant. `CarouselCardView: CardSurfaceView` keeps everything carousel-specific (mute
button, `dimAlpha`, `chromeAlpha`, glass rim, `setTopLeadingAccessory`).
`SplitWebOverlayViewController` switches to `CardSurfaceView` (it uses only the generic
subset — audit-verified). `InlineReaderEclipseTransition`'s use of
`CarouselCardView.cornerRadius` as a magic-number source points at the base class
constant instead. Visuals must be pixel-identical — the split is by API, not appearance.

## 5. `CarouselScrubberViewDelegate` (audit §2.1)

`onPreview`/`onCommit` → `scrubber(_:didPreview:)` / `scrubber(_:didCommit:)`; sole
conformer `CardCarouselViewController` (drops two `[weak self]` closures in
`viewDidLoad`).

## 6. `HorizonScrollIndicator` boundary fix (audit §2.2.1)

Delete the `isInsideCarouselCard` superview-chain type-check; the `.install()` vs
`.makeHosted()` caller-side choice already covers every call site (audit-verified: all
current in-card hosts use `.makeHosted()`). Grep all `.install(` call sites and confirm
none sit inside a card before deleting.

## 7. `CarouselAnimationTiming` constants (audit §2.7)

Small internal namespace naming the carousel's non-eclipse durations/curves (the 0.28
crossfade, the 0.22 chrome fade, and siblings you find). Values unchanged, one home.
Do NOT build a generic animation framework — named constants only (the audit holds up
`MoonHorizonStyle` as the model).

## 8. Eclipse-family cross-references (audit §2.3; master plan says: document, don't merge)

Add a short comment at the top of each of `CardEclipseAnimator.swift` (LunaDesignSystem),
`InlineReaderEclipseTransition.swift` (LunaReaderUI), and `LunarEclipseTransition.swift`
(LunaTransitions) naming the other two, stating what IS shared (`CardEclipseTransition
.makeCorona` + `EclipseFlareView`, reused by the inline transition) and that the lunar
transition's silhouette-corona/radial-light drawing is deliberately independent (it
follows an arbitrary snapshot shape, not a rounded card). Three sentences each, present
tense.

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/CardCarouselMetricsTests -only-testing:LunaTests/SourceBadgeTests -only-testing:LunaTests/DotMatrixSpinnerViewTests -only-testing:LunaTests/ReaderScreenTests -only-testing:LunaTests/InlineReaderTabMetricsTests`.
Then a manual sanity pass is NOT required here — Wave 5 covers the full suite — but if
you have any doubt about a transformation's equivalence, stop and report instead of
committing.
