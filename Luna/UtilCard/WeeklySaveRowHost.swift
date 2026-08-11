//
//  WeeklySaveRowHost.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaWeekly
import UIKit

/// The util card's Save of the Week slot.
///
/// It owns whatever rows the local store currently has for THIS app's kinds —
/// none (the slot collapses and the card reflows without it), one, or, in the
/// central app, up to three that take turns in the same place. Everything it
/// draws comes from `WeeklySaveStore`; it never fetches.
final class WeeklySaveRowHost: UIView {
    /// Tapping a row saves it, exactly like a recent-history row.
    var onSave: ((_ urlString: String, _ sourceView: UIView) -> Void)?
    /// The card asks for a relayout whenever the slot appears or disappears.
    var onPresenceChange: (() -> Void)?
    /// The central onboarding labels subscribe here rather than maintaining a
    /// second timer, so both changes begin on the same clock tick — and it
    /// carries the kind the row is arriving AT, not the one it is leaving, so a
    /// subscriber can never be a turn behind. A manual swipe reports too: the
    /// labels follow the row whoever moved it.
    var onCycle: ((WeeklySaveKind) -> Void)?
    /// Whether the deck already holds this URL — installed by the util card so
    /// an answered pick shows dimmed under a checkmark rather than offered.
    var isSaved: ((_ urlString: String) -> Bool)? {
        didSet { updateSavedStates() }
    }

    private let store: WeeklySaveStore
    private let app: LunaApp
    private let now: () -> Date

    /// Rows live inside a clipping child so a slide reads as a row entering the
    /// slot. The HOST itself must not clip: the replacement corona overhangs it
    /// on every side, and that overhang is the effect.
    private let clip = UIView()

    /// One row per cycle slot, in the app's kind order. Central Luna keeps
    /// empty sibling slots too, so a missing weekly pick remains a fully
    /// transparent turn in the cycle rather than being silently removed from it.
    private(set) var rows: [UtilURLRow] = []
    private(set) var displays: [WeeklySaveDisplay] = []
    private var slots: [WeeklySaveDisplay?] = []
    private var index = 0
    /// Held for the whole run — a transition that only the animation retains is
    /// the carousel's classic disappearing-act bug.
    private var replacement: WeeklyRowEclipseTransition?

    /// Whether the card should give this slot any room at all. A central card
    /// with at least one live pick keeps the slot for all three turns.
    var isEmpty: Bool { displays.isEmpty }

    /// Whether a replacement is mid-flight (the cycle pauses while it is).
    var isReplacing: Bool { replacement != nil }

    /// The auto-advance policy. Only the central app ever has more than one
    /// live kind, so everywhere else this simply never starts.
    let pacer: WeeklyCyclePacer
    /// The committed-swipe / auto-advance settle. Held so a new gesture can
    /// interrupt it rather than queue behind it.
    private var slide: UIViewPropertyAnimator?
    private var pan: UIPanGestureRecognizer!
    /// The neighbour the current drag is heading toward, and which way.
    private var dragTarget: Int?
    private var dragForward = true
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// The carousel's own Reduce Motion crossfade length
    /// (`CarouselAnimationTiming.crossfadeDuration`, which is private to it).
    static let reduceMotionCrossfade: TimeInterval = 0.28

    init(
        store: WeeklySaveStore = .shared,
        app: LunaApp = .current,
        now: @escaping () -> Date = Date.init,
        pacer: WeeklyCyclePacer = WeeklyCyclePacer()
    ) {
        self.store = store
        self.app = app
        self.now = now
        self.pacer = pacer
        super.init(frame: .zero)
        accessibilityIdentifier = "utilCard.weeklyHost"
        clipsToBounds = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = UtilURLRow.cornerRadius
        clip.layer.cornerCurve = .continuous
        addSubview(clip)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        addGestureRecognizer(pan)

        pacer.onAdvance = { [weak self] in
            self?.advance(forward: true, velocity: 0)
        }
        pacer.reduceMotion = UIAccessibility.isReduceMotionEnabled
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pacer.appDidEnterBackground()
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Coming back also RE-ENABLES auto-advance after a manual swipe.
            self?.pacer.appWillEnterForeground()
        })

        reload(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Gates

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pacer.isInWindow = window != nil
    }

    /// Forwarded by the util card from `CardContentViewController`.
    func cardDidBecomeCentered() { pacer.isCentered = true }
    func cardDidLeaveCenter() { pacer.cardDidLeaveCenter() }
    func setCycleVisible(_ isVisible: Bool) { pacer.isCycleVisible = isVisible }

    // MARK: - Content

    /// Rebuilds from the store. Returns true when the slot's presence changed,
    /// which is the card's cue to reflow.
    @discardableResult
    func reload(animated: Bool) -> Bool {
        let wasEmpty = isEmpty
        let previous = displays
        let previousSlots = slots
        let updated = store.liveDisplays(for: WeeklySaveKind.kinds(for: app))
        let updatedSlots: [WeeklySaveDisplay?] = app == .luna
            ? WeeklySaveKind.kinds(for: app).map { store.display(for: $0) }
            : updated.map(Optional.some)
        guard updated != previous || updatedSlots != previousSlots else { return false }
        displays = updated
        slots = updatedSlots
        let previousIndex = index
        index = min(index, max(0, updatedSlots.count - 1))

        // The one case worth an eclipse: the row on screen right now kept its
        // place and swapped its content. Anything else (a row appearing, the
        // last one leaving, the set changing size) is the card's own fade.
        if animated, !wasEmpty, !isEmpty,
           previousSlots.count == updatedSlots.count, previousIndex == index,
           previousSlots.indices.contains(index),
           previousSlots[index]?.save.kind == updatedSlots[index]?.save.kind,
           previousSlots[index] != updatedSlots[index],
           bounds.width > 1, let outgoing = rows.indices.contains(index) ? rows[index] : nil
        {
            replaceCurrentRow(outgoing: outgoing, with: updatedSlots[index])
            rebuildOffscreenRows(keeping: index)
            return false
        }

        rebuildRows()
        setNeedsLayout()
        let presenceChanged = wasEmpty != isEmpty
        if presenceChanged { onPresenceChange?() }
        return presenceChanged
    }

    private func syncPacer() {
        pacer.liveKindCount = app == .luna && !displays.isEmpty
            ? slots.count
            : displays.count
        pacer.isReplacing = isReplacing
        pacer.reduceMotion = UIAccessibility.isReduceMotionEnabled
    }

    private func rebuildRows() {
        replacement?.finish()
        replacement = nil
        for row in rows { row.removeFromSuperview() }
        rows = slots.map(makeRow)
        updateRowVisibility()
        syncPacer()
    }

    /// After an in-place replacement the OTHER kinds' rows may also have moved
    /// on, so they are rebuilt around the row the eclipse is animating.
    private func rebuildOffscreenRows(keeping keptIndex: Int) {
        for (offset, row) in rows.enumerated() where offset != keptIndex {
            row.removeFromSuperview()
        }
        var rebuilt: [UtilURLRow] = []
        for (offset, display) in slots.enumerated() {
            if offset == keptIndex, rows.indices.contains(keptIndex) {
                rebuilt.append(rows[keptIndex])
            } else {
                rebuilt.append(makeRow(display))
            }
        }
        rows = rebuilt
        updateRowVisibility()
        syncPacer()
    }

    private func makeRow(_ display: WeeklySaveDisplay?) -> UtilURLRow {
        let row = UtilURLRow(style: .saveOfTheWeek)
        if let display {
            configure(row, with: display)
        } else {
            // The central card's nil turn leaves the entire slot empty — no
            // dark row shell, rim, or hit target — while preserving its place
            // in the shared three-kind cycle.
            row.alpha = 0
            row.isUserInteractionEnabled = false
            row.accessibilityElementsHidden = true
        }
        clip.addSubview(row)
        return row
    }

    private func configure(_ row: UtilURLRow, with display: WeeklySaveDisplay) {
        row.configure(
            RecentURLPreview(
                urlString: display.save.urlString,
                title: display.title,
                subtitle: display.subtitleHost,
                kind: Self.previewKind(display.save.kind),
                imageData: display.imageData),
            weeklyLabel: WeeklySaveLabels.subtitle(
                for: app, monthTier: display.save.isMonthTier(now: now())),
            weeklyTint: Self.softTint(for: display.save.kind))
        row.onTap = { [weak self, weak row] in
            guard let self, let row else { return }
            self.onSave?(display.save.urlString, row)
        }
        row.setSaved(isSaved?(display.save.urlString) ?? false)
    }

    /// Reconciled by the util card on `.readingListChanged`: saving or deleting
    /// the pick flips its row between offered and answered.
    func updateSavedStates() {
        for (offset, row) in rows.enumerated() {
            guard slots.indices.contains(offset), let display = slots[offset] else {
                continue
            }
            row.setSaved(isSaved?(display.save.urlString) ?? false)
        }
    }

    /// Only the current row is on screen; the rest wait hidden.
    private func updateRowVisibility() {
        for (offset, row) in rows.enumerated() where !(replacement != nil && offset == index) {
            row.isHidden = offset != index
            row.alpha = slotIsEmpty(offset) ? 0 : 1
        }
    }

    // MARK: - Replacement

    private func replaceCurrentRow(outgoing: UtilURLRow, with display: WeeklySaveDisplay?) {
        replacement?.finish()
        let incoming = makeRow(display)
        incoming.isHidden = false
        rows[index] = incoming
        clip.frame = bounds
        outgoing.frame = clip.bounds

        if UIAccessibility.isReduceMotionEnabled {
            // Carousel precedent: no travel, no corona — just a crossfade.
            incoming.alpha = 0
            UIView.animate(withDuration: Self.reduceMotionCrossfade) {
                incoming.alpha = 1
                outgoing.alpha = 0
            } completion: { _ in
                outgoing.removeFromSuperview()
            }
            return
        }

        let transition = WeeklyRowEclipseTransition(
            host: self, clip: clip, outgoing: outgoing, incoming: incoming
        ) { [weak self] in
            self?.replacement = nil
            self?.syncPacer()
        }
        replacement = transition
        transition.start()
        syncPacer()
    }

    // MARK: - Cycling

    /// The next/previous live kind, wrapping.
    private func neighbour(forward: Bool) -> Int? {
        guard rows.count > 1 else { return nil }
        return forward
            ? (index + 1) % rows.count
            : (index + rows.count - 1) % rows.count
    }

    /// Auto-advance and committed-swipe settle share this: a horizontal slide,
    /// NOT an eclipse. The eclipse means "this pick was replaced"; a cycle just
    /// means "here is the other one".
    func advance(forward: Bool, velocity: CGFloat) {
        guard !isReplacing, let target = neighbour(forward: forward),
              bounds.width > 1
        else { return }
        prepareNeighbour(target, forward: forward, atDrag: 0)
        settle(to: target, forward: forward, velocity: velocity, commit: true)
    }

    /// Parks a neighbour one row-width off, in the direction it will arrive
    /// from, with its content lagging behind its shell.
    private func prepareNeighbour(_ target: Int, forward: Bool, atDrag drag: CGFloat) {
        let width = clip.bounds.width
        let row = rows[target]
        row.isHidden = false
        row.alpha = slotIsEmpty(target) ? 0 : 1
        row.frame = clip.bounds
        row.transform = CGAffineTransform(
            translationX: (forward ? width : -width) + drag, y: 0)
        row.setContentParallax(forward ? Self.parallaxLag : -Self.parallaxLag)
        clip.bringSubviewToFront(row)
    }

    private func settle(
        to target: Int, forward: Bool, velocity: CGFloat, commit: Bool
    ) {
        // Reported here rather than from the pacer's tick: this is the one place
        // that knows the DESTINATION, and it is reached by an auto-advance and a
        // committed swipe alike. A cancelled drag changes nothing, so it says
        // nothing.
        if commit, let kind = kind(atSlot: target) { onCycle?(kind) }
        let width = max(clip.bounds.width, 1)
        let outgoing = rows[index]
        let incoming = rows[target]
        let timing = UISpringTimingParameters(
            dampingRatio: 0.86,
            initialVelocity: CGVector(dx: abs(velocity) / width, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.55, timingParameters: timing)
        animator.addAnimations {
            if commit {
                incoming.transform = .identity
                incoming.setContentParallax(0)
                outgoing.transform = CGAffineTransform(
                    translationX: forward ? -width : width, y: 0)
                outgoing.alpha = self.slotIsEmpty(self.index) ? 0 : 0.85
            } else {
                incoming.transform = CGAffineTransform(
                    translationX: forward ? width : -width, y: 0)
                incoming.setContentParallax(forward ? Self.parallaxLag : -Self.parallaxLag)
                outgoing.transform = .identity
                outgoing.alpha = self.slotIsEmpty(self.index) ? 0 : 1
            }
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            if commit {
                outgoing.transform = .identity
                outgoing.alpha = 1
                outgoing.isHidden = true
                self.index = target
            } else {
                incoming.isHidden = true
                incoming.transform = .identity
                incoming.setContentParallax(0)
            }
            self.slide = nil
        }
        slide?.stopAnimation(true)
        slide = animator
        animator.startAnimation()
    }

    /// 14pt: enough for the content to read as sitting behind the shell,
    /// not so much that it looks detached from it.
    private static let parallaxLag: CGFloat = 14
    /// The carousel's own commit thresholds.
    private static let commitFraction: CGFloat = 0.5
    private static let commitVelocity: CGFloat = 350

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard rows.count > 1, bounds.width > 1 else { return }
        let width = clip.bounds.width
        let drag = gesture.translation(in: self).x

        switch gesture.state {
        case .began:
            slide?.stopAnimation(true)
            slide = nil
            pacer.isUserTouching = true
            pacer.userDidTakeControl()
            dragForward = drag < 0
            dragTarget = neighbour(forward: dragForward)
            if let dragTarget { prepareNeighbour(dragTarget, forward: dragForward, atDrag: drag) }
        case .changed:
            // Reversing direction mid-drag swaps which neighbour is tracking.
            let forward = drag < 0
            if forward != dragForward {
                if let dragTarget { parkNeighbour(dragTarget) }
                dragForward = forward
                dragTarget = neighbour(forward: forward)
                if let dragTarget {
                    prepareNeighbour(dragTarget, forward: forward, atDrag: drag)
                }
            }
            rows[index].transform = CGAffineTransform(translationX: drag, y: 0)
            if let dragTarget {
                rows[dragTarget].transform = CGAffineTransform(
                    translationX: (dragForward ? width : -width) + drag, y: 0)
                let progress = min(abs(drag) / width, 1)
                rows[dragTarget].setContentParallax(
                    (dragForward ? Self.parallaxLag : -Self.parallaxLag) * (1 - progress))
            }
        case .ended, .cancelled, .failed:
            pacer.isUserTouching = false
            guard let target = dragTarget else { return }
            dragTarget = nil
            let velocity = gesture.velocity(in: self).x
            let towardTarget = dragForward ? velocity < 0 : velocity > 0
            let commit = gesture.state == .ended
                && (abs(drag) > width * Self.commitFraction
                    || (abs(velocity) > Self.commitVelocity && towardTarget))
            settle(
                to: target, forward: dragForward, velocity: velocity, commit: commit)
        default:
            break
        }
    }

    /// Horizontal intent only, and the same 1.5× test the deck's own page pan
    /// applies — whoever passes it owns the touch, so the two never fight and
    /// a vertical or diagonal drag still reaches the carousel.
    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === self.pan
        else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard rows.count > 1, !isReplacing else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) * 1.5
    }

    private func parkNeighbour(_ target: Int) {
        let row = rows[target]
        row.isHidden = true
        row.transform = .identity
        row.setContentParallax(0)
    }

    private func slotIsEmpty(_ offset: Int) -> Bool {
        slots.indices.contains(offset) && slots[offset] == nil
    }

    /// Which kind owns a cycle slot — an EMPTY central turn included, which is
    /// why this reads the app's kind order rather than the slot's display: a
    /// missing pick still spends its turn in the cycle, and whatever follows the
    /// row (the setup labels) has to name the right app through it.
    private func kind(atSlot offset: Int) -> WeeklySaveKind? {
        if app == .luna {
            let kinds = WeeklySaveKind.kinds(for: app)
            return kinds.indices.contains(offset) ? kinds[offset] : nil
        }
        return slots.indices.contains(offset) ? slots[offset]?.save.kind : nil
    }

    /// Each kind carries the tint of the standalone app that owns it, including
    /// when central Luna cycles through every kind. The slight lift makes the
    /// hue read as a soft glass cast rather than brand paint.
    private static func softTint(for kind: WeeklySaveKind) -> UIColor {
        let surface: LunaSurfacePalette.Surface
        switch kind {
        case .article: surface = .reader
        case .media: surface = .downloader
        case .product: surface = .priceTracker
        }
        return LunaSurfacePalette.blended(
            LunaSurfacePalette.baseColor(for: surface), toward: .white, amount: 0.18)
    }

    private static func previewKind(_ kind: WeeklySaveKind) -> RecentURLPreview.Kind {
        switch kind {
        case .article: return .article
        case .media: return .media
        case .product: return .product
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        // A row mid-transform is being animated; assigning `frame` under a
        // non-identity transform would fight it.
        for row in rows where !row.isHidden && row.transform.isIdentity {
            row.frame = clip.bounds
        }
    }
}
