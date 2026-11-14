//
//  ScrollDirectionImmersionTracker.swift
//  Luna
//

import LunaDesignSystem
import LunaReaderUI
import UIKit

/// The scroll-reader chrome policy is intentionally about the host viewport,
/// not the portrait card nested inside it. Every iPad gets tap-only chrome even
/// in a narrow multitasking window; a future foldable/landscape phone gets it
/// when its available screen is wider than tall.
enum ReaderCardViewportPolicy {
    static func usesTapOnlyScrollChrome(
        userInterfaceIdiom: UIUserInterfaceIdiom,
        viewportSize: CGSize
    ) -> Bool {
        userInterfaceIdiom == .pad || viewportSize.width > viewportSize.height
    }
}

/// The host of a tracked reader: it takes the immersion signal, and it answers
/// how far its immersed card extends past its resting footprint.
protocol ReaderImmersionTrackerDelegate: AnyObject {
    /// The reader wants the host chrome faded away (`immersed` true — reading is
    /// under way) or back in. `extendsCard` mirrors the host's own choice of
    /// whether an immersed layout should extend into the freed room: true for the
    /// scroll reader (more content shows), false for RSVP, whose fixed layout
    /// must not move when playback starts — only the chrome fades.
    func immersionTracker(
        _ tracker: ScrollDirectionImmersionTracker,
        didChangeImmersion immersed: Bool, extendsCard: Bool)

    /// Whether this scroll view's dismissal can still run in reverse.
    func canReverseScrollDismissal(
        _ tracker: ScrollDirectionImmersionTracker, in scrollView: UIScrollView
    ) -> Bool

    /// How much taller the live, immersed card is than its resting footprint —
    /// i.e. how far the card's bottom edge travels back UP when the chrome
    /// returns. It does not gate the bottom restore (the article's end can never
    /// reach the restored edge while the taller card still owns the scroll
    /// range); it marks the card as currently immersed and floors the downward
    /// dismissal dead zone.
    func immersionBottomExtension(for tracker: ScrollDirectionImmersionTracker) -> CGFloat
}

/// Detects "is the user reading on, or surfacing" under an arbitrary reader
/// hierarchy and reports it as a single immersion signal: KVO on every nested
/// scroll view for the scroll reader's direction, the play state of every nested
/// RSVP controller. Generic over any reader hosted anywhere — nothing here is
/// carousel- or card-specific.
final class ScrollDirectionImmersionTracker: RSVPPlaybackObserving {

    /// False on large/wide hosts, where scrolling must never change card chrome.
    /// RSVP callbacks remain active because its play/pause state is independent
    /// of this scroll-only gate.
    var allowsScrollDrivenImmersion = true {
        didSet {
            guard !allowsScrollDrivenImmersion else { return }
            scrollRuns = [:]
        }
    }

    /// The host this tracker reports to, and asks for the immersed card's extra
    /// height.
    weak var delegate: ReaderImmersionTrackerDelegate?

    /// Whether the tracker currently reports. Side cards' readers are live but
    /// inert, so the host sets this only while its card is centered; going
    /// inactive drops any in-progress directional run.
    var isActive = false {
        didSet {
            guard !isActive else { return }
            scrollRuns = [:]
        }
    }

    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Ignore synchronous TextKit and UIKit offset writes during a card resize.
    private var applyingScrollImmersion = false
    /// Per scroll view: the last seen offset and the directional run since the
    /// last direction flip (positive = scrolling down the article).
    private var scrollRuns: [ObjectIdentifier: (last: CGFloat, run: CGFloat)] = [:]

    /// Downward travel (pt) before the chrome fades away.
    private static let fadeOutTravel: CGFloat = 100
    /// A downward reading gesture this close to the bottom must not dismiss
    /// chrome. The position-driven bottom restore is about to take ownership,
    /// and letting the directional rule fire in the same region makes the two
    /// states fight while the scroll view is still decelerating.
    private static let bottomDismissalDeadZoneViewportFraction: CGFloat = 0.5
    /// How near the very end of the article counts as "reached the end" for the
    /// bottom restore. Small on purpose: the chrome returns as the last of the
    /// content arrives at the viewport's bottom edge, not a card-height early.
    /// (A settling scroll can stop a point or two short of the exact maximum.)
    private static let bottomRestoreTolerance: CGFloat = 12

    /// A dead zone may never be more than this much of the whole scroll range.
    /// The zone above is a fraction of the VIEWPORT measured from the end of the
    /// CONTENT, so on an article only a little longer than one screen it covers
    /// the entire scroll range — and then no downward gesture anywhere in the
    /// article can dismiss the chrome at all. Keeping it proportional to the
    /// article as well leaves the dismissal reachable on a short one (`0.25`
    /// leaves the fade-out's own travel clear for any range over ~133pt, below
    /// which there is barely a card's worth of content to immerse into).
    private static let bottomDismissalDeadZoneRangeFraction: CGFloat = 0.25

    /// Where the bottom dead zone begins, as a distance from the article's end.
    /// A long article takes the viewport-proportional zone unchanged; a short one
    /// is capped by its own length so it keeps a region where reading on still
    /// dismisses the chrome.
    static func dismissalDeadZoneStart(
        viewportHeight: CGFloat, scrollableRange: CGFloat, bottomExtension: CGFloat
    ) -> CGFloat {
        let desired = max(
            bottomExtension, viewportHeight * bottomDismissalDeadZoneViewportFraction)
        return min(desired, max(0, scrollableRange) * bottomDismissalDeadZoneRangeFraction)
    }

    /// Hooks the immersion triggers onto `root`'s live content (KVO on every
    /// scroll view, play-state callbacks on every RSVP controller). Idempotent
    /// for scroll views (already-observed ones are skipped) — call again
    /// whenever the reader's hierarchy changes (a dive, pop, mode switch, or
    /// late embed swaps the live scroll views / RSVP controllers).
    func observe(_ root: UIViewController) {
        for rsvp in Self.rsvpControllers(of: root) {
            rsvp.playbackObserver = self
        }
        for scrollView in Self.scrollViews(in: root.view) {
            let key = ObjectIdentifier(scrollView)
            guard scrollObservations[key] == nil else { continue }
            // Synchronous on purpose: isDragging/isDecelerating must be sampled
            // at change time — deferred to the next runloop, a quick flick's
            // whole gesture reads as already-settled.
            scrollObservations[key] = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] scrollView, _ in
                self?.handleOffsetChange(of: scrollView)
            }
        }
    }

    private func handleOffsetChange(of scrollView: UIScrollView) {
        guard isActive, allowsScrollDrivenImmersion, !applyingScrollImmersion,
              !ScrollPresentationState.isSuppressed(for: scrollView) else { return }
        let key = ObjectIdentifier(scrollView)
        // Sample eligibility on every offset so the host can commit fullscreen
        // when the last transitional line leaves, even during a fling or a jump.
        let canReverse = delegate?.canReverseScrollDismissal(self, in: scrollView) ?? false
        guard scrollView.isDragging || scrollView.isDecelerating else {
            scrollRuns[key] = nil
            return
        }
        // Distance from the content's top (0 = at the top).
        let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let maximumPosition = max(
            0,
            scrollView.contentSize.height + scrollView.adjustedContentInset.top
                + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let travelPosition = min(max(0, position), maximumPosition)
            - ScrollPresentationState.offsetAdjustment(for: scrollView)
        let previous = scrollRuns[key]
        let delta = travelPosition - (previous?.last ?? travelPosition)
        let remainingToBottom = max(0, maximumPosition - position)
        let bottomExtension = max(0, delegate?.immersionBottomExtension(for: self) ?? 0)

        if delta < 0, canReverse, scrollView.isDragging {
            changeScrollImmersion(false, in: scrollView)
            return
        }
        if bottomExtension > 0 {
            if delta > 0, remainingToBottom <= Self.bottomRestoreTolerance {
                changeScrollImmersion(false, in: scrollView)
            } else {
                scrollRuns[key] = (travelPosition, 0)
            }
            return
        }
        let dismissalDeadZoneStart = Self.dismissalDeadZoneStart(
            viewportHeight: scrollView.bounds.height, scrollableRange: maximumPosition,
            bottomExtension: bottomExtension)
        let run = delta < 0 || remainingToBottom <= dismissalDeadZoneStart
            ? 0 : (previous?.run ?? 0) + delta
        scrollRuns[key] = (travelPosition, run)
        if run >= Self.fadeOutTravel, position > 0 {
            changeScrollImmersion(true, in: scrollView)
        }
    }

    private func changeScrollImmersion(_ immersed: Bool, in scrollView: UIScrollView) {
        scrollRuns = [:]
        applyingScrollImmersion = true
        defer { applyingScrollImmersion = false }
        delegate?.immersionTracker(self, didChangeImmersion: immersed, extendsCard: true)
        // Seed from the resized card so the next user offset can reverse it.
        let insets = scrollView.adjustedContentInset
        let maximum = max(0, scrollView.contentSize.height + insets.top + insets.bottom
            - scrollView.bounds.height)
        let position = min(max(0, scrollView.contentOffset.y + insets.top), maximum)
        scrollRuns[ObjectIdentifier(scrollView)] = (
            position - ScrollPresentationState.offsetAdjustment(for: scrollView), 0)
    }

    /// RSVP immerses without the card-bottom extension: its layout is fixed, so
    /// play/pause must not move anything on screen.
    func rsvpReader(_ reader: RSVPViewController, didChangePlaybackState playing: Bool) {
        guard isActive else { return }
        delegate?.immersionTracker(self, didChangeImmersion: playing, extendsCard: false)
    }

    private static func rsvpControllers(of root: UIViewController) -> [RSVPViewController] {
        var found: [RSVPViewController] = []
        for child in root.children {
            if let rsvp = child as? RSVPViewController { found.append(rsvp) }
            found.append(contentsOf: rsvpControllers(of: child))
        }
        return found
    }

    private static func scrollViews(in root: UIView, depth: Int = 0) -> [UIScrollView] {
        guard depth < 8 else { return [] }
        var found: [UIScrollView] = []
        for subview in root.subviews {
            if let scroll = subview as? UIScrollView { found.append(scroll) }
            found.append(contentsOf: scrollViews(in: subview, depth: depth + 1))
        }
        return found
    }
}
