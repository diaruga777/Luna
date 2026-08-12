//
//  ScrollDirectionImmersionTracker.swift
//  Luna
//

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

/// Detects "is the user reading on, or surfacing" under an arbitrary reader
/// hierarchy and reports it as a single immersion signal: KVO on every nested
/// scroll view for the scroll reader's direction, `onPlaybackStateChanged` on
/// every nested RSVP controller for its play state. Generic over any reader
/// hosted anywhere — nothing here is carousel- or card-specific.
final class ScrollDirectionImmersionTracker {

    /// False on large/wide hosts, where scrolling must never change card chrome.
    /// RSVP callbacks remain active because its play/pause state is independent
    /// of this scroll-only gate.
    var allowsScrollDrivenImmersion = true {
        didSet {
            guard !allowsScrollDrivenImmersion else { return }
            scrollRuns = [:]
        }
    }

    /// The reader wants the host chrome faded away (true — reading is under
    /// way) or back in (false — the user is surfacing). `extendsCard` mirrors
    /// the host's own choice of whether an immersed layout should extend into
    /// the freed room: true for the scroll reader (more content shows), false
    /// for RSVP, whose fixed layout must not move when playback starts — only
    /// the chrome fades.
    var onImmersionChange: ((_ immersed: Bool, _ extendsCard: Bool) -> Void)?

    /// How much taller the live, immersed card is than its resting footprint —
    /// i.e. how far the card's bottom edge travels back UP when the chrome
    /// returns. It does not gate the bottom restore (the article's end can never
    /// reach the restored edge while the taller card still owns the scroll
    /// range); it marks the card as currently immersed and floors the downward
    /// dismissal dead zone.
    var immersionBottomExtension: (() -> CGFloat)?

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
    /// Per scroll view: the last seen offset and the directional run since the
    /// last direction flip (positive = scrolling down the article).
    private var scrollRuns: [ObjectIdentifier: (last: CGFloat, run: CGFloat)] = [:]

    /// Downward travel (pt) before the chrome fades away…
    private static let fadeOutTravel: CGFloat = 100
    /// …and the smaller upward travel that deliberately signals surfacing.
    /// This still absorbs line-height jitter, but makes chrome return promptly
    /// without matching the longer downward dismissal gesture.
    private static let fadeInTravel: CGFloat = 50
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
            rsvp.onPlaybackStateChanged = { [weak self] playing in
                guard let self, self.isActive else { return }
                // RSVP immerses without the card-bottom extension: its layout
                // is fixed, so play/pause must not move anything on screen.
                self.onImmersionChange?(playing, false)
            }
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

    /// Direction-driven, not position-driven: scrolling down (reading on)
    /// fades the carousel chrome away; scrolling up — from anywhere in the
    /// article — fades it back in. Travel accumulates per direction and
    /// resets on a flip, so line-height jitter can't toggle the state, and
    /// `isDragging`/`isDecelerating` keeps restore-position and
    /// text-selection offsets from counting as reading.
    private func handleOffsetChange(of scrollView: UIScrollView) {
        let key = ObjectIdentifier(scrollView)
        guard isActive, allowsScrollDrivenImmersion,
              scrollView.isDragging || scrollView.isDecelerating
        else {
            scrollRuns[key] = nil
            return
        }
        // Distance from the content's top (0 = at the top).
        let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let maximumPosition = max(
            0,
            scrollView.contentSize.height + scrollView.adjustedContentInset.top
                + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let remainingToBottom = max(0, maximumPosition - position)
        let bottomExtension = max(0, immersionBottomExtension?() ?? 0)
        let dismissalDeadZoneStart = Self.dismissalDeadZoneStart(
            viewportHeight: scrollView.bounds.height,
            scrollableRange: maximumPosition,
            bottomExtension: bottomExtension)
        let reachedArticleEnd = remainingToBottom <= Self.bottomRestoreTolerance

        // Position exceptions do not need a directional run. At the top the
        // chrome always returns immediately; at the bottom it returns as the end
        // of the content lands on the viewport's bottom edge — the host then
        // slides the content up by the extension so that end stays put under the
        // returning card edge.
        let previous = scrollRuns[key]
        if (previous != nil && (position <= 0 || reachedArticleEnd))
            || (bottomExtension > 0 && reachedArticleEnd) {
            scrollRuns = [:]
            onImmersionChange?(false, true)
            return
        }
        guard let previous else {
            scrollRuns[key] = (position, 0)
            return
        }
        let delta = position - previous.last
        if delta >= 0, remainingToBottom <= dismissalDeadZoneStart {
            // Keep a fresh baseline so travel accumulated above the dead zone
            // cannot fire on a later layout/clamping offset near the bottom.
            scrollRuns[key] = (position, 0)
            return
        }
        let run = (delta >= 0) == (previous.run >= 0) ? previous.run + delta : delta
        scrollRuns[key] = (position, run)
        // Re-seed the runs BEFORE firing: the fade's card-bottom extension
        // resizes the scroll view synchronously, and at the article's end
        // that clamps the offset — a synthetic ~90pt "scroll up" delivered
        // re-entrantly that would immediately fade the chrome back in. With
        // the runs cleared first, that event just seeds a fresh baseline.
        if run <= -Self.fadeInTravel {
            scrollRuns = [:]
            onImmersionChange?(false, true)
        } else if run >= Self.fadeOutTravel, position > 0 {
            scrollRuns = [:]
            onImmersionChange?(true, true)
        }
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
