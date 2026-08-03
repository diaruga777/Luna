//
//  WeeklyCyclePacer.swift
//  Luna
//

import Foundation

/// When the central app's weekly row is allowed to advance on its own.
///
/// Pure gating, no views: every reason to stop is a stored flag, and the timer
/// exists only while all of them agree. Extracted from the row host precisely
/// so the policy — including the "the user touched it, so stop until they
/// leave or come back" latch — can be tested without a carousel.
///
/// Main-thread only, like the view that owns it; deliberately NOT `@MainActor`
/// so a `UIView`'s (nonisolated) initializer can build one as a default.
final class WeeklyCyclePacer {
    static let interval: TimeInterval = 2.0

    /// Starts a repeating tick and returns its canceller. Injected so tests
    /// drive the cadence by hand instead of waiting two seconds a time.
    typealias Scheduler = (
        _ interval: TimeInterval, _ tick: @escaping () -> Void
    ) -> () -> Void

    var onAdvance: (() -> Void)?

    private let interval: TimeInterval
    private let scheduler: Scheduler
    private var cancel: (() -> Void)?

    /// The manual-gesture latch: set by the first swipe, cleared only by
    /// leaving centre or by a background→foreground round trip.
    private(set) var userTookControl = false

    var liveKindCount = 0 { didSet { update() } }
    var isCentered = false { didSet { update() } }
    var isInWindow = false { didSet { update() } }
    var isAppActive = true { didSet { update() } }
    /// A replacement eclipse owns the slot while it runs.
    var isReplacing = false { didSet { update() } }
    var isUserTouching = false { didSet { update() } }
    /// Reduce Motion means no automatic movement at all; a deliberate swipe
    /// still works (as a crossfade).
    var reduceMotion = false { didSet { update() } }

    init(
        interval: TimeInterval = WeeklyCyclePacer.interval,
        scheduler: @escaping Scheduler = WeeklyCyclePacer.timerScheduler
    ) {
        self.interval = interval
        self.scheduler = scheduler
    }

    deinit { cancel?() }

    var isRunning: Bool { cancel != nil }

    /// Two or more live kinds, the card in front of the user, nothing else
    /// moving, and no manual override.
    var canRun: Bool {
        liveKindCount >= 2 && isCentered && isInWindow && isAppActive
            && !isReplacing && !isUserTouching && !reduceMotion && !userTookControl
    }

    func userDidTakeControl() {
        userTookControl = true
        update()
    }

    func cardDidLeaveCenter() {
        userTookControl = false
        isCentered = false
    }

    func appWillEnterForeground() {
        userTookControl = false
        isAppActive = true
    }

    func appDidEnterBackground() {
        isAppActive = false
    }

    private func update() {
        if canRun, cancel == nil {
            cancel = scheduler(interval) { [weak self] in self?.onAdvance?() }
        } else if !canRun, let cancel {
            cancel()
            self.cancel = nil
        }
    }

    /// A repeating `Timer` with generous tolerance — a two-second decorative
    /// cadence has no business waking the CPU precisely.
    static let timerScheduler: Scheduler = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            tick()
        }
        timer.tolerance = interval * 0.25
        return { timer.invalidate() }
    }
}
