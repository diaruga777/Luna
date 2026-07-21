//
//  ScrollDirectionImmersionTracker.swift
//  Luna
//

import LunaReaderUI
import UIKit

/// Detects "is the user reading on, or surfacing" under an arbitrary reader
/// hierarchy and reports it as a single immersion signal: KVO on every nested
/// scroll view for the scroll reader's direction, `onPlaybackStateChanged` on
/// every nested RSVP controller for its play state. Generic over any reader
/// hosted anywhere — nothing here is carousel- or card-specific.
final class ScrollDirectionImmersionTracker {

    /// The reader wants the host chrome faded away (true — reading is under
    /// way) or back in (false — the user is surfacing). `extendsCard` mirrors
    /// the host's own choice of whether an immersed layout should extend into
    /// the freed room: true for the scroll reader (more content shows), false
    /// for RSVP, whose fixed layout must not move when playback starts — only
    /// the chrome fades.
    var onImmersionChange: ((_ immersed: Bool, _ extendsCard: Bool) -> Void)?

    /// How much taller the live, immersed card is than its resting footprint.
    /// When the article's bottom comes within this distance of the viewport,
    /// restoring the chrome puts that bottom exactly at the restored card edge.
    var bottomRevealDistance: (() -> CGFloat)?

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
    private static let fadeOutTravel: CGFloat = 24
    /// …and the fraction of the visible card the user must travel upward
    /// before it comes back. This deliberately resists tiny reverse-scroll
    /// corrections while remaining proportional on iPhone and iPad.
    private static let fadeInViewportFraction: CGFloat = 1 / 3

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
        guard isActive, scrollView.isDragging || scrollView.isDecelerating else {
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
        let revealAtBottom = max(0, bottomRevealDistance?() ?? 0)

        // Position exceptions do not need a directional run. At the top the
        // chrome always returns immediately; near the bottom it returns at the
        // exact point where shrinking to the resting card will meet the
        // article's bottom edge.
        let previous = scrollRuns[key]
        if (previous != nil && (position <= 0 || remainingToBottom <= revealAtBottom))
            || (revealAtBottom > 0 && remainingToBottom <= revealAtBottom) {
            scrollRuns = [:]
            onImmersionChange?(false, true)
            return
        }
        guard let previous else {
            scrollRuns[key] = (position, 0)
            return
        }
        let delta = position - previous.last
        let run = (delta >= 0) == (previous.run >= 0) ? previous.run + delta : delta
        scrollRuns[key] = (position, run)
        // Re-seed the runs BEFORE firing: the fade's card-bottom extension
        // resizes the scroll view synchronously, and at the article's end
        // that clamps the offset — a synthetic ~90pt "scroll up" delivered
        // re-entrantly that would immediately fade the chrome back in. With
        // the runs cleared first, that event just seeds a fresh baseline.
        let fadeInTravel = max(scrollView.bounds.height * Self.fadeInViewportFraction, 1)
        if run <= -fadeInTravel {
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
