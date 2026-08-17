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
import LunaModels

public protocol CardCarouselDataSource: AnyObject {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int
    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController
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
    /// Optional artwork pinned over the bottom-trailing corner of a `.miniCards`
    /// thumbnail chip. Unlike the source badge, this never replaces the thumbnail.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadMiniCarouselAccessoryForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void)
    /// Whether this card's `.miniCards` chip should be its full-bleed still
    /// (`loadThumbnailForCardAt`) rather than a mini card with a source badge.
    /// True for a save whose card IS a picture — a media download in the
    /// all-kinds deck — so the chip mirrors the card above it instead of
    /// reducing a video to its host's favicon. A card that answers true but has
    /// no still yet falls back to its badge.
    func carousel(
        _ carousel: CardCarouselViewController,
        prefersThumbnailChipForCardAt index: Int
    ) -> Bool
    /// Whether this card's chip is a UTILITY chip: the icon supplied by
    /// `loadThumbnailForCardAt` centered over a single button pill, in place of
    /// both a save's still and a save's badge-and-skeleton mini card. True only
    /// for the deck's permanent util card, which holds no save to describe.
    /// Answered before `prefersThumbnailChipForCardAt`, and honoured by both
    /// scrubber styles.
    func carousel(
        _ carousel: CardCarouselViewController,
        prefersUtilityChipForCardAt index: Int
    ) -> Bool
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

    /// This card's own shape. Defaults to the deck's `style.card`, so a
    /// single-kind deck never implements it.
    func carousel(
        _ carousel: CardCarouselViewController,
        cardStyleForCardAt index: Int
    ) -> CardCarouselCardStyle
}

public extension CardCarouselDataSource {
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
        loadMiniCarouselAccessoryForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }

    func carousel(
        _ carousel: CardCarouselViewController,
        prefersThumbnailChipForCardAt index: Int
    ) -> Bool { false }

    func carousel(
        _ carousel: CardCarouselViewController,
        prefersUtilityChipForCardAt index: Int
    ) -> Bool { false }

    func carousel(
        _ carousel: CardCarouselViewController,
        cardStyleForCardAt index: Int
    ) -> CardCarouselCardStyle { carousel.style.card }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? { nil }

    func carousel(
        _ carousel: CardCarouselViewController,
        edgeGlowColorForCardAt index: Int
    ) -> UIColor? { nil }
}

/// How ONE card PRESENTS what it shows — the properties that are a fact about
/// the content rather than about the screen it is on.
///
/// A save presents the same way in every app: nothing about a downloaded video
/// changes when you open a different app, so nothing about its card does either.
///
/// **Card GEOMETRY is deliberately not in here.** Every card in every deck is
/// the one rectangle `CardCarouselMetrics.resolve` returns, so paging between
/// kinds never resizes or re-centers the card mid-transition.
public struct CardCarouselCardStyle: Hashable {
    /// Content dissolves over this many points at the card's top and bottom
    /// edges instead of hitting a hard clip — scrolled reader text fades away
    /// as it approaches an edge. 0 keeps the hard clip, which is what a video
    /// or a product editor wants.
    public var contentEdgeFadeHeight: CGFloat = 0
    /// Horizontal swipes INSIDE this card page to the neighbor, for content
    /// with no timeline of its own to scrub. Playable content overrides this
    /// at the moment of the gesture: its whole width IS a timeline.
    public var pagesOnInCardSwipes = false

    public init() {}
}

/// Per-surface tuning, set BEFORE the carousel's view loads.
///
/// **Nothing that decides the card's frame is per-surface.** `peek`, `edgeGap`,
/// `sideScale` and `verticalPadding` are constants on `CardCarouselMetrics`, so
/// one card frame serves every deck, every app, and the launch splash.
public struct CardCarouselStyle {
    /// The presentation EVERY card takes unless its own kind says otherwise. A
    /// deck whose cards are all one kind sets this and nothing else; a deck that
    /// mixes kinds leaves it and lets each card answer
    /// (`CardCarouselDataSource.carousel(_:cardStyleForCardAt:)`).
    public var card = CardCarouselCardStyle()
    /// Multiplies finger translation while interactively paging. Values above
    /// one make the eclipse transition travel farther than the physical drag.
    public var pageSwipeMovementMultiplier: CGFloat = 1
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
    /// While immersed, moves the centered card's mute toggle from the card's
    /// top-right corner to the screen's safe top-right corner. It keeps the
    /// same 12pt card inset in both positions and translates with the card's
    /// own immersion animation.
    public var movesMuteButtonToScreenEdgeWhenImmersed = false
    /// How far the paused card's playback controls sit in from the card's
    /// bottom and side edges — the mute button's inset from the top, so the
    /// card's floating controls all keep the same margin.
    static let playbackControlsCardInset: CGFloat = 12

    public init() {}

    /// The shared look for a deck whose every card is one kind — the
    /// Downloader's media deck and the Price Tracker's product deck: a
    /// slightly faster page swipe, the wider scrub-strip inset with its own
    /// edge fade (room for the flanking circles beside it), and a card
    /// border.
    public static var singleKindDeck: CardCarouselStyle {
        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        style.scrubberHorizontalInset = 56
        style.scrubberEdgeFadeWidth = 28
        style.showsCardBorder = true
        return style
    }
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
        centeredContentScrubs: Bool,
        velocity: CGPoint
    ) -> CardCarouselPagePanStartDecision {
        guard !isTransitioning else { return .reject }
        if startsInsideCenteredCard {
            // Immersed readers reserve in-card gestures for their content. A
            // screen-edge swipe remains the always-available paging affordance.
            // So does playable content, whose whole width is a TIMELINE: the
            // same drag already scrubs it, and one gesture cannot mean two
            // things at once (the all-kinds deck pages on in-card swipes for
            // its readers, but its video cards must scrub like the
            // Downloader's).
            guard !isImmersed, pagesOnInCardSwipes, !centeredContentScrubs,
                  abs(velocity.x) > abs(velocity.y) * 1.5
            else { return .reject }
            return .accept
        }
        guard abs(velocity.x) > abs(velocity.y) else { return .reject }
        return isImmersed ? .acceptAndSurface : .accept
    }
}

enum CardCarouselPagePanSimultaneityPolicy {
    /// Whether a gesture inside the card may run alongside the page pan.
    ///
    /// It normally must: the in-card page swipe only exists on surfaces whose
    /// cards are live readers, and those have to keep scrolling, tapping links
    /// and selecting text for every drag that does NOT become a page. The one
    /// exception is a scroll view asking to start while the page pan is already
    /// tracking the touch — that scroll would run under a deck the same finger
    /// is paging.
    static func allowsSimultaneousRecognition(
        pagesOnInCardSwipes: Bool,
        otherIsScrollViewPan: Bool,
        pagePanIsTrackingTheTouch: Bool
    ) -> Bool {
        guard pagesOnInCardSwipes else { return false }
        return !(otherIsScrollViewPan && pagePanIsTrackingTheTouch)
    }
}

enum CardCarouselScrollViews {
    /// Every scroll view inside `root`'s subtree, outermost first. A mounted
    /// reader card nests several (the article's own, a web frame's inside it),
    /// so the search cannot stop at the first hit.
    static func nested(in root: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        var frontier = [root]
        var next = 0
        while next < frontier.count {
            let view = frontier[next]
            next += 1
            if let scrollView = view as? UIScrollView { found.append(scrollView) }
            frontier.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// Named durations for the carousel's own non-eclipse animations (the eclipse
/// page transition timings live on `CardEclipseTransition`).
private enum CarouselAnimationTiming {
    /// `jump(to:)`'s crossfade between the current and target windows of
    /// mounted cards (Reduce Motion, scrub commits, multi-card jumps).
    static let crossfadeDuration: TimeInterval = 0.28
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
        coordinator.delegate = self
        return coordinator
    }()

    private struct Slot {
        let index: Int
        let card: CarouselCardView
        let content: CardContentViewController
    }

    private var slots: [Int: Slot] = [:]
    private var count = 0
    /// ONE resolved geometry for the current container size, shared by every
    /// card in the deck. Every card is the same rectangle
    /// (`CardCarouselMetrics.resolve`), which is also the rectangle the launch
    /// splash is drawn at (`CardDeckGeometry`).
    private var resolvedMetrics: CardCarouselMetrics?
    private var metricsContainerSize: CGSize = .zero

    /// The card geometry at the current container size, computed on first sight.
    private var metrics: CardCarouselMetrics? {
        guard metricsContainerSize.width > 0, metricsContainerSize.height > 0 else { return nil }
        if let resolvedMetrics { return resolvedMetrics }
        let resolved = CardCarouselMetrics.resolve(containerSize: metricsContainerSize)
        resolvedMetrics = resolved
        return resolved
    }

    /// The per-card presentation style of card `index`, as its kind describes
    /// it. Its GEOMETRY is not in here — that is the deck's, and it is one
    /// answer for every card.
    func cardStyle(at index: Int) -> CardCarouselCardStyle {
        dataSource?.carousel(self, cardStyleForCardAt: index) ?? style.card
    }
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
    private var scrubberLeadingConstraint: NSLayoutConstraint!
    private var scrubberTrailingConstraint: NSLayoutConstraint!
    private lazy var scrubber = CarouselScrubberView()
    private lazy var scrubPreview = CarouselScrubPreviewController(carousel: self, cardArea: cardArea)
    /// True while the scrub strip's live preview is drawing the deck. The real
    /// slots stay mounted (and keep their content alive) but hide underneath it.
    private var isShowingScrubPreview = false
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
    /// True from the moment a page pan is accepted until the touch leaves. The
    /// transition it drives is created one touch-move later, so `isTransitioning`
    /// alone leaves a frame in which the deck still takes immersion changes from
    /// a card the same gesture is already paging away.
    private(set) var isPagingGesture = false

    private var scrubStartFraction: Double = 0
    private var wasPlayingBeforeScrub = false
    private let playbackScrubProgress = MoonHorizonProgressBar()
    private let playbackSpeedPill = PlaybackSpeedPillButton()
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
        playbackScrubProgress.accessibilityLabel = L10n.string("CardDeck_videoPositionAccessibilityLabel")
        cardArea.addSubview(playbackScrubProgress)
        playbackSpeedPill.alpha = 0
        playbackSpeedPill.isHidden = true
        playbackSpeedPill.delegate = self
        cardArea.addSubview(playbackSpeedPill)
        cardAreaTopConstraint = cardArea.topAnchor.constraint(equalTo: view.topAnchor)
        scrubberLeadingConstraint = scrubber.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: style.scrubberHorizontalInset)
        scrubberTrailingConstraint = scrubber.trailingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: -style.scrubberHorizontalInset)
        NSLayoutConstraint.activate([
            scrubberLeadingConstraint,
            scrubberTrailingConstraint,
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
        if metricsContainerSize != size {
            metricsContainerSize = size
            resolvedMetrics = nil
        }
        alignScrubberToCardColumn()
        // Render the eclipse corona for this exact card geometry now, in the
        // background, rather than on whichever tap first starts a transition.
        EclipseCorona.prewarm(
            bodySize: centeredCardFrame().size,
            cornerRadius: CarouselCardView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint)
        guard !isTransitioning else { return }
        for slot in slots.values { applyRestingLayout(to: slot) }
        scrubPreview.layout()
        layoutPlaybackScrubProgress()
        updatePlaybackControls()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        audioSession.startVolumeObservation()
        slots[currentIndex]?.content.cardDidBecomeCentered()
        updatePlaybackControls()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        audioSession.stopVolumeObservation()
        // A lifecycle interruption must not leave eclipse dressing frozen over
        // the next appearance. `cancel()` settles according to whether totality
        // already committed the page turn.
        pagingTransition.transition?.cancel()
        slots[currentIndex]?.content.cardDidLeaveCenter()
        updatePlaybackControls()
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
        clearScrubPreview()
        setImmersed(false)
        count = dataSource?.numberOfCards(in: self) ?? 0
        let target = min(max(index ?? currentIndex, 0), max(0, count - 1))
        for slot in slots.values { unmount(slot) }
        slots = [:]
        currentIndex = target
        mountWindow()
        removeOrphanCardViews()
        stripLoadGeneration += 1
        scrubber.setThumbnailCount(count)
        guard count > 0 else {
            updatePlaybackControls()
            return
        }
        scrubber.setSelectedIndex(currentIndex, animated: false)
        applyMuteState()
        if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
        updatePlaybackControls()
        delegate?.carousel(self, didCenterCardAt: currentIndex)
    }

    /// On a wide container the card no longer spans the screen, so a scrub strip
    /// still pinned to the screen edges would run out from under it on both
    /// sides and stop reading as this deck's own control. It follows the card's
    /// column instead, keeping the exact clearance it has on a phone: the strip
    /// is inset from the card's edges by however much `scrubberHorizontalInset`
    /// exceeds the card's own `peek + edgeGap` inset there.
    ///
    /// Phone-shaped containers are left literally alone — the style's inset from
    /// the screen edges, as before.
    private func alignScrubberToCardColumn() {
        let inset: CGFloat
        if LunaLayout.isWide(containerWidth: view.bounds.width), let metrics {
            // The card area spans the view's full width, so the metrics' own x is
            // already this view's x — and deliberately WITHOUT the column-aside
            // shift, which the strip carries as its own transform instead. Going
            // through `restingCenteredCardFrame` here would apply it twice.
            let clearanceInsideCard = style.scrubberHorizontalInset
                - (CardCarouselMetrics.peek + CardCarouselMetrics.edgeGap)
            inset = max(0, metrics.centeredCardFrame().minX + clearanceInsideCard)
        } else {
            inset = style.scrubberHorizontalInset
        }
        guard abs(scrubberLeadingConstraint.constant - inset) > 0.5 else { return }
        scrubberLeadingConstraint.constant = inset
        scrubberTrailingConstraint.constant = -inset
    }

    /// The centered card's resting horizontal bounds in `target`'s space, or the
    /// container's own when the metrics haven't resolved yet. Hosts that flank
    /// the deck with floating controls anchor them to this so those controls stay
    /// beside the CARD rather than stranded at the edges of a wide screen.
    public func restingCardColumn(in target: UIView) -> ClosedRange<CGFloat> {
        guard let frame = restingCenteredCardFrame(in: target) else {
            return target.bounds.minX...target.bounds.maxX
        }
        return frame.minX...frame.maxX
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
    /// they are. A caller may opt the immersed card into a near-full-width
    /// viewport with `horizontalInset`; this is used only by the large-screen
    /// scrolling Reader.
    public private(set) var isImmersed = false

    /// Whether the current immersion extends the centered card's bottom edge
    /// into the room the faded strip frees up. Content that keeps a fixed
    /// layout (the RSVP reader) immerses WITHOUT the extension, so nothing
    /// inside the card moves — only the chrome fades.
    private var immersionExtendsCard = true

    /// Nil keeps the centered card's resting width. A value expands it to the
    /// carousel bounds with this much breathing room on either side.
    private var immersionHorizontalInset: CGFloat?

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

    /// Whether the carousel now carries `immersed`. It refuses — and answers
    /// false — while a page turn owns the deck. A host that fades screen-level
    /// chrome of its own MUST leave that chrome alone on a refusal: the deck
    /// and the screen around it would otherwise disagree about the same state,
    /// and the half the deck refused (the footer veil) stays raised over a deck
    /// that is not immersed at all.
    @discardableResult
    public func setImmersed(
        _ immersed: Bool,
        extendsCard: Bool = true,
        horizontalInset: CGFloat? = nil,
        animated: Bool = false
    ) -> Bool {
        // A page turn starts un-immersed: an edge page pan first surfaces the
        // carousel synchronously. Immersing again mid-turn — a reader still
        // decelerating from a flick keeps reporting its travel through the
        // swipe that pages it away — would fight the eclipse over the same
        // cards, so the deck refuses for as long as the turn owns it. The
        // gesture counts from the moment it is accepted, not from the
        // transition it creates one touch-move later: immersion landing in that
        // gap fades the INCOMING card, which then arrives at centre invisible.
        // Surfacing is never refused; a reload asks for it unconditionally.
        guard !immersed || !(isPagingGesture || isTransitioning) else { return false }
        let resolvedHorizontalInset = immersed ? horizontalInset.map { max(0, $0) } : nil
        if immersed == isImmersed {
            // Already immersed but the extension mode changed (e.g. a mode
            // switch from scroll to RSVP mid-immersion) — re-apply the card
            // frame without re-reporting the unchanged immersion state.
            guard immersed,
                  immersionExtendsCard != extendsCard
                    || immersionHorizontalInset != resolvedHorizontalInset
            else { return true }
            immersionExtendsCard = extendsCard
            immersionHorizontalInset = resolvedHorizontalInset
            if animated {
                prepareCenteredContentForImmersionLayout()
                let transitioningContent = slots[currentIndex]?.content
                UIView.animate(
                    withDuration: 0.32, delay: 0,
                    options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        self.applyImmersionLayout()
                        transitioningContent?.animatePreparedCardViewportTransition()
                    },
                    completion: { completed in
                        transitioningContent?.finishCardViewportTransition(completed: completed)
                    })
            } else {
                applyImmersionLayout()
            }
            return true
        }
        isImmersed = immersed
        immersionExtendsCard = extendsCard
        immersionHorizontalInset = resolvedHorizontalInset
        scrubber.isUserInteractionEnabled = !immersed && !isColumnAside
        // Immersion hands the runway under the card to the reader's own chrome.
        updatePlaybackControls()
        if animated {
            prepareCenteredContentForImmersionLayout()
            let transitioningContent = slots[currentIndex]?.content
            UIView.animate(
                withDuration: 0.32, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.applyImmersionLayout()
                    transitioningContent?.animatePreparedCardViewportTransition()
                },
                completion: { completed in
                    transitioningContent?.finishCardViewportTransition(completed: completed)
                })
        } else {
            applyImmersionLayout()
        }
        return true
    }

    // MARK: - Column aside (making room for a second card)

    /// How far the whole deck has stepped sideways to make room for a second
    /// card beside it — the side-by-side inline reader's left column. Zero at
    /// rest.
    ///
    /// Deliberately NOT immersion: the card keeps its chrome, its rim, its
    /// resting geometry, and every touch. Only its neighbours leave, because
    /// they would otherwise sit underneath the new column. Because
    /// `restingCenteredCardFrame` reports the shifted frame, host chrome
    /// anchored to the card travels with it for free.
    public private(set) var columnAsideShift: CGFloat = 0

    private var isColumnAside: Bool { abs(columnAsideShift) > 0.5 }

    /// Steps the deck aside by `shift` (negative moves it left). The animation
    /// is the same spring the archive tray uses, so a host animating its own
    /// chrome alongside can simply lay out inside this call's animation block.
    public func setColumnAside(shift: CGFloat, animated: Bool = false) {
        loadViewIfNeeded()
        guard abs(shift - columnAsideShift) > 0.5 else { return }
        columnAsideShift = shift
        scrubber.isUserInteractionEnabled = !isImmersed && !isColumnAside
        updatePlaybackControls()
        let changes = { self.applyColumnAsideLayout() }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.36, delay: 0,
            usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes)
    }

    private func applyColumnAsideLayout() {
        cardArea.transform = CGAffineTransform(translationX: columnAsideShift, y: 0)
        applyScrubberTransform()
        applyCardVisibility()
    }

    /// Which cards the deck shows in its current state. Immersion and the column
    /// shift retire the PEEKS; the live scrub preview draws its own deck and
    /// hides them all.
    ///
    /// Applied to every slot, the centered one included, so "the card at centre
    /// is visible" holds however the deck arrived at this state. Written as the
    /// peeks only, a card that faded as a peek and then became the centered card
    /// under an immersed deck kept its alpha of 0 — a black hole where the card
    /// should be, which nothing restored until it left centre again.
    private func applyCardVisibility() {
        let retiresPeeks = isImmersed || isColumnAside
        for slot in slots.values {
            let isCentered = slot.index == currentIndex
            slot.card.alpha = isShowingScrubPreview || (retiresPeeks && !isCentered) ? 0 : 1
        }
    }

    /// The strip's two independent offsets composed in one place: the column
    /// shift that carries it sideways with the card, and immersion's short
    /// downward drift as it hands the bottom lane to the reader's mode switcher.
    private func applyScrubberTransform() {
        let drift: CGFloat = isImmersed && !UIAccessibility.isReduceMotionEnabled ? 8 : 0
        scrubber.transform = CGAffineTransform(translationX: columnAsideShift, y: drift)
    }

    private func applyImmersionLayout() {
        scrubber.alpha = isImmersed ? 0 : 1
        // A host-owned backdrop (the starfield) counts as carousel chrome, so it
        // leaves and returns on the same curve as the strip and the side cards.
        chromeBackdrop?.alpha = isImmersed ? 0 : 1
        // The Reader replaces this bottom-center strip with its mode switcher
        // during immersion. A short downward drift makes that handoff read as
        // one control yielding the lane to the other instead of a hard swap.
        applyScrubberTransform()
        applyCardVisibility()
        // The centered card's content stays fully visible while immersed — its
        // glass rim fades in step with the strip and side cards, and its
        // surface tone clears so the content edge fades dissolve into the
        // screen background rather than a card-toned band.
        slots[currentIndex]?.card.borderAlpha = isImmersed ? 0 : 1
        slots[currentIndex]?.card.setSurfaceHidden(isImmersed)
        guard let metrics, let slot = slots[currentIndex] else { return }
        let resting = metrics.centeredCardFrame()
        var frame = resting
        if isImmersed, let horizontalInset = immersionHorizontalInset {
            let target = view.convert(view.bounds, to: cardArea)
            let width = max(1, target.width - horizontalInset * 2)
            frame.origin.x = target.midX - width / 2
            frame.size.width = width
        }
        if isImmersed, immersionExtendsCard {
            // Extend only the bottom edge to the carousel view's bottom (the
            // room the faded scrub strip frees up).
            let target = view.convert(view.bounds, to: cardArea)
            frame.size.height = max(target.maxY - resting.minY, resting.height)
        }
        slot.card.transform = .identity
        slot.card.bounds = CGRect(origin: .zero, size: frame.size)
        slot.card.center = CGPoint(x: frame.midX, y: frame.midY)
        // Resolve every nested content frame at the destination inside the
        // same animation transaction. Reader text animates independently, but
        // its clipping viewport must share the card's exact interpolation.
        slot.card.layoutIfNeeded()
        updateCenteredMuteButtonPosition()
        // The card must ride above its (fading) peeking neighbors.
        if isImmersed { cardArea.bringSubviewToFront(slot.card) }
    }

    /// The Reader's immersive viewport needs the audio control outside its
    /// scrollable card. Calculate a translation from the card's destination
    /// frame, rather than changing its constraints, so it interpolates in the
    /// same transaction as the card frame and returns exactly with it.
    private func updateCenteredMuteButtonPosition() {
        guard let card = slots[currentIndex]?.card else { return }
        guard isImmersed, style.movesMuteButtonToScreenEdgeWhenImmersed else {
            card.setMuteButtonTranslation(.zero)
            return
        }

        let cardFrame = card.convert(card.bounds, to: view)
        card.setMuteButtonTranslation(CGPoint(
            x: view.bounds.maxX - cardFrame.maxX,
            y: view.safeAreaInsets.top - cardFrame.minY))
    }

    /// Resolve the destination frame before UIKit starts interpolating the
    /// card, so text content can prepare a true old-layout → new-layout reflow.
    private func prepareCenteredContentForImmersionLayout() {
        guard let metrics, let slot = slots[currentIndex] else { return }
        var frame = metrics.centeredCardFrame()
        if isImmersed, let horizontalInset = immersionHorizontalInset {
            let target = view.convert(view.bounds, to: cardArea)
            let width = max(1, target.width - horizontalInset * 2)
            frame.origin.x = target.midX - width / 2
            frame.size.width = width
        }
        if isImmersed, immersionExtendsCard {
            let target = view.convert(view.bounds, to: cardArea)
            frame.size.height = max(target.maxY - frame.minY, frame.height)
        }
        slot.content.prepareForCardViewportTransition(to: frame.size)
    }

    /// Pages by `step` cards. Single steps run the eclipse transition (unless
    /// Reduce Motion or off-window); anything else is a crossfade jump.
    public func page(by step: Int, completion: (() -> Void)? = nil) {
        let target = min(max(currentIndex + step, 0), max(0, count - 1))
        guard count > 0, target != currentIndex, !isTransitioning, !isImmersed,
              !isColumnAside
        else {
            completion?()
            return
        }
        reportNavigationTarget(target)
        if abs(target - currentIndex) == 1,
           !UIAccessibility.isReduceMotionEnabled,
           view.window != nil,
           slots[target] != nil {
            runEclipse(to: target, completion: completion)
        } else {
            jump(to: target, completion: completion)
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
        let card = makeCardView(at: index)
        card.installContentView(content.view)
        content.setMuted(audioSession.isMuted)
        content.audioAvailabilityObserver = self
        content.playbackObserver = self
        cardArea.addSubview(card)
        content.didMove(toParent: self)
        return Slot(index: index, card: card, content: content)
    }

    /// A bare card surface wearing card `index`'s chrome: the host's rim and
    /// edge-fade style, this card's failure glow, its top-leading accessory,
    /// and the shared mute toggle.
    private func makeCardView(at index: Int) -> CarouselCardView {
        let card = CarouselCardView()
        card.setBorderEnabled(style.showsCardBorder)
        card.setContentEdgeFadeHeight(cardStyle(at: index).contentEdgeFadeHeight)
        card.setEdgeGlow(dataSource?.carousel(self, edgeGlowColorForCardAt: index))
        card.delegate = self
        card.setTopLeadingAccessory(dataSource?.carousel(
            self, topLeadingAccessoryForCardAt: index))
        return card
    }

    /// The scrub preview's cards are the real thing: same chrome, same
    /// geometry, so nothing about the deck changes shape when the finger
    /// touches the strip or lets go of it. The preview controller owns where
    /// they are mounted.
    func makeScrubPreviewCard(at index: Int) -> CarouselCardView {
        makeCardView(at: index)
    }

    /// Whether the card showing `content` should offer the mute button.
    func showsMuteButton(for content: CardContentViewController?) -> Bool {
        !isMuteButtonOccluded && content?.supportsAudio == true
    }

    private func unmount(_ slot: Slot) {
        // A retiring card must not drive the deck's chrome on its way out.
        slot.content.playbackObserver = nil
        slot.content.setPlaying(false)
        slot.content.willMove(toParent: nil)
        slot.card.removeFromSuperview()
        slot.content.view.removeFromSuperview()
        slot.content.removeFromParent()
    }

    private func applyRestingLayout(to slot: Slot, atSlotOffset stagedOffset: Int? = nil) {
        guard metrics != nil else { return }
        if slot.index == currentIndex, isImmersed {
            applyImmersionLayout()
            return
        }
        let offset = stagedOffset ?? (slot.index - currentIndex)
        applyRestingLayout(to: slot.card, atSlotOffset: offset)
        // A live scrub preview draws the whole deck itself; the real cards
        // stand aside for it rather than showing the committed card's window.
        // A deck stepped aside for a second column keeps only its centered card:
        // the peeks would land underneath that column.
        slot.card.alpha = isImmersed || isShowingScrubPreview
            || (isColumnAside && offset != 0) ? 0 : 1
        updateMuteUI()
    }

    /// The resting geometry of the card `offset` slots from center — shared by
    /// the mounted slots and the scrub preview's stand-in cards.
    ///
    /// Size and vertical placement are the deck's single answer for every card;
    /// only the horizontal step depends on which slot this is.
    func applyRestingLayout(
        to card: CarouselCardView, atSlotOffset offset: Int
    ) {
        guard let metrics else { return }
        card.layer.cornerRadius = CarouselCardView.cornerRadius
        card.borderAlpha = 1
        card.setSurfaceHidden(false)
        card.transform = .identity
        card.bounds = CGRect(origin: .zero, size: metrics.cardSize)
        card.center = CGPoint(
            x: metrics.centerX(forSlotOffset: offset),
            y: metrics.centerY())
        card.transform = CGAffineTransform(
            scaleX: metrics.scale(forSlotOffset: offset),
            y: metrics.scale(forSlotOffset: offset))
        card.dimAlpha = offset == 0 ? 0 : CarouselCardView.restingDimAlpha
        card.setMuteButtonTranslation(.zero)
    }

    /// Removes any card view left in the hierarchy that no mounted slot owns —
    /// a structural guarantee that no card can appear twice, whatever the
    /// interleaving of reloads and transitions.
    private func removeOrphanCardViews() {
        let live = Set(slots.values.map { ObjectIdentifier($0.card) })
            .union(scrubPreview.liveCardIdentifiers)
        for subview in cardArea.subviews
        where subview is CarouselCardView && !live.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }
    }

    private func centeredCardFrame() -> CGRect {
        metrics?.centeredCardFrame() ?? .zero
    }

    /// Whether a horizontal drag starting at `point` (in `space`'s coordinates)
    /// belongs to the centered card's own content: playable content treats its
    /// whole width as a timeline and scrubs there. Screen-level drawers ask this
    /// before starting a pull, so a video card's scrub is never ALSO a tray pull
    /// — the same gesture cannot mean two things at once.
    public func centeredCardConsumesHorizontalDrag(at point: CGPoint, in space: UIView) -> Bool {
        guard count > 0, !isTransitioning,
              let slot = slots[currentIndex], slot.content.isPlayable
        else { return false }
        // While immersed the centered card is bottom-extended past its resting
        // frame, so use its live frame (as the card tap does).
        let frame = isImmersed ? slot.card.frame : centeredCardFrame()
        return frame.contains(space.convert(point, to: cardArea))
    }

    private func layoutPlaybackScrubProgress() {
        guard let metrics else { return }
        let height = playbackScrubProgress.intrinsicContentSize.height
        let bar = metrics.playbackScrubProgressFrame(
            bottomInset: CardCarouselStyle.playbackControlsCardInset, height: height)
        playbackScrubProgress.frame = bar
        // The speed pill rides above the bar's LEFT end — so the two read as one
        // stack of controls floating inside the card's bottom edge.
        let pill = playbackSpeedPill.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize)
        playbackSpeedPill.frame = CGRect(
            x: bar.minX,
            y: bar.minY - 8 - pill.height,
            width: pill.width,
            height: pill.height)
    }

    // MARK: - Playback controls (paused card)

    /// The centered card's content when it is a paused timeline at rest — the
    /// one state that shows playback controls.
    ///
    /// "At rest" is the point of the guards: a card paged away is paused too,
    /// and a transition, a live scrub preview, immersion or a stepped-aside
    /// column would all draw the controls over, or beside, a card that has left
    /// its resting frame.
    private func pausedPlaybackContent() -> CardContentViewController? {
        guard isViewVisible, !isTransitioning, !isShowingScrubPreview,
              !isImmersed, !isColumnAside,
              let content = slots[currentIndex]?.content,
              content.isPlayable, !content.isPlaying,
              content.showsPlaybackScrubProgress
        else { return nil }
        return content
    }

    /// Brings the paused card's controls up (or takes them down) to match the
    /// current state. Called from every point that can change it, including the
    /// content's own play-state report.
    private func updatePlaybackControls() {
        guard let content = pausedPlaybackContent() else {
            hidePlaybackControls()
            return
        }
        showPlaybackControls(
            at: content.playbackFraction,
            speed: content.supportsPlaybackSpeed ? content.playbackSpeed : nil)
    }

    /// `speed` nil means this content plays at one rate only — no pill.
    private func showPlaybackControls(at fraction: Double, speed: Double?) {
        playbackScrubPresentation += 1
        playbackScrubProgress.layer.removeAllAnimations()
        playbackScrubProgress.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
        let wasHidden = playbackScrubProgress.isHidden
        playbackScrubProgress.isHidden = false
        if wasHidden { playbackScrubProgress.alpha = 0 }
        cardArea.bringSubviewToFront(playbackScrubProgress)
        if let speed {
            playbackSpeedPill.speed = speed
            if playbackSpeedPill.isHidden {
                playbackSpeedPill.isHidden = false
                playbackSpeedPill.alpha = 0
            }
            cardArea.bringSubviewToFront(playbackSpeedPill)
        }
        layoutPlaybackScrubProgress()
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.playbackScrubProgress.alpha = 1
            self.playbackSpeedPill.alpha = speed == nil ? 0 : 1
        } completion: { [weak self] _ in
            guard let self, speed == nil else { return }
            self.playbackSpeedPill.isHidden = true
        }
    }

    #if DEBUG
    /// Holds the deck in the state an ACCEPTED page swipe leaves it in — before
    /// the transition that swipe creates exists. A test cannot synthesise the
    /// touch that gets there, and that one frame is where a decelerating reader
    /// used to immerse the deck into its own page turn.
    func setPagingGestureForTesting(_ active: Bool) { isPagingGesture = active }

    /// The chrome is faded out before it is hidden (the flag lands in the fade's
    /// completion), so `alpha` — set on the model layer immediately — is what
    /// "showing" means synchronously.
    var isPlaybackPositionBarShowingForTesting: Bool {
        !playbackScrubProgress.isHidden && playbackScrubProgress.alpha > 0
    }

    var playbackSpeedPillForTesting: PlaybackSpeedPillButton? {
        playbackSpeedPill.isHidden || playbackSpeedPill.alpha == 0 ? nil : playbackSpeedPill
    }

    /// The bar's frame in card-area coordinates, for geometry tests. Nil while
    /// the controls are down.
    var playbackScrubBarFrameForTesting: CGRect? {
        isPlaybackPositionBarShowingForTesting ? playbackScrubProgress.frame : nil
    }

    var playbackSpeedPillFrameForTesting: CGRect? {
        playbackSpeedPillForTesting?.frame
    }
    #endif

    private func updatePlaybackScrubProgress(to fraction: Double) {
        guard !playbackScrubProgress.isHidden else { return }
        playbackScrubProgress.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
    }

    private func hidePlaybackControls() {
        guard !playbackScrubProgress.isHidden || !playbackSpeedPill.isHidden else { return }
        playbackScrubPresentation += 1
        let presentation = playbackScrubPresentation
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.playbackScrubProgress.alpha = 0
            self.playbackSpeedPill.alpha = 0
        } completion: { [weak self] finished in
            guard let self, finished, presentation == self.playbackScrubPresentation else { return }
            self.playbackScrubProgress.isHidden = true
            self.playbackSpeedPill.isHidden = true
        }
    }

    // MARK: - Paging

    private func runEclipse(
        to target: Int,
        duration: TimeInterval = CardEclipseTransition.duration,
        completion: (() -> Void)? = nil
    ) {
        guard let transition = makeEclipseTransition(
            to: target, duration: duration, completion: completion)
        else {
            jump(to: target, completion: completion)
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
        duration: TimeInterval = CardEclipseTransition.duration,
        completion: (() -> Void)? = nil
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
        // The outgoing card's controls leave WITH it, before the eclipse starts —
        // they belong to a card at rest, and the pause that retires them at the
        // zenith is no state change at all (the card was already paused).
        updatePlaybackControls()

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
            completion: { [weak self] finished in
                self?.settleAfterTransition(
                    finished: finished, outgoing: outgoing, completion: completion)
            })
        pagingTransition = .automatic(transition)
        return transition
    }

    /// Runs after a transition finishes OR cancels: restores interactivity,
    /// applies resting layout, and picks up a reload that arrived mid-flight.
    private func settleAfterTransition(
        finished: Bool,
        outgoing: Slot,
        completion: (() -> Void)?
    ) {
        isTransitioning = false
        pagingTransition = .none
        view.isUserInteractionEnabled = true
        if finished { outgoing.content.cardDidLeaveCenter() }

        // Building/tearing down the new three-card window can construct a full
        // reader or query a backing store. It happens only after the eclipse's
        // egress is gone, never under its peak frames.
        let keep = Set((currentIndex - 1)...(currentIndex + 1))
        for slot in Array(slots.values) where !keep.contains(slot.index) {
            unmount(slot)
            slots[slot.index] = nil
        }
        mountWindow()
        for slot in slots.values { slot.card.isHidden = false }
        for slot in slots.values { applyRestingLayout(to: slot) }
        removeOrphanCardViews()
        // Restores target-dependent chrome when an interactive page reverses,
        // and confirms the new target after a successful transition.
        reportNavigationTarget(currentIndex)
        if finished {
            applyMuteState()
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
            delegate?.carousel(self, didCenterCardAt: currentIndex)
        }
        updatePlaybackControls()
        if case .pending(let centerIndex) = pendingReload {
            pendingReload = .none
            reloadData(centeringAt: centerIndex)
        }
        completion?()
    }

    /// Behind the eclipse's total-coverage veil: retire the far peek, move the
    /// outgoing card to the opposite slot, and mount the next card on the side
    /// the incoming card vacated.
    private func performZenithSwap(
        outgoing: Slot,
        step: Int,
        opposite: Slot?
    ) -> CardEclipseZenithResult {
        opposite?.card.isHidden = true
        currentIndex += step

        applyRestingLayout(to: outgoing)
        return CardEclipseZenithResult(reappearingPeeks: [outgoing.card])
    }

    /// A non-adjacent target is already the moon crossing the current card.
    /// At totality, keep that exact target centered, retire cards outside its
    /// new three-card window, and lay out both new peeks while they are hidden.
    private func performZenithJump(
        outgoing: Slot,
        incoming: Slot,
        target: Int
    ) -> CardEclipseZenithResult {
        for slot in slots.values where slot.index != incoming.index {
            slot.card.isHidden = true
        }
        currentIndex = target
        return CardEclipseZenithResult(reappearingPeeks: [])
    }

    /// Non-eclipse move (Reduce Motion, off-window updates, and generic
    /// multi-card jumps).
    private func jump(to target: Int, completion: (() -> Void)? = nil) {
        guard target != currentIndex, !isTransitioning else {
            completion?()
            return
        }
        slots[currentIndex]?.content.cardDidLeaveCenter()
        currentIndex = target
        updatePlaybackControls()
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
        } completion: { _ in completion?() }
        applyMuteState()
        if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
        updatePlaybackControls()
        scrubber.setSelectedIndex(currentIndex, animated: true)
        delegate?.carousel(self, didCenterCardAt: currentIndex)
    }

    // MARK: - Scrub-strip preview

    private func showScrubPreview(_ index: Int) {
        guard count > 0, !isTransitioning else { return }
        reportNavigationTarget(index)
        slots[currentIndex]?.content.setPlaying(false)
        isShowingScrubPreview = true
        scrubPreview.show(at: index, cardCount: count)
        // The preview owns the deck for the duration of the gesture.
        for slot in slots.values { slot.card.alpha = 0 }
        updatePlaybackControls()
    }

    /// Tears the preview down and gives the real cards the deck back.
    private func clearScrubPreview() {
        scrubPreview.remove()
        guard isShowingScrubPreview else { return }
        isShowingScrubPreview = false
        for slot in slots.values { applyRestingLayout(to: slot) }
        updatePlaybackControls()
    }

    private func commitScrub(to index: Int, isDirectTap: Bool = false) {
        guard count > 0, !isTransitioning else { return }
        let target = min(max(index, 0), count - 1)
        reportNavigationTarget(target)
        guard isDirectTap else {
            settleScrub(to: target)
            return
        }
        clearScrubPreview()
        if target == currentIndex {
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
        } else {
            pageScrubberTap(to: target)
        }
    }

    /// Releasing the strip is not a page turn: the settled card is ALREADY on
    /// screen as the live preview, so the commit hands the deck back
    /// underneath it and lifts the preview off. Never the eclipse — that
    /// belongs to the gestures that do travel between cards (a card swipe, a
    /// direct chip tap). This holds for every card, whether or not the preview
    /// managed to mount its real content: a media save, whose player the strip
    /// deliberately does not build per chip, previewed as its poster and must
    /// still settle as quietly as an article does.
    private func settleScrub(to target: Int) {
        guard target != currentIndex else {
            clearScrubPreview()
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
            return
        }
        settleScrubPreview(to: target)
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

    /// Commits a lightweight scrub preview. The real target is mounted only
    /// now that the strip has settled; the preview remains above it until the
    /// new three-card window is laid out, keeping the handover visually quiet.
    private func settleScrubPreview(to target: Int) {
        slots[currentIndex]?.content.cardDidLeaveCenter()
        currentIndex = target

        let keep = Set((target - 1)...(target + 1))
        for slot in Array(slots.values) where !keep.contains(slot.index) {
            unmount(slot)
            slots[slot.index] = nil
        }
        mountWindow()
        applyMuteState()
        isShowingScrubPreview = false
        for slot in slots.values { applyRestingLayout(to: slot) }
        scrubPreview.remove()
        scrubber.setSelectedIndex(target, animated: true)
        if isViewVisible { slots[target]?.content.cardDidBecomeCentered() }
        delegate?.carousel(self, didCenterCardAt: target)
    }

    private func loadStripVisuals(for indices: IndexSet) {
        guard let dataSource else { return }
        let generation = stripLoadGeneration
        for index in indices where index >= 0 && index < count {
            if dataSource.carousel(self, prefersUtilityChipForCardAt: index) {
                loadUtilityChip(at: index, generation: generation)
                continue
            }
            // One strip in every app; what differs is the CHIP, and that is a
            // per-card answer — a media save shows its own still, an article a
            // mini card with its source badge.
            if dataSource.carousel(self, prefersThumbnailChipForCardAt: index) {
                loadThumbnailChip(at: index, generation: generation)
            } else {
                loadBadgeChip(at: index, generation: generation)
            }
            loadMiniCarouselAccessory(at: index, generation: generation)
        }
    }

    /// A picture chip for a `.miniCards` strip. A save that wants one but has
    /// no still yet (an undownloaded video, say) keeps the mini card and its
    /// badge rather than showing an empty well.
    private func loadThumbnailChip(at index: Int, generation: Int) {
        dataSource?.carousel(self, loadThumbnailForCardAt: index) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.stripLoadGeneration == generation else { return }
                guard let image else {
                    self.loadBadgeChip(at: index, generation: generation)
                    return
                }
                self.scrubber.setThumbnail(image, at: index)
            }
        }
    }

    /// The util card's chip: its icon over a button pill, in either style.
    private func loadUtilityChip(at index: Int, generation: Int) {
        dataSource?.carousel(self, loadThumbnailForCardAt: index) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.stripLoadGeneration == generation else { return }
                self.scrubber.setUtilityChip(icon: image, at: index)
            }
        }
    }

    private func loadBadgeChip(at index: Int, generation: Int) {
        dataSource?.carousel(self, loadSourceBadgeForCardAt: index) { [weak self] badge in
            DispatchQueue.main.async {
                guard let self, self.stripLoadGeneration == generation else { return }
                self.scrubber.setBadge(badge, at: index)
            }
        }
    }

    private func loadMiniCarouselAccessory(at index: Int, generation: Int) {
        dataSource?.carousel(
            self, loadMiniCarouselAccessoryForCardAt: index
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.stripLoadGeneration == generation else { return }
                self.scrubber.setAccessoryImage(image, at: index)
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
            relinquishScrollingClaimedByPagePan()
        case .changed:
            if case .none = pagingTransition, !pagePanConsumed {
                beginInteractivePage(translation: translation)
            }
            guard case .interactive(let activeTransition) = pagingTransition else { return }
            activeTransition.update(fraction: abs(translation) / interactiveTravel)
        case .ended, .cancelled, .failed:
            // Cleared before the transition guard below: a pan that never
            // became a page must still hand the deck back.
            isPagingGesture = false
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

    /// A drag the carousel has claimed as a page swipe must not ALSO scroll the
    /// card it started on.
    ///
    /// `pagePan` recognizes simultaneously with the embedded content's own
    /// gestures — that is what keeps links, taps and scrolling alive on a card
    /// that is not being paged — so by the time the horizontal gate lets paging
    /// begin, the reader under the finger has usually begun its own scroll on
    /// the same touch. Nothing then stops the rest of the swipe from scrolling
    /// that article while the deck pages it away, which is most visible when
    /// the swipe starts on a peeking side card: the finger arrives at the newly
    /// centered reader already scrolled off its first line.
    ///
    /// Toggling `isEnabled` is the only way to cancel a recognizer mid-sequence;
    /// it ends the scroll where it stands (no deceleration) and the scroll view
    /// takes part again on the next touch down.
    private func relinquishScrollingClaimedByPagePan() {
        for scrollView in CardCarouselScrollViews.nested(in: cardArea) {
            let pan = scrollView.panGestureRecognizer
            // Only recognizers actually tracking this touch — a card
            // decelerating from an earlier flick keeps its momentum.
            guard pan.state == .began || pan.state == .changed else { continue }
            pan.isEnabled = false
            pan.isEnabled = true
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
            // Pausing brings the controls up on its own (they are a function of
            // the paused state, whether the pause came from a tap or a drag).
            content.setPlaying(false)
            updatePlaybackControls()
        case .changed:
            let translation = gesture.translation(in: cardArea).x
            let fraction = scrubStartFraction + Double(translation / metrics.cardSize.width)
            content.seek(toFraction: fraction)
            updatePlaybackScrubProgress(to: fraction)
        case .ended, .cancelled, .failed:
            // Resuming takes them down again; a drag that ends paused keeps them.
            if wasPlayingBeforeScrub { content.setPlaying(true) }
            updatePlaybackControls()
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
            slot.card.setMuteButtonVisible(isCenter && showsMuteButton(for: slot.content))
            slot.card.updateMuteIcon(muted: audioSession.isMuted)
        }
    }
}

// MARK: - Gesture disambiguation

extension CardCarouselViewController: CarouselCardViewDelegate,
    CarouselAudioSessionCoordinatorDelegate {
    public func carouselCardDidToggleMute(_ card: CarouselCardView) {
        setSoundMuted(!audioSession.isMuted)
    }

    func carouselAudioSessionDidChangeMuteState(_ coordinator: CarouselAudioSessionCoordinator) {
        applyMuteState()
    }
}

extension CardCarouselViewController: CardContentAudioAvailabilityObserving,
    CardContentPlaybackObserving {
    public func cardContentDidChangeAudioAvailability(_ content: CardContentViewController) {
        updateMuteUI()
    }

    public func cardContentDidChangePlaybackState(_ content: CardContentViewController) {
        updatePlaybackControls()
    }
}

extension CardCarouselViewController: PlaybackSpeedPillDelegate {
    public func playbackSpeedPill(_ pill: PlaybackSpeedPillButton, didSelect speed: Double) {
        guard let content = slots[currentIndex]?.content else { return }
        content.setPlaybackSpeed(speed)
        // The new label needs a new pill frame ("0.25×" is wider than "1×", and the
        // pill is frame-managed) — without this the longer title wraps to a second
        // line inside the old width.
        layoutPlaybackScrubProgress()
    }
}

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
            // A new touch sequence: whatever the last one claimed is over.
            isPagingGesture = false
            // A horizontal control under the finger — the RSVP scrubber, any
            // slider inside a card — owns horizontal drags outright. A scrub
            // toward either end of the track reads exactly like a page-worthy
            // swipe, and paging mid-scrub yanks the card out from under the
            // thumb, so the pan must refuse rather than merely coexist.
            if let hit = cardArea.hitTest(gestureRecognizer.location(in: cardArea), with: nil),
               sequence(first: hit, next: { $0.superview }).contains(where: { $0 is UISlider }) {
                return false
            }
            let velocity = pagePan.velocity(in: cardArea)
            let decision = CardCarouselPagePanStartPolicy.decision(
                isTransitioning: isTransitioning,
                isImmersed: isImmersed,
                startsInsideCenteredCard: insideCenter,
                pagesOnInCardSwipes: cardStyle(at: currentIndex).pagesOnInCardSwipes,
                centeredContentScrubs: slots[currentIndex]?.content.isPlayable == true,
                velocity: velocity)
            if decision == .acceptAndSurface {
                // Restore the resting card geometry before the same pan starts
                // manipulating it, so immersion never costs a second swipe.
                setImmersed(false, animated: false)
                delegate?.carouselDidSurfaceForEdgePaging(self)
            }
            // The deck belongs to this gesture from here until the touch leaves,
            // whatever the pan turns out to do with it.
            if decision != .reject { isPagingGesture = true }
            return decision != .reject
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The in-card page pan and the additive tap must coexist with gestures
        // inside the embedded content (scroll views, links) — up to the moment
        // the pan becomes a page, after which the card keeps none of the touch.
        if gestureRecognizer === pagePan {
            let isScrollViewPan = (otherGestureRecognizer.view as? UIScrollView)
                .map { $0.panGestureRecognizer === otherGestureRecognizer } ?? false
            return CardCarouselPagePanSimultaneityPolicy.allowsSimultaneousRecognition(
                pagesOnInCardSwipes: cardStyle(at: currentIndex).pagesOnInCardSwipes,
                otherIsScrollViewPan: isScrollViewPan,
                pagePanIsTrackingTheTouch: pagePan.state == .began || pagePan.state == .changed)
        }
        // Additive only against other taps (a link, a button inside embedded
        // content) — never against a long-press-family recognizer, so a content
        // long-press (text selection, a card's own context menu) doesn't also
        // let this tap fire on finger-lift and toggle the chrome.
        return gestureRecognizer is UITapGestureRecognizer
            && otherGestureRecognizer is UITapGestureRecognizer
    }
}

// MARK: - Scrub strip

extension CardCarouselViewController: CarouselScrubberViewDelegate {

    public func scrubber(_ scrubber: CarouselScrubberView, didShow indices: IndexSet) {
        loadStripVisuals(for: indices)
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
