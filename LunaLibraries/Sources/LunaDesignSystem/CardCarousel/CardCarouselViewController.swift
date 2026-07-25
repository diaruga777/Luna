//
//  CardCarouselViewController.swift
//  LunaDesignSystem
//
//  A root-screen carousel of vertical 9:16 cards, one saved item per card, with
//  the neighbors' edges peeking in from the screen sides and a thumbnail scrub
//  strip underneath. Interaction model:
//
//  - The centered card's content autoplays (looping) as soon as it is centered.
//  - Tap on the centered card: pause/play. Horizontal drag inside it: scrub the
//    playback timestamp (the card itself does not pan — paging happens outside).
//  - Dragging on the side insets drives the eclipse page transition
//    interactively (tracking the finger, playable forward and back); releasing
//    finishes or cancels it. A tap on a peeked edge pages one card. Reduce
//    Motion gets a crossfade. Non-centered cards rest heavily darkened.
//  - The scrub strip scrolls like a miniature carousel: the chip at its center
//    is the current card (previewed over the centered card while scrolling),
//    and releasing settles the nearest chip dead-center and commits it.
//  - Sound is off by default, toggled by the card's top-right mute button; a
//    hardware volume press also unmutes.
//
//  Content comes through CardCarouselDataSource as CardContentViewController
//  instances, so the same carousel serves any Luna app surface.
//

import UIKit

public protocol CardCarouselDataSource: AnyObject {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int
    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController
    /// Content for the large scrub overlay. It must render identically to
    /// `contentControllerForCardAt`; the exact instance may be promoted into
    /// the centered card when the scrub settles.
    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController?
    /// Small preview for the scrub strip; call the completion on any queue.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void)
    /// Card title, shown by the big scrub-preview overlay for `.miniCards`
    /// scrubbers while the finger sweeps the strip.
    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String?
    /// Source-identity badge for a `.miniCards` scrubber chip (favicon,
    /// sender initials, symbol). May call the completion more than once — a
    /// fast fallback first, then a refined badge (e.g. a favicon that had to
    /// be fetched) — and on any queue.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void)
    /// Optional small accessory pinned to the card's top-leading corner.
    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView?
    /// Optional tint for this card's edge glow — how a card whose save FAILED
    /// is marked out from its healthy neighbors. Asked at mount, because a
    /// `CardContentViewController` has no back-reference to its card view.
    func carousel(
        _ carousel: CardCarouselViewController,
        edgeGlowColorForCardAt index: Int
    ) -> UIColor?
}

public extension CardCarouselDataSource {
    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? { nil }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? { nil }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) { completion(nil) }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? { nil }

    func carousel(
        _ carousel: CardCarouselViewController,
        edgeGlowColorForCardAt index: Int
    ) -> UIColor? { nil }
}

/// Per-surface tuning, set BEFORE the carousel's view loads.
public struct CardCarouselStyle {
    /// Points of a neighboring card visible inside the screen edge.
    public var peek: CGFloat = 14
    /// Extra horizontal inset applied only to the centered card.
    public var edgeGap: CGFloat = 30
    public var sideScale: CGFloat = 0.92
    public var verticalPadding: CGFloat = 12
    /// Ignore the 9:16 aspect and take all available height and width.
    public var fillsVertically = false
    /// Horizontal swipes INSIDE the centered card page too (for content that
    /// doesn't scrub, e.g. embedded readers). Recognized simultaneously with
    /// the content's own gestures, gated to strongly-horizontal drags.
    public var pagesOnInCardSwipes = false
    /// Multiplies finger translation while interactively paging. Values above
    /// one make the eclipse transition travel farther than the physical drag.
    public var pageSwipeMovementMultiplier: CGFloat = 1
    public var scrubberStyle: CarouselScrubberView.Style = .thumbnails
    /// Mount and autoplay the previewed card's real content while the user
    /// scrolls the scrub strip. Kept opt-in because media previews may create
    /// players rapidly; the Downloader enables it for its thumbnail strip.
    public var autoplaysScrubPreviewContent = false
    /// Horizontal room around the scrub strip. Hosts can increase this to
    /// flank the strip with floating controls without covering its content.
    public var scrubberHorizontalInset: CGFloat = 16
    /// Width of the alpha-fade zone at each end of the scrub strip. Chips
    /// dissolve across this zone as they approach the strip's bounds — hosts
    /// that flank the strip with floating controls size it so chips melt away
    /// before reaching them. 0 disables the effect.
    public var scrubberEdgeFadeWidth: CGFloat = 0
    /// A subtle glass rim on every card, delineating it from a same-tone
    /// screen background. The centered card's rim fades with the rest of the
    /// carousel chrome during immersion.
    public var showsCardBorder = false
    /// Card content dissolves over this many points at the card's top and
    /// bottom edges instead of hitting a hard clip — scrolled reader text fades
    /// away as it approaches an edge. 0 (the default) keeps the hard clip.
    public var contentEdgeFadeHeight: CGFloat = 0
    /// Show a transient moon-horizon position bar beneath opted-in playable
    /// content while an in-card horizontal drag seeks through it.
    public var showsPlaybackScrubProgress = false

    public init() {}
}

public protocol CardCarouselDelegate: AnyObject {
    /// A new card is centered (paging, scrub commit, or reload).
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int)
    /// The user's page or scrub interaction has selected a target, before any
    /// card transition begins. A cancelled interactive page reports the still-
    /// centered card again when it settles. Hosts use this to update peripheral
    /// chrome without waiting for the card swap.
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int)
    /// Long-press menu for a card; return nil for none.
    func carousel(
        _ carousel: CardCarouselViewController,
        menuForCardAt index: Int
    ) -> UIMenu?
    /// The centered card was tapped and its content is not playable (playable
    /// content consumes the tap as pause/play). The tap does NOT cancel
    /// touches, so content-level taps (links) still land.
    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int)
    /// An edge page pan began while the carousel was immersed. The carousel
    /// has already restored its own chrome synchronously; hosts use this to
    /// restore any matching screen-level chrome before the page moves.
    func carouselDidSurfaceForEdgePaging(_ carousel: CardCarouselViewController)
}

public extension CardCarouselDelegate {
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {}
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int) {}
    func carousel(
        _ carousel: CardCarouselViewController,
        menuForCardAt index: Int
    ) -> UIMenu? { nil }
    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {}
    func carouselDidSurfaceForEdgePaging(_ carousel: CardCarouselViewController) {}
}

enum CardCarouselPagePanStartDecision: Equatable {
    case reject
    case accept
    case acceptAndSurface
}

enum CardCarouselPagePanStartPolicy {
    static func decision(
        isTransitioning: Bool,
        isImmersed: Bool,
        startsInsideCenteredCard: Bool,
        pagesOnInCardSwipes: Bool,
        velocity: CGPoint
    ) -> CardCarouselPagePanStartDecision {
        guard !isTransitioning else { return .reject }
        if startsInsideCenteredCard {
            // Immersed readers reserve in-card gestures for their content. A
            // screen-edge swipe remains the always-available paging affordance.
            guard !isImmersed, pagesOnInCardSwipes,
                  abs(velocity.x) > abs(velocity.y) * 1.5
            else { return .reject }
            return .accept
        }
        guard abs(velocity.x) > abs(velocity.y) else { return .reject }
        return isImmersed ? .acceptAndSurface : .accept
    }
}

/// Named durations for the carousel's own non-eclipse animations (the eclipse
/// page transition timings live on `CardEclipseTransition`).
private enum CarouselAnimationTiming {
    /// `jump(to:)`'s crossfade between the current and target windows of
    /// mounted cards (Reduce Motion, scrub commits, multi-card jumps).
    static let crossfadeDuration: TimeInterval = 0.28
    /// `promoteScrubPreview`'s chrome fade-in once a scrubbed preview becomes
    /// the real centered slot.
    static let chromeFadeDuration: TimeInterval = 0.22
}

public final class CardCarouselViewController: UIViewController {

    public weak var dataSource: CardCarouselDataSource?
    public weak var delegate: CardCarouselDelegate?

    /// Whether the carousel drives the shared AVAudioSession (ambient while
    /// muted, playback while unmuted). Hosts with their own audio coordination
    /// can turn this off.
    public var managesAudioSession: Bool {
        get { audioSession.managesAudioSession }
        set { audioSession.managesAudioSession = newValue }
    }

    /// Per-surface tuning. Set BEFORE the carousel's view loads.
    public var style = CardCarouselStyle()

    public private(set) var currentIndex = 0
    var isSoundMuted: Bool { audioSession.isMuted }
    private lazy var audioSession: CarouselAudioSessionCoordinator = {
        let coordinator = CarouselAudioSessionCoordinator()
        coordinator.onMuteStateChanged = { [weak self] in self?.applyMuteState() }
        return coordinator
    }()

    private struct Slot {
        let index: Int
        let card: CarouselCardView
        let content: CardContentViewController
    }

    private var slots: [Int: Slot] = [:]
    private var count = 0
    private var metrics: CardCarouselMetrics?
    private var isTransitioning = false
    private var isViewVisible = false
    /// A data reload that arrived mid-transition; applied when the transition
    /// settles (tearing slots down under a running transition would strand its
    /// captured card views in the hierarchy).
    private enum PendingReload {
        case none
        case pending(centerIndex: Int?)
    }
    private var pendingReload: PendingReload = .none

    private let cardArea = UIView()
    private var cardAreaTopConstraint: NSLayoutConstraint!
    private lazy var scrubber = CarouselScrubberView(style: style.scrubberStyle)
    private lazy var scrubPreview = CarouselScrubPreviewController(carousel: self, cardArea: cardArea)
    /// Bumped on every reload so async thumbnail/badge completions from a
    /// superseded item set can't land on the wrong chip.
    private var stripLoadGeneration = 0

    private var playbackPan: UIPanGestureRecognizer!
    private var pagePan: UIPanGestureRecognizer!
    private lazy var cardContextMenuInteraction = UIContextMenuInteraction(delegate: self)
    /// The in-flight eclipse, and whether the inset pan is driving it
    /// interactively. The carousel must retain the transition for its whole
    /// run — its animator completion holds it only weakly, so an unretained
    /// transition deallocates mid-flight and freezes at the zenith.
    private enum PagingTransition {
        case none
        case automatic(CardEclipseTransition)
        case interactive(CardEclipseTransition)

        var transition: CardEclipseTransition? {
            switch self {
            case .none: return nil
            case .automatic(let transition), .interactive(let transition): return transition
            }
        }
    }
    private var pagingTransition: PagingTransition = .none
    /// Finger-travel distance mapping the pan translation to the fraction.
    private var interactiveTravel: CGFloat = 1
    /// Set when a page pan already paged non-interactively (Reduce Motion), so
    /// further .changed events in the same gesture don't page again.
    private var pagePanConsumed = false

    private var scrubStartFraction: Double = 0
    private var wasPlayingBeforeScrub = false
    private let playbackScrubProgress = MoonHorizonProgressBar()
    private var playbackScrubPresentation = 0

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // The scrubber is added first so the card area (and the eclipse's
        // darkening veil inside it) can render above the strip.
        scrubber.edgeFadeWidth = style.scrubberEdgeFadeWidth
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrubber)
        cardArea.clipsToBounds = false
        cardArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardArea)
        playbackScrubProgress.alpha = 0
        playbackScrubProgress.isHidden = true
        // The traveling activity pulse belongs to download progress, not
        // deterministic media playback position.
        playbackScrubProgress.showsActivityPulse = false
        playbackScrubProgress.accessibilityLabel = "Video position"
        cardArea.addSubview(playbackScrubProgress)
        cardAreaTopConstraint = cardArea.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            scrubber.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: style.scrubberHorizontalInset),
            scrubber.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -style.scrubberHorizontalInset),
            scrubber.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            cardAreaTopConstraint,
            cardArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardArea.bottomAnchor.constraint(equalTo: scrubber.topAnchor),
        ])

        scrubber.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Let content-level taps (links inside an embedded reader, buttons)
        // land as well — the carousel's tap is additive, never stealing.
        tap.cancelsTouchesInView = false
        tap.delegate = self
        cardArea.addGestureRecognizer(tap)

        playbackPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        playbackPan.delegate = self
        cardArea.addGestureRecognizer(playbackPan)

        pagePan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pagePan.delegate = self
        cardArea.addGestureRecognizer(pagePan)

        cardArea.addInteraction(cardContextMenuInteraction)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = cardArea.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if metrics?.containerSize != size {
            metrics = CardCarouselMetrics.resolve(
                containerSize: size,
                peek: style.peek,
                edgeGap: style.edgeGap,
                sideScale: style.sideScale,
                verticalPadding: style.verticalPadding,
                fillsVertically: style.fillsVertically)
        }
        // Render the eclipse corona for this exact card geometry now, in the
        // background, rather than on whichever tap first starts a transition.
        EclipseCorona.prewarm(
            bodySize: centeredCardFrame().size,
            cornerRadius: CarouselCardView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint)
        guard !isTransitioning else { return }
        for slot in slots.values { applyRestingLayout(to: slot) }
        scrubPreview.layout(centeredCardFrame: centeredCardFrame())
        layoutPlaybackScrubProgress()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        audioSession.startVolumeObservation()
        slots[currentIndex]?.content.cardDidBecomeCentered()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        audioSession.stopVolumeObservation()
        slots[currentIndex]?.content.cardDidLeaveCenter()
    }

    // MARK: - Public surface

    /// Rebuilds every slot from the data source. Pass the index to center;
    /// otherwise the current index is kept (clamped to the new count). Arriving
    /// mid-transition, the reload is deferred until the transition settles.
    public func reloadData(centeringAt index: Int? = nil) {
        loadViewIfNeeded()
        guard !isTransitioning else {
            let existingIndex: Int?
            if case .pending(let centerIndex) = pendingReload {
                existingIndex = centerIndex
            } else {
                existingIndex = nil
            }
            pendingReload = .pending(centerIndex: index ?? existingIndex)
            return
        }
        scrubPreview.remove()
        setImmersed(false)
        count = dataSource?.numberOfCards(in: self) ?? 0
        let target = min(max(index ?? currentIndex, 0), max(0, count - 1))
        for slot in slots.values { unmount(slot) }
        slots = [:]
        currentIndex = target
        mountWindow()
        removeOrphanCardViews()
        scrubber.setThumbnailCount(count)
        loadAllThumbnails()
        guard count > 0 else { return }
        scrubber.setSelectedIndex(currentIndex, animated: false)
        applyMuteState()
        if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
        delegate?.carousel(self, didCenterCardAt: currentIndex)
    }

    /// The card view showing `index`, if mounted — e.g. a share-sheet popover source.
    public func cardView(at index: Int) -> UIView? {
        slots[index]?.card
    }

    /// The content controller mounted for `index`, if any.
    public func contentController(at index: Int) -> CardContentViewController? {
        slots[index]?.content
    }

    /// The centered card's RESTING frame — ignoring any immersion bottom
    /// extension — in `target`'s coordinate space. A host that draws chrome
    /// alongside the card (e.g. a scroll indicator that slides out to the screen
    /// edge on immersion) uses this as its resting anchor. Nil before layout
    /// resolves the metrics.
    public func restingCenteredCardFrame(in target: UIView) -> CGRect? {
        guard let metrics else { return nil }
        return cardArea.convert(metrics.centeredCardFrame(), to: target)
    }

    // MARK: - Immersion (reading-focused chrome fade)

    /// Whether the carousel chrome is faded away for focused reading: the
    /// peeking side cards and the scrub strip fade out, and (with
    /// `extendsCard`) the centered card's bottom edge extends into the room
    /// the strip frees up. The card's top, sides, and corner radius never
    /// move — the host's header and the card's own header stay exactly as
    /// they are.
    public private(set) var isImmersed = false

    /// Whether the current immersion extends the centered card's bottom edge
    /// into the room the faded strip frees up. Content that keeps a fixed
    /// layout (the RSVP reader) immerses WITHOUT the extension, so nothing
    /// inside the card moves — only the chrome fades.
    private var immersionExtendsCard = true

    /// A host-owned decorative view behind the cards — the starfield — that the
    /// carousel treats as its own chrome: it fades out with the scrub strip and
    /// side cards on immersion and fades back in with them, on the same curve.
    /// Weak, and never laid out or positioned here; the host still owns it.
    public weak var chromeBackdrop: UIView?

    /// Cards rest this far below the carousel view's top — hosts whose header
    /// overlays the carousel reserve their header height here.
    public func setTopInset(_ inset: CGFloat) {
        loadViewIfNeeded()
        guard abs(cardAreaTopConstraint.constant - inset) > 0.5 else { return }
        cardAreaTopConstraint.constant = inset
    }

    public func setImmersed(_ immersed: Bool, extendsCard: Bool = true, animated: Bool = false) {
        // A transition starts un-immersed: an edge page pan first surfaces the
        // carousel synchronously. This drops any later spurious fade-out — e.g.
        // a reader still decelerating while the user pages away — that would
        // fight the eclipse's manipulation of the same card.
        guard !isTransitioning else { return }
        if immersed == isImmersed {
            // Already immersed but the extension mode changed (e.g. a mode
            // switch from scroll to RSVP mid-immersion) — re-apply the card
            // frame without re-reporting the unchanged immersion state.
            guard immersed, immersionExtendsCard != extendsCard else { return }
            immersionExtendsCard = extendsCard
            if animated {
                UIView.animate(
                    withDuration: 0.32, delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction],
                    animations: applyImmersionLayout)
            } else {
                applyImmersionLayout()
            }
            return
        }
        isImmersed = immersed
        immersionExtendsCard = extendsCard
        scrubber.isUserInteractionEnabled = !immersed
        if animated {
            UIView.animate(
                withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                animations: applyImmersionLayout)
        } else {
            applyImmersionLayout()
        }
    }

    private func applyImmersionLayout() {
        scrubber.alpha = isImmersed ? 0 : 1
        // A host-owned backdrop (the starfield) counts as carousel chrome, so it
        // leaves and returns on the same curve as the strip and the side cards.
        chromeBackdrop?.alpha = isImmersed ? 0 : 1
        // The Reader replaces this bottom-center strip with its mode switcher
        // during immersion. A short downward drift makes that handoff read as
        // one control yielding the lane to the other instead of a hard swap.
        scrubber.transform = isImmersed && !UIAccessibility.isReduceMotionEnabled
            ? CGAffineTransform(translationX: 0, y: 8)
            : .identity
        for other in slots.values where other.index != currentIndex {
            other.card.alpha = isImmersed ? 0 : 1
        }
        // The centered card's content stays fully visible while immersed — its
        // glass rim fades in step with the strip and side cards, and its
        // surface tone clears so the content edge fades dissolve into the
        // screen background rather than a card-toned band.
        slots[currentIndex]?.card.borderAlpha = isImmersed ? 0 : 1
        slots[currentIndex]?.card.setSurfaceHidden(isImmersed)
        guard let metrics, let slot = slots[currentIndex] else { return }
        let resting = metrics.centeredCardFrame()
        var frame = resting
        if isImmersed, immersionExtendsCard {
            // Extend only the bottom edge to the carousel view's bottom (the
            // room the faded scrub strip frees up).
            let target = view.convert(view.bounds, to: cardArea)
            frame.size.height = max(target.maxY - resting.minY, resting.height)
        }
        slot.card.transform = .identity
        slot.card.bounds = CGRect(origin: .zero, size: frame.size)
        slot.card.center = CGPoint(x: frame.midX, y: frame.midY)
        // The card must ride above its (fading) peeking neighbors.
        if isImmersed { cardArea.bringSubviewToFront(slot.card) }
    }

    /// Pages by `step` cards. Single steps run the eclipse transition (unless
    /// Reduce Motion or off-window); anything else is a crossfade jump.
    public func page(by step: Int) {
        let target = min(max(currentIndex + step, 0), max(0, count - 1))
        guard count > 0, target != currentIndex, !isTransitioning, !isImmersed
        else { return }
        reportNavigationTarget(target)
        if abs(target - currentIndex) == 1,
           !UIAccessibility.isReduceMotionEnabled,
           view.window != nil,
           slots[target] != nil {
            runEclipse(to: target)
        } else {
            jump(to: target)
        }
    }

    private func setSoundMuted(_ muted: Bool) {
        audioSession.setMuted(muted)
    }

    // MARK: - Slots

    private func mountWindow() {
        guard count > 0 else { return }
        for index in (currentIndex - 1)...(currentIndex + 1)
        where index >= 0 && index < count && slots[index] == nil {
            slots[index] = mount(index: index)
        }
        for slot in slots.values { applyRestingLayout(to: slot) }
    }

    private func mount(index: Int) -> Slot? {
        guard let dataSource else { return nil }
        let content = dataSource.carousel(self, contentControllerForCardAt: index)
        addChild(content)
        let slot = mount(index: index, existingContent: content)
        content.didMove(toParent: self)
        return slot
    }

    /// Wraps an already-created child content controller in normal card chrome.
    /// Scrub-preview promotion uses this to preserve the exact live player.
    private func mount(index: Int, existingContent content: CardContentViewController) -> Slot {
        let dataSource = dataSource
        let card = CarouselCardView()
        card.setBorderEnabled(style.showsCardBorder)
        card.setContentEdgeFadeHeight(style.contentEdgeFadeHeight)
        card.setEdgeGlow(dataSource?.carousel(self, edgeGlowColorForCardAt: index))
        card.installContentView(content.view)
        content.setMuted(audioSession.isMuted)
        content.audioAvailabilityChanged = { [weak self] in self?.updateMuteUI() }
        card.onMuteToggle = { [weak self] in
            guard let self else { return }
            self.setSoundMuted(!self.audioSession.isMuted)
        }
        card.setTopLeadingAccessory(dataSource?.carousel(
            self, topLeadingAccessoryForCardAt: index))
        cardArea.addSubview(card)
        return Slot(index: index, card: card, content: content)
    }

    private func unmount(_ slot: Slot) {
        slot.content.setPlaying(false)
        slot.content.willMove(toParent: nil)
        slot.card.removeFromSuperview()
        slot.content.view.removeFromSuperview()
        slot.content.removeFromParent()
    }

    private func applyRestingLayout(to slot: Slot, atSlotOffset stagedOffset: Int? = nil) {
        guard let metrics else { return }
        if slot.index == currentIndex, isImmersed {
            applyImmersionLayout()
            return
        }
        let offset = stagedOffset ?? (slot.index - currentIndex)
        slot.card.layer.cornerRadius = CarouselCardView.cornerRadius
        slot.card.alpha = isImmersed ? 0 : 1
        slot.card.borderAlpha = 1
        slot.card.setSurfaceHidden(false)
        slot.card.transform = .identity
        slot.card.bounds = CGRect(origin: .zero, size: metrics.cardSize)
        slot.card.center = CGPoint(
            x: metrics.centerX(forSlotOffset: offset),
            y: metrics.centerY())
        slot.card.transform = CGAffineTransform(
            scaleX: metrics.scale(forSlotOffset: offset),
            y: metrics.scale(forSlotOffset: offset))
        slot.card.dimAlpha = offset == 0 ? 0 : CarouselCardView.restingDimAlpha
        updateMuteUI()
    }

    /// Removes any card view left in the hierarchy that no mounted slot owns —
    /// a structural guarantee that no card can appear twice, whatever the
    /// interleaving of reloads and transitions.
    private func removeOrphanCardViews() {
        let live = Set(slots.values.map { ObjectIdentifier($0.card) })
        for subview in cardArea.subviews
        where subview is CarouselCardView && !live.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }
    }

    private func centeredCardFrame() -> CGRect {
        metrics?.centeredCardFrame() ?? .zero
    }

    private func layoutPlaybackScrubProgress() {
        guard let metrics else { return }
        let height = playbackScrubProgress.intrinsicContentSize.height
        playbackScrubProgress.frame = metrics.playbackScrubProgressFrame(height: height)
    }

    private func showPlaybackScrubProgress(at fraction: Double) {
        guard style.showsPlaybackScrubProgress else { return }
        playbackScrubPresentation += 1
        playbackScrubProgress.layer.removeAllAnimations()
        playbackScrubProgress.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
        playbackScrubProgress.isHidden = false
        playbackScrubProgress.alpha = 0
        cardArea.bringSubviewToFront(playbackScrubProgress)
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.playbackScrubProgress.alpha = 1
        }
    }

    private func updatePlaybackScrubProgress(to fraction: Double) {
        guard !playbackScrubProgress.isHidden else { return }
        playbackScrubProgress.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
    }

    private func hidePlaybackScrubProgress() {
        guard !playbackScrubProgress.isHidden else { return }
        playbackScrubPresentation += 1
        let presentation = playbackScrubPresentation
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.playbackScrubProgress.alpha = 0
        } completion: { [weak self] finished in
            guard let self, finished, presentation == self.playbackScrubPresentation else { return }
            self.playbackScrubProgress.isHidden = true
        }
    }

    // MARK: - Paging

    private func runEclipse(
        to target: Int,
        duration: TimeInterval = CardEclipseTransition.duration
    ) {
        guard let transition = makeEclipseTransition(to: target, duration: duration) else {
            jump(to: target)
            return
        }
        // Non-interactive runs block all input for their duration; interactive
        // runs (handlePagePan) keep the driving pan alive instead.
        view.isUserInteractionEnabled = false
        transition.animateToFinish()
    }

    /// Builds one eclipse page transition to `target`, staging an unmounted
    /// target in the incoming peek position when this is a multi-card jump.
    /// Marks the carousel as transitioning — and retains the transition — until
    /// it settles.
    private func makeEclipseTransition(
        to target: Int,
        duration: TimeInterval = CardEclipseTransition.duration
    ) -> CardEclipseTransition? {
        guard let metrics,
              !isTransitioning,
              target >= 0, target < count,
              target != currentIndex,
              let outgoing = slots[currentIndex]
        else { return nil }
        let step = target - currentIndex
        let direction = step > 0 ? 1 : -1
        let incoming: Slot
        if let mounted = slots[target] {
            incoming = mounted
        } else if let staged = mount(index: target) {
            slots[target] = staged
            applyRestingLayout(to: staged, atSlotOffset: direction)
            staged.card.layoutIfNeeded()
            staged.content.view.layoutIfNeeded()
            incoming = staged
        } else {
            return nil
        }
        let opposite = slots[currentIndex - direction]

        isTransitioning = true

        // The veil should darken the scrub strip too, not just the card region.
        let dimmingBounds = view.convert(view.bounds, to: cardArea)

        let transition = CardEclipseTransition(
            in: cardArea,
            outgoing: outgoing.card,
            incoming: incoming.card,
            oppositePeek: opposite?.card,
            forward: step > 0,
            incomingTargetCenter: CGPoint(
                x: metrics.centerX(forSlotOffset: 0),
                y: metrics.centerY()),
            dimmingBounds: dimmingBounds,
            duration: duration,
            atZenith: { [weak self] in
                guard let self else {
                    return CardEclipseZenithResult(reappearingPeeks: [])
                }
                if abs(step) > 1 {
                    return self.performZenithJump(
                        outgoing: outgoing,
                        incoming: incoming,
                        target: target)
                }
                return self.performZenithSwap(outgoing: outgoing, step: step, opposite: opposite)
            },
            completion: { [weak self] _ in
                self?.settleAfterTransition()
            })
        pagingTransition = .automatic(transition)
        return transition
    }

    /// Runs after a transition finishes OR cancels: restores interactivity,
    /// applies resting layout, and picks up a reload that arrived mid-flight.
    private func settleAfterTransition() {
        isTransitioning = false
        pagingTransition = .none
        view.isUserInteractionEnabled = true
        for slot in slots.values { applyRestingLayout(to: slot) }
        removeOrphanCardViews()
        // Restores target-dependent chrome when an interactive page reverses,
        // and confirms the new target after a successful transition.
        reportNavigationTarget(currentIndex)
        if case .pending(let centerIndex) = pendingReload {
            pendingReload = .none
            reloadData(centeringAt: centerIndex)
        }
    }

    /// Behind the eclipse's total-coverage veil: retire the far peek, move the
    /// outgoing card to the opposite slot, and mount the next card on the side
    /// the incoming card vacated.
    private func performZenithSwap(
        outgoing: Slot,
        step: Int,
        opposite: Slot?
    ) -> CardEclipseZenithResult {
        if let opposite {
            unmount(opposite)
            slots[opposite.index] = nil
        }
        currentIndex += step

        applyRestingLayout(to: outgoing)
        outgoing.content.cardDidLeaveCenter()

        var enteringCard: UIView?
        let enteringIndex = currentIndex + step
        if enteringIndex >= 0, enteringIndex < count, slots[enteringIndex] == nil,
           let entering = mount(index: enteringIndex) {
            slots[enteringIndex] = entering
            applyRestingLayout(to: entering)
            enteringCard = entering.card
        }

        if let centered = slots[currentIndex] {
            centered.content.setMuted(audioSession.isMuted)
            if isViewVisible { centered.content.cardDidBecomeCentered() }
        }
        updateMuteUI()
        scrubber.setSelectedIndex(currentIndex, animated: true)
        delegate?.carousel(self, didCenterCardAt: currentIndex)
        return CardEclipseZenithResult(
            reappearingPeeks: [outgoing.card, enteringCard].compactMap { $0 })
    }

    /// A non-adjacent target is already the moon crossing the current card.
    /// At totality, keep that exact target centered, retire cards outside its
    /// new three-card window, and lay out both new peeks while they are hidden.
    private func performZenithJump(
        outgoing: Slot,
        incoming: Slot,
        target: Int
    ) -> CardEclipseZenithResult {
        outgoing.content.cardDidLeaveCenter()

        let keep = Set((target - 1)...(target + 1))
        for slot in Array(slots.values) where !keep.contains(slot.index) {
            unmount(slot)
            slots[slot.index] = nil
        }
        currentIndex = target

        var reappearingPeeks: [UIView] = []
        for index in [target - 1, target + 1] where index >= 0 && index < count {
            let slot: Slot
            if let mounted = slots[index] {
                slot = mounted
            } else if let mounted = mount(index: index) {
                slots[index] = mounted
                slot = mounted
            } else {
                continue
            }
            applyRestingLayout(to: slot)
            slot.card.layoutIfNeeded()
            slot.content.view.layoutIfNeeded()
            reappearingPeeks.append(slot.card)
        }

        incoming.content.setMuted(audioSession.isMuted)
        if isViewVisible { incoming.content.cardDidBecomeCentered() }
        updateMuteUI()
        scrubber.setSelectedIndex(currentIndex, animated: true)
        delegate?.carousel(self, didCenterCardAt: currentIndex)
        return CardEclipseZenithResult(reappearingPeeks: reappearingPeeks)
    }

    /// Non-eclipse move (Reduce Motion, off-window updates, and generic
    /// multi-card jumps).
    private func jump(to target: Int) {
        guard target != currentIndex, !isTransitioning else { return }
        slots[currentIndex]?.content.cardDidLeaveCenter()
        currentIndex = target
        UIView.transition(
            with: cardArea,
            duration: CarouselAnimationTiming.crossfadeDuration,
            options: [.transitionCrossDissolve, .allowAnimatedContent]
        ) {
            let keep = Set((self.currentIndex - 1)...(self.currentIndex + 1))
            for slot in self.slots.values where !keep.contains(slot.index) {
                self.unmount(slot)
                self.slots[slot.index] = nil
            }
            self.mountWindow()
        }
        applyMuteState()
        if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
        scrubber.setSelectedIndex(currentIndex, animated: true)
        delegate?.carousel(self, didCenterCardAt: currentIndex)
    }

    // MARK: - Scrub-strip preview

    private func showScrubPreview(_ index: Int) {
        guard count > 0, !isTransitioning else { return }
        reportNavigationTarget(index)
        slots[currentIndex]?.content.setPlaying(false)
        scrubPreview.show(at: index, cardCount: count, centeredCardFrame: centeredCardFrame())
    }

    private func commitScrub(to index: Int, isDirectTap: Bool = false) {
        guard count > 0, !isTransitioning else { return }
        let target = min(max(index, 0), count - 1)
        reportNavigationTarget(target)
        if !isDirectTap,
           scrubPreview.previewContentIndex == target,
           let content = scrubPreview.takeContent() {
            promoteScrubPreview(content, to: target)
            return
        }
        scrubPreview.remove()
        if target == currentIndex {
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
        } else if isDirectTap {
            pageScrubberTap(to: target)
        } else if style.scrubberStyle.animateScrubTransitions {
            pageMiniCardScrubber(to: target)
        } else {
            jump(to: target)
        }
    }

    /// Mini-card chips can expose a target outside the carousel's mounted ±1
    /// window. Stage that exact card and eclipse to it instead of revealing an
    /// immediate crossfade/layout pass.
    private func pageMiniCardScrubber(to target: Int) {
        if !UIAccessibility.isReduceMotionEnabled, view.window != nil {
            runEclipse(to: target)
        } else {
            jump(to: target)
        }
    }

    /// A direct chip tap always pages through the eclipse, on both the Reader's
    /// mini cards and the Downloader's thumbnails. Scroll-settle commits keep
    /// their live-preview promotion behavior.
    private func pageScrubberTap(to target: Int) {
        if !UIAccessibility.isReduceMotionEnabled, view.window != nil {
            runEclipse(to: target, duration: CardEclipseTransition.scrubberTapDuration)
        } else {
            jump(to: target)
        }
    }

    /// Commits a scrubbed media preview with no player swap: the preview's
    /// content controller becomes the real centered slot and keeps playing at
    /// its current timestamp. Only mute/Photos chrome fades into view.
    private func promoteScrubPreview(
        _ content: CardContentViewController,
        to target: Int
    ) {
        slots[currentIndex]?.content.cardDidLeaveCenter()

        if let replaced = slots[target] {
            unmount(replaced)
            slots[target] = nil
        }
        currentIndex = target

        let promoted = mount(index: target, existingContent: content)
        promoted.card.chromeAlpha = 0
        slots[target] = promoted

        let keep = Set((target - 1)...(target + 1))
        for slot in Array(slots.values) where !keep.contains(slot.index) {
            unmount(slot)
            slots[slot.index] = nil
        }
        mountWindow()
        applyMuteState()
        for slot in slots.values { applyRestingLayout(to: slot) }
        scrubber.setSelectedIndex(target, animated: true)
        if isViewVisible { content.cardDidBecomeCentered() }
        delegate?.carousel(self, didCenterCardAt: target)

        UIView.animate(
            withDuration: CarouselAnimationTiming.chromeFadeDuration, delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            promoted.card.chromeAlpha = 1
        }
    }

    private func loadAllThumbnails() {
        guard let dataSource else { return }
        stripLoadGeneration += 1
        let generation = stripLoadGeneration
        for index in 0..<count {
            switch style.scrubberStyle {
            case .thumbnails:
                dataSource.carousel(self, loadThumbnailForCardAt: index) { [weak self] image in
                    DispatchQueue.main.async {
                        guard let self, self.stripLoadGeneration == generation else { return }
                        self.scrubber.setThumbnail(image, at: index)
                    }
                }
            case .miniCards:
                dataSource.carousel(self, loadSourceBadgeForCardAt: index) { [weak self] badge in
                    DispatchQueue.main.async {
                        guard let self, self.stripLoadGeneration == generation else { return }
                        self.scrubber.setBadge(badge, at: index)
                    }
                }
            }
        }
    }

    // MARK: - Card gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard count > 0, !isTransitioning else { return }
        let location = gesture.location(in: cardArea)
        // The tap doesn't cancel touches, so a control (mute button, download
        // button) handles its own tap — don't double-trigger card behavior.
        if let hit = cardArea.hitTest(location, with: nil),
           sequence(first: hit, next: { [weak cardArea] in $0 === cardArea ? nil : $0.superview })
               .contains(where: { $0 is UIControl }) {
            return
        }
        // While immersed the centered card is bottom-extended past its resting
        // frame — use its live frame so taps land on the card, and never page
        // to the invisible (faded-away) neighbors.
        let center = isImmersed
            ? (slots[currentIndex]?.card.frame ?? centeredCardFrame())
            : centeredCardFrame()
        if center.contains(location) {
            guard let content = slots[currentIndex]?.content else { return }
            let contentPoint = cardArea.convert(location, to: content.view)
            guard content.allowsCardTap(at: contentPoint) else { return }
            if content.isPlayable {
                content.setPlaying(!content.isPlaying)
            } else {
                delegate?.carousel(self, didTapCenteredCardAt: currentIndex)
            }
        } else if !isImmersed, location.x > center.maxX {
            page(by: 1)
        } else if !isImmersed, location.x < center.minX {
            page(by: -1)
        }
    }

    /// Interactive paging: a horizontal drag starting on the insets beside the
    /// card drives the eclipse with the finger — play it forward, pull it back,
    /// release to finish or cancel.
    @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: cardArea).x * style.pageSwipeMovementMultiplier
        switch gesture.state {
        case .began:
            pagePanConsumed = false
        case .changed:
            if case .none = pagingTransition, !pagePanConsumed {
                beginInteractivePage(translation: translation)
            }
            guard case .interactive(let activeTransition) = pagingTransition else { return }
            activeTransition.update(fraction: abs(translation) / interactiveTravel)
        case .ended, .cancelled, .failed:
            guard case .interactive(let interactiveTransition) = pagingTransition
            else { return }
            let fraction = min(max(abs(translation) / interactiveTravel, 0), 1)
            let velocity = gesture.velocity(in: cardArea).x * style.pageSwipeMovementMultiplier
            // The drag direction and the paging direction are opposite signs
            // (dragging left brings the next card in from the right).
            let towardTarget = translation < 0 ? -velocity : velocity
            let shouldFinish = gesture.state == .ended
                && (fraction > 0.5 || (fraction > 0.08 && towardTarget > 350))
                && towardTarget > -350
            if shouldFinish {
                interactiveTransition.finishInteractive()
            } else {
                interactiveTransition.cancelInteractive()
            }
        default:
            break
        }
    }

    private func beginInteractivePage(translation: CGFloat) {
        guard abs(translation) > 0, let metrics else { return }
        let step = translation < 0 ? 1 : -1
        let target = currentIndex + step
        guard target >= 0, target < count else { return }
        if UIAccessibility.isReduceMotionEnabled || slots[target] == nil {
            // No interactive tracking — settle the gesture as a plain page.
            pagePanConsumed = true
            page(by: step)
            return
        }
        reportNavigationTarget(target)
        guard let transition = makeEclipseTransition(to: target) else { return }
        // Finger travel maps to the incoming card's journey from its peek slot
        // to center.
        interactiveTravel = max(
            abs(metrics.centerX(forSlotOffset: step) - metrics.centerX(forSlotOffset: 0)),
            1)
        pagingTransition = .interactive(transition)
    }

    private func reportNavigationTarget(_ index: Int) {
        delegate?.carousel(self, navigationTargetDidChangeTo: index)
    }

    @objc private func handleScrubPan(_ gesture: UIPanGestureRecognizer) {
        guard let metrics, let content = slots[currentIndex]?.content, content.isPlayable
        else { return }
        switch gesture.state {
        case .began:
            scrubStartFraction = content.playbackFraction
            wasPlayingBeforeScrub = content.isPlaying
            content.setPlaying(false)
            if content.showsPlaybackScrubProgress {
                showPlaybackScrubProgress(at: scrubStartFraction)
            }
        case .changed:
            let translation = gesture.translation(in: cardArea).x
            let fraction = scrubStartFraction + Double(translation / metrics.cardSize.width)
            content.seek(toFraction: fraction)
            updatePlaybackScrubProgress(to: fraction)
        case .ended, .cancelled, .failed:
            hidePlaybackScrubProgress()
            if wasPlayingBeforeScrub { content.setPlaying(true) }
        default:
            break
        }
    }

    // MARK: - Mute + audio session

    private func applyMuteState() {
        for slot in slots.values { slot.content.setMuted(audioSession.isMuted) }
        scrubPreview.setMuted(audioSession.isMuted)
        updateMuteUI()
    }

    private var isMuteButtonOccluded = false

    /// Temporarily removes the top-right audio control while a host-owned
    /// overlay covers the card. The content's mute state is unchanged.
    public func setMuteButtonOccluded(_ occluded: Bool) {
        guard isMuteButtonOccluded != occluded else { return }
        isMuteButtonOccluded = occluded
        updateMuteUI()
    }

    private func updateMuteUI() {
        for slot in slots.values {
            let isCenter = slot.index == currentIndex
            slot.card.setMuteButtonVisible(
                !isMuteButtonOccluded && isCenter && slot.content.supportsAudio)
            slot.card.updateMuteIcon(muted: audioSession.isMuted)
        }
    }
}

// MARK: - Gesture disambiguation

extension CardCarouselViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: cardArea)
        let insideCenter = centeredCardFrame().contains(location)
        if gestureRecognizer === playbackPan {
            // Pans inside the centered card scrub playback — horizontal only,
            // on scrubbable content.
            guard insideCenter,
                  let content = slots[currentIndex]?.content, content.isPlayable
            else { return false }
            let velocity = playbackPan.velocity(in: cardArea)
            return abs(velocity.x) > abs(velocity.y)
        }
        if gestureRecognizer === pagePan {
            let velocity = pagePan.velocity(in: cardArea)
            let decision = CardCarouselPagePanStartPolicy.decision(
                isTransitioning: isTransitioning,
                isImmersed: isImmersed,
                startsInsideCenteredCard: insideCenter,
                pagesOnInCardSwipes: style.pagesOnInCardSwipes,
                velocity: velocity)
            if decision == .acceptAndSurface {
                // Restore the resting card geometry before the same pan starts
                // manipulating it, so immersion never costs a second swipe.
                setImmersed(false, animated: false)
                delegate?.carouselDidSurfaceForEdgePaging(self)
            }
            return decision != .reject
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The in-card page pan and the additive tap must coexist with gestures
        // inside the embedded content (scroll views, links).
        if gestureRecognizer === pagePan {
            return style.pagesOnInCardSwipes
        }
        return gestureRecognizer is UITapGestureRecognizer
    }
}

// MARK: - Scrub strip

extension CardCarouselViewController: CarouselScrubberViewDelegate {

    public func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet) {
        guard case .miniCards = style.scrubberStyle else { return }
        scrubPreview.prepare(indices: indices, cardCount: count)
    }

    public func scrubber(_ scrubber: CarouselScrubberView, didPreview index: Int) {
        showScrubPreview(index)
    }

    public func scrubber(_ scrubber: CarouselScrubberView, didCommit index: Int) {
        commitScrub(to: index)
    }

    public func scrubber(_ scrubber: CarouselScrubberView, didTap index: Int) {
        commitScrub(to: index, isDirectTap: true)
    }
}

// MARK: - Card menus

extension CardCarouselViewController: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard count > 0, !isTransitioning,
              // Only the resting card deck differentiates text vs whitespace;
              // an immersed (chrome-hidden) card is pure reading — leave every
              // press to the content's own selection and link menus.
              !isImmersed,
              centeredCardFrame().contains(location)
        else { return nil }
        // A press the content claims (real text, a link, an inline image) is not
        // ours — decline so text selection or the content's own menu proceeds.
        if let content = slots[currentIndex]?.content,
           content.longPressSelectsContent(at: cardArea.convert(location, to: content.view)) {
            return nil
        }
        guard let menu = delegate?.carousel(self, menuForCardAt: currentIndex) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        cardHighlightPreview()
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        cardHighlightPreview()
    }

    /// Anchors the menu's lift to the centered card so the whole card-area view
    /// (which fills the screen) isn't what gets highlighted.
    private func cardHighlightPreview() -> UITargetedPreview? {
        guard let card = slots[currentIndex]?.card else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: card, parameters: parameters)
    }
}
