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

import AVFoundation
import UIKit

public protocol CardCarouselDataSource: AnyObject {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int
    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController
    /// Lightweight content for the large scrub overlay. Hosts can return the
    /// real card (Downloader media) or a cheap representation (Reader excerpt).
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
    /// Width of the fade-blur zone at each end of the scrub strip. Chips
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

    public init() {}
}

public protocol CardCarouselDelegate: AnyObject {
    /// A new card is centered (paging, scrub commit, or reload).
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int)
    /// Long-press menu for a card; return nil for none.
    func carousel(
        _ carousel: CardCarouselViewController,
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration?
    /// The centered card was tapped and its content is not playable (playable
    /// content consumes the tap as pause/play). The tap does NOT cancel
    /// touches, so content-level taps (links) still land.
    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int)
    /// A long-press on the centered card, streamed for its whole lifetime
    /// (.began/.changed/.ended/.cancelled) so hosts can drive press-and-drag
    /// interactions. Fires alongside any context menu.
    func carousel(
        _ carousel: CardCarouselViewController,
        longPress gesture: UILongPressGestureRecognizer,
        onCenteredCardAt index: Int)
}

public extension CardCarouselDelegate {
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {}
    func carousel(
        _ carousel: CardCarouselViewController,
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration? { nil }
    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {}
    func carousel(
        _ carousel: CardCarouselViewController,
        longPress gesture: UILongPressGestureRecognizer,
        onCenteredCardAt index: Int) {}
}

public final class CardCarouselViewController: UIViewController {

    public weak var dataSource: CardCarouselDataSource?
    public weak var delegate: CardCarouselDelegate?

    /// Whether the carousel drives the shared AVAudioSession (ambient while
    /// muted, playback while unmuted). Hosts with their own audio coordination
    /// can turn this off.
    public var managesAudioSession = true

    /// Per-surface tuning. Set BEFORE the carousel's view loads.
    public var style = CardCarouselStyle()

    public private(set) var currentIndex = 0
    private var isSoundMuted = true

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
    private var volumeObservation: NSKeyValueObservation?

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

        scrubber.onPreview = { [weak self] index in self?.showScrubPreview(index) }
        scrubber.onCommit = { [weak self] index in self?.commitScrub(to: index) }

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

        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        cardArea.addGestureRecognizer(longPress)
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
        guard !isTransitioning else { return }
        for slot in slots.values { applyRestingLayout(to: slot) }
        scrubPreview.layout(centeredCardFrame: centeredCardFrame())
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        startVolumeObservation()
        slots[currentIndex]?.content.cardDidBecomeCentered()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        volumeObservation?.invalidate()
        volumeObservation = nil
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

    /// Cards rest this far below the carousel view's top — hosts whose header
    /// overlays the carousel reserve their header height here.
    public func setTopInset(_ inset: CGFloat) {
        loadViewIfNeeded()
        guard abs(cardAreaTopConstraint.constant - inset) > 0.5 else { return }
        cardAreaTopConstraint.constant = inset
    }

    public func setImmersed(_ immersed: Bool, extendsCard: Bool = true, animated: Bool = false) {
        // A transition can only start un-immersed (paging is inert while
        // immersed), so this only drops a spurious fade-out — e.g. a reader
        // still decelerating while the user pages away — that would fight the
        // eclipse's manipulation of the same card.
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
        isSoundMuted = muted
        applyMuteState()
        updateAudioSession()
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
        card.installContentView(content.view)
        content.setMuted(isSoundMuted)
        content.audioAvailabilityChanged = { [weak self] in self?.updateMuteUI() }
        card.onMuteToggle = { [weak self] in
            guard let self else { return }
            self.setSoundMuted(!self.isSoundMuted)
        }
        card.setTopLeadingAccessory(dataSource?.carousel(
            self, topLeadingAccessoryForCardAt: index))
        // Install a context-menu interaction only on cards that actually have a
        // menu (probed once at mount; the interaction still asks the delegate for
        // a fresh configuration at press time). An interaction whose delegate
        // answers nil never fails its long-press "click driver" while the finger
        // is stationary, and that driver's relationship recognizers gate action
        // delivery for EVERY other long press sharing the touch — a held link
        // inside an embedded reader card sat recognized-but-undelivered until the
        // finger moved or lifted.
        if delegate?.carousel(self, contextMenuForCardAt: index) != nil {
            card.addInteraction(UIContextMenuInteraction(delegate: self))
        }
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

    private func applyRestingLayout(to slot: Slot) {
        guard let metrics else { return }
        if slot.index == currentIndex, isImmersed {
            applyImmersionLayout()
            return
        }
        let offset = slot.index - currentIndex
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

    // MARK: - Paging

    private func runEclipse(to target: Int) {
        guard let transition = makeEclipseTransition(to: target) else {
            jump(to: target)
            return
        }
        // Non-interactive runs block all input for their duration; interactive
        // runs (handlePagePan) keep the driving pan alive instead.
        view.isUserInteractionEnabled = false
        transition.animateToFinish()
    }

    /// Builds one eclipse page transition to `target` (must be ±1 and mounted),
    /// marking the carousel as transitioning — and retaining the transition —
    /// until it settles.
    private func makeEclipseTransition(to target: Int) -> CardEclipseTransition? {
        guard let metrics,
              !isTransitioning,
              let outgoing = slots[currentIndex],
              let incoming = slots[target]
        else { return nil }
        let step = target - currentIndex
        let opposite = slots[currentIndex - step]

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
            atZenith: { [weak self] in
                guard let self else {
                    return CardEclipseZenithResult(repositionedOutgoing: nil, enteringPeek: nil)
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
            centered.content.setMuted(isSoundMuted)
            if isViewVisible { centered.content.cardDidBecomeCentered() }
        }
        updateMuteUI()
        scrubber.setSelectedIndex(currentIndex, animated: true)
        delegate?.carousel(self, didCenterCardAt: currentIndex)
        return CardEclipseZenithResult(
            repositionedOutgoing: outgoing.card,
            enteringPeek: enteringCard)
    }

    /// Non-eclipse move (Reduce Motion, scrub commits, multi-card jumps).
    private func jump(to target: Int) {
        guard target != currentIndex, !isTransitioning else { return }
        slots[currentIndex]?.content.cardDidLeaveCenter()
        currentIndex = target
        UIView.transition(
            with: cardArea,
            duration: 0.28,
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
        slots[currentIndex]?.content.setPlaying(false)
        scrubPreview.show(at: index, cardCount: count, centeredCardFrame: centeredCardFrame())
    }

    private func commitScrub(to index: Int) {
        guard count > 0, !isTransitioning else { return }
        let target = min(max(index, 0), count - 1)
        if style.autoplaysScrubPreviewContent,
           scrubPreview.previewContentIndex == target,
           let content = scrubPreview.takeContent() {
            promoteScrubPreview(content, to: target)
            return
        }
        scrubPreview.remove()
        if target == currentIndex {
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
        } else if style.scrubberStyle.animateScrubTransitions, abs(target - currentIndex) == 1 {
            page(by: target - currentIndex)
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
        delegate?.carousel(self, didCenterCardAt: target)

        UIView.animate(
            withDuration: 0.22, delay: 0,
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

    /// Whether a long-press that began on the centered card is being streamed.
    private var isStreamingLongPress = false

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            guard count > 0, !isTransitioning,
                  centeredCardFrame().contains(gesture.location(in: cardArea))
            else { return }
            isStreamingLongPress = true
        }
        guard isStreamingLongPress else { return }
        delegate?.carousel(self, longPress: gesture, onCenteredCardAt: currentIndex)
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            isStreamingLongPress = false
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
        guard let transition = makeEclipseTransition(to: target) else { return }
        // Finger travel maps to the incoming card's journey from its peek slot
        // to center.
        interactiveTravel = max(
            abs(metrics.centerX(forSlotOffset: step) - metrics.centerX(forSlotOffset: 0)),
            1)
        pagingTransition = .interactive(transition)
    }

    @objc private func handleScrubPan(_ gesture: UIPanGestureRecognizer) {
        guard let metrics, let content = slots[currentIndex]?.content, content.isPlayable
        else { return }
        switch gesture.state {
        case .began:
            scrubStartFraction = content.playbackFraction
            wasPlayingBeforeScrub = content.isPlaying
            content.setPlaying(false)
        case .changed:
            let translation = gesture.translation(in: cardArea).x
            let fraction = scrubStartFraction + Double(translation / metrics.cardSize.width)
            content.seek(toFraction: fraction)
        case .ended, .cancelled, .failed:
            if wasPlayingBeforeScrub { content.setPlaying(true) }
        default:
            break
        }
    }

    // MARK: - Mute + audio session

    private func applyMuteState() {
        for slot in slots.values { slot.content.setMuted(isSoundMuted) }
        updateMuteUI()
    }

    private func updateMuteUI() {
        for slot in slots.values {
            let isCenter = slot.index == currentIndex
            slot.card.setMuteButtonVisible(isCenter && slot.content.supportsAudio)
            slot.card.updateMuteIcon(muted: isSoundMuted)
        }
    }

    private func updateAudioSession() {
        guard managesAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        // Muted autoplay must not silence other apps' audio; unmuted playback
        // should be audible even with the silent switch on.
        if isSoundMuted {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback)
        }
        try? session.setActive(true)
    }

    private func startVolumeObservation() {
        updateAudioSession()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.old, .new]
        ) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new
            else { return }
            DispatchQueue.main.async {
                guard let self, self.isSoundMuted else { return }
                self.setSoundMuted(false)
            }
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
            guard !isTransitioning, !isImmersed else { return false }
            let velocity = pagePan.velocity(in: cardArea)
            if insideCenter {
                // Inside the card, paging is opt-in (embedded readers) and only
                // for strongly-horizontal drags, so it never fights the
                // content's own vertical scrolling.
                guard style.pagesOnInCardSwipes else { return false }
                return abs(velocity.x) > abs(velocity.y) * 1.5
            }
            // Pans on the insets beside the card always page interactively.
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The in-card page pan and the additive tap/long-press must coexist
        // with gestures inside the embedded content (scroll views, links).
        if gestureRecognizer === pagePan {
            return style.pagesOnInCardSwipes
        }
        return gestureRecognizer is UITapGestureRecognizer
            || gestureRecognizer is UILongPressGestureRecognizer
    }
}

// MARK: - Context menus

extension CardCarouselViewController: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let card = interaction.view,
              let slot = slots.values.first(where: { $0.card === card })
        else { return nil }
        return delegate?.carousel(self, contextMenuForCardAt: slot.index)
    }
}
