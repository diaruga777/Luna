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
//  - The scrub strip pages one card on a flick, or jumps continuously while
//    dragging (thumbnail preview over the centered card, committed on release).
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
    /// Small preview for the scrub strip; call the completion on any queue.
    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void)
    /// Optional small accessory pinned to the card's top-leading corner.
    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView?
}

public extension CardCarouselDataSource {
    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? { nil }
}

public protocol CardCarouselDelegate: AnyObject {
    /// A new card is centered (paging, scrub commit, or reload).
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int)
    /// Long-press menu for a card; return nil for none.
    func carousel(
        _ carousel: CardCarouselViewController,
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration?
}

public extension CardCarouselDelegate {
    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {}
    func carousel(
        _ carousel: CardCarouselViewController,
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration? { nil }
}

public final class CardCarouselViewController: UIViewController {

    public weak var dataSource: CardCarouselDataSource?
    public weak var delegate: CardCarouselDelegate?

    /// Whether the carousel drives the shared AVAudioSession (ambient while
    /// muted, playback while unmuted). Hosts with their own audio coordination
    /// can turn this off.
    public var managesAudioSession = true

    public private(set) var currentIndex = 0
    public private(set) var isSoundMuted = true

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
    private var pendingReload: (deferred: Bool, index: Int?) = (false, nil)

    private let cardArea = UIView()
    private let scrubber = CarouselScrubberView()
    private var previewOverlay: UIImageView?

    private var playbackPan: UIPanGestureRecognizer!
    private var pagePan: UIPanGestureRecognizer!
    /// The in-flight interactive eclipse and the finger-travel distance mapping
    /// translation to its fraction.
    private var interactiveTransition: CardEclipseTransition?
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
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrubber)
        cardArea.clipsToBounds = false
        cardArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardArea)
        NSLayoutConstraint.activate([
            scrubber.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrubber.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            cardArea.topAnchor.constraint(equalTo: view.topAnchor),
            cardArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardArea.bottomAnchor.constraint(equalTo: scrubber.topAnchor),
        ])

        scrubber.onPreview = { [weak self] index in self?.showScrubPreview(index) }
        scrubber.onCommit = { [weak self] index in self?.commitScrub(to: index) }
        scrubber.onPageStep = { [weak self] step in
            self?.removeScrubPreview()
            self?.page(by: step)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        cardArea.addGestureRecognizer(tap)

        playbackPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        playbackPan.delegate = self
        cardArea.addGestureRecognizer(playbackPan)

        pagePan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pagePan.delegate = self
        cardArea.addGestureRecognizer(pagePan)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = cardArea.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if metrics?.containerSize != size {
            metrics = CardCarouselMetrics.resolve(containerSize: size)
        }
        guard !isTransitioning else { return }
        for slot in slots.values { applyRestingLayout(to: slot) }
        layoutPreviewOverlay()
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
            pendingReload = (true, index ?? pendingReload.index)
            return
        }
        removeScrubPreview()
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

    /// Pages by `step` cards. Single steps run the eclipse transition (unless
    /// Reduce Motion or off-window); anything else is a crossfade jump.
    public func page(by step: Int) {
        let target = min(max(currentIndex + step, 0), max(0, count - 1))
        guard count > 0, target != currentIndex, !isTransitioning else { return }
        if abs(target - currentIndex) == 1,
           !UIAccessibility.isReduceMotionEnabled,
           view.window != nil,
           slots[target] != nil {
            runEclipse(to: target)
        } else {
            jump(to: target)
        }
    }

    public func setSoundMuted(_ muted: Bool) {
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
        let card = CarouselCardView()
        addChild(content)
        card.installContentView(content.view)
        content.didMove(toParent: self)
        content.setMuted(isSoundMuted)
        content.audioAvailabilityChanged = { [weak self] in self?.updateMuteUI() }
        card.onMuteToggle = { [weak self] in
            guard let self else { return }
            self.setSoundMuted(!self.isSoundMuted)
        }
        card.setTopLeadingAccessory(dataSource.carousel(self, topLeadingAccessoryForCardAt: index))
        card.addInteraction(UIContextMenuInteraction(delegate: self))
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
        let offset = slot.index - currentIndex
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
    /// marking the carousel as transitioning until it settles.
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

        return CardEclipseTransition(
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
    }

    /// Runs after a transition finishes OR cancels: restores interactivity,
    /// applies resting layout, and picks up a reload that arrived mid-flight.
    private func settleAfterTransition() {
        isTransitioning = false
        interactiveTransition = nil
        view.isUserInteractionEnabled = true
        for slot in slots.values { applyRestingLayout(to: slot) }
        removeOrphanCardViews()
        if pendingReload.deferred {
            let index = pendingReload.index
            pendingReload = (false, nil)
            reloadData(centeringAt: index)
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
        if previewOverlay == nil {
            let overlay = UIImageView()
            overlay.contentMode = .scaleAspectFit
            overlay.backgroundColor = .secondarySystemBackground
            overlay.layer.cornerRadius = CarouselCardView.cornerRadius
            overlay.layer.cornerCurve = .continuous
            overlay.clipsToBounds = true
            cardArea.addSubview(overlay)
            previewOverlay = overlay
            layoutPreviewOverlay()
        }
        dataSource?.carousel(self, loadThumbnailForCardAt: index) { [weak self] image in
            DispatchQueue.main.async { self?.previewOverlay?.image = image }
        }
    }

    private func layoutPreviewOverlay() {
        previewOverlay?.frame = centeredCardFrame()
    }

    private func removeScrubPreview() {
        previewOverlay?.removeFromSuperview()
        previewOverlay = nil
    }

    private func commitScrub(to index: Int) {
        removeScrubPreview()
        guard count > 0, !isTransitioning else { return }
        let target = min(max(index, 0), count - 1)
        if target == currentIndex {
            if isViewVisible { slots[currentIndex]?.content.cardDidBecomeCentered() }
            scrubber.setSelectedIndex(currentIndex, animated: true)
        } else if abs(target - currentIndex) == 1 {
            page(by: target - currentIndex)
        } else {
            jump(to: target)
        }
    }

    private func loadAllThumbnails() {
        guard let dataSource else { return }
        for index in 0..<count {
            dataSource.carousel(self, loadThumbnailForCardAt: index) { [weak self] image in
                DispatchQueue.main.async { self?.scrubber.setThumbnail(image, at: index) }
            }
        }
    }

    // MARK: - Card gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard count > 0, !isTransitioning else { return }
        let location = gesture.location(in: cardArea)
        let center = centeredCardFrame()
        if center.contains(location) {
            guard let content = slots[currentIndex]?.content, content.isPlayable else { return }
            content.setPlaying(!content.isPlaying)
        } else if location.x > center.maxX {
            page(by: 1)
        } else if location.x < center.minX {
            page(by: -1)
        }
    }

    /// Interactive paging: a horizontal drag starting on the insets beside the
    /// card drives the eclipse with the finger — play it forward, pull it back,
    /// release to finish or cancel.
    @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: cardArea).x
        switch gesture.state {
        case .began:
            pagePanConsumed = false
        case .changed:
            if interactiveTransition == nil, !pagePanConsumed {
                beginInteractivePage(translation: translation)
            }
            guard let interactiveTransition else { return }
            interactiveTransition.update(fraction: abs(translation) / interactiveTravel)
        case .ended, .cancelled, .failed:
            guard let interactiveTransition else { return }
            let fraction = min(max(abs(translation) / interactiveTravel, 0), 1)
            let velocity = gesture.velocity(in: cardArea).x
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
        interactiveTransition = transition
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
            // Pans on the insets beside the card page interactively.
            guard !insideCenter, !isTransitioning else { return false }
            let velocity = pagePan.velocity(in: cardArea)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
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
