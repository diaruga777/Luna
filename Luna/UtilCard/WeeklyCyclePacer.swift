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
@MainActor
final class UtilCardSetupTextCycler {
    static let animationDuration: TimeInterval = 0.55

    private weak var safariButton: UIButton?
    private weak var shortcutButton: UIButton?
    private let safariTitles: [String]
    private let shortcutTitles: [String]
    private let baseSafariTitle: String
    private let baseShortcutTitle: String
    private var index = -1

    init(
        safariButton: UIButton,
        shortcutButton: UIButton,
        apps: [LunaApp]
    ) {
        self.safariButton = safariButton
        self.shortcutButton = shortcutButton
        baseSafariTitle = safariButton.configuration?.title ?? ""
        baseShortcutTitle = shortcutButton.configuration?.title ?? ""
        safariTitles = apps.map { OnboardingStrings.Intro.safariAction.value(for: $0) }
        shortcutTitles = apps.map { OnboardingStrings.Intro.shortcutAction.value(for: $0) }
        safariButton.clipsToBounds = true
        shortcutButton.clipsToBounds = true
    }

    func advance() {
        let count = max(safariTitles.count, shortcutTitles.count)
        guard count > 0 else { return }
        index = (index + 1) % count
        if let title = safariTitles[safe: index] {
            animate(safariButton, to: title)
        }
        if let title = shortcutTitles[safe: index] {
            animate(shortcutButton, to: title)
        }
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
        index = -1
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
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
