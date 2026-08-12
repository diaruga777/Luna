//
//  WeeklyCyclePacer.swift
//  Luna
//

import Foundation
import LunaModels
import UIKit

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
    /// This is intentionally unhurried: the weekly pick is content to read,
    /// not a status ticker. The setup labels use this exact same clock.
    static let interval: TimeInterval = 4.0

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
    /// Onboarding holds the slot back until its headline has yielded to it.
    /// A hidden row must not advance underneath its entrance animation.
    var isCycleVisible = true { didSet { update() } }
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
            && !isReplacing && !isUserTouching && isCycleVisible
            && !reduceMotion && !userTookControl
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

/// The central util card's setup labels advance *with* the weekly row. Only
/// the labels move; the glass buttons, icons, frames and hit targets stay fixed.
///
/// It keeps NO counter of its own. Which app's phrasing is due is asked of the
/// row — `show(_:)` takes the app owning the kind the row is arriving at — so
/// the two can never drift apart. They did: the cycler counted from its own
/// zero while the row advanced to the slot AFTER the one the tick found, so the
/// Price Tracker's phrasing sat under the Reader's pick.
@MainActor
final class UtilCardSetupTextCycler {
    static let animationDuration: TimeInterval = 0.55
    /// The setup labels begin their cadence as soon as the actions are on
    /// screen, before the weekly row is allowed to take over that cadence.
    static let interval = WeeklyCyclePacer.interval

    typealias Scheduler = (
        _ interval: TimeInterval, _ tick: @escaping () -> Void
    ) -> () -> Void

    private weak var safariButton: UIButton?
    private weak var shortcutButton: UIButton?
    private let baseSafariTitle: String
    private let baseShortcutTitle: String
    private let scheduler: Scheduler
    private var cancel: (() -> Void)?
    private var nextAppIndex = 0

    /// Fired at the start of each label transition. The util card uses this
    /// boundary to introduce the weekly row, so it never fades in halfway
    /// through a changing title.
    var onCycleStart: ((LunaApp) -> Void)?

    init(
        safariButton: UIButton,
        shortcutButton: UIButton,
        scheduler: @escaping Scheduler = UtilCardSetupTextCycler.timerScheduler
    ) {
        self.safariButton = safariButton
        self.shortcutButton = shortcutButton
        baseSafariTitle = safariButton.configuration?.title ?? ""
        baseShortcutTitle = shortcutButton.configuration?.title ?? ""
        self.scheduler = scheduler
        safariButton.clipsToBounds = true
        shortcutButton.clipsToBounds = true
    }

    deinit { cancel?() }

    /// Begins the opening cadence. Once the weekly row is visible, its own
    /// pacer reports the destination app through `show(_:)` instead.
    func startCycling() {
        guard !UIAccessibility.isReduceMotionEnabled, cancel == nil else { return }
        cancel = scheduler(Self.interval) { [weak self] in self?.advanceCycle() }
    }

    func stopCycling() {
        cancel?()
        cancel = nil
    }

    private func advanceCycle() {
        let apps: [LunaApp] = [.reader, .downloader, .priceTracker]
        let app = apps[nextAppIndex]
        nextAppIndex = (nextAppIndex + 1) % apps.count
        onCycleStart?(app)
        show(app)
    }

    /// Puts `app`'s own phrasing on both labels — the app whose kind the weekly
    /// row is showing, so the pair reads as one recommendation.
    func show(_ app: LunaApp) {
        animate(safariButton, to: OnboardingStrings.Intro.safariAction.value(for: app))
        animate(shortcutButton, to: OnboardingStrings.Intro.shortcutAction.value(for: app))
    }

    private func animate(_ button: UIButton?, to title: String) {
        guard let button, button.configuration?.title != title else { return }
        let outgoing = button.titleLabel
        let travel = max(button.bounds.width * 0.22, 34)
        UIView.animate(
            withDuration: Self.animationDuration * 0.34,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            outgoing?.transform = CGAffineTransform(translationX: -travel, y: 0)
            outgoing?.alpha = 0
        } completion: { [weak button] _ in
            guard let button else { return }
            self.applyTitle(title, to: button)
            button.accessibilityLabel = title
            button.layoutIfNeeded()
            let incoming = button.titleLabel
            incoming?.transform = CGAffineTransform(translationX: travel, y: 0)
            incoming?.alpha = 0
            UIView.animate(
                withDuration: Self.animationDuration * 0.66,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                incoming?.transform = .identity
                incoming?.alpha = 1
            }
        }
    }

    func reset() {
        stopCycling()
        nextAppIndex = 0
        safariButton?.titleLabel?.layer.removeAllAnimations()
        shortcutButton?.titleLabel?.layer.removeAllAnimations()
        UIView.performWithoutAnimation {
            if let safariButton { applyTitle(baseSafariTitle, to: safariButton) }
            if let shortcutButton { applyTitle(baseShortcutTitle, to: shortcutButton) }
            safariButton?.accessibilityLabel = baseSafariTitle
            shortcutButton?.accessibilityLabel = baseShortcutTitle
            safariButton?.titleLabel?.transform = .identity
            shortcutButton?.titleLabel?.transform = .identity
            safariButton?.titleLabel?.alpha = 1
            shortcutButton?.titleLabel?.alpha = 1
        }
    }

    private func applyTitle(_ title: String, to button: UIButton) {
        var configuration = button.configuration
        configuration?.title = title
        var attributes = AttributeContainer()
        attributes.font = .systemFont(ofSize: 13, weight: .semibold)
        configuration?.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = configuration
    }

    private static let timerScheduler: Scheduler = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            tick()
        }
        timer.tolerance = interval * 0.25
        return { timer.invalidate() }
    }
}
