//
//  ReaderResumePositionResolver.swift
//  Luna
//

import CoreGraphics

/// Pure decision logic for what word index the scroll reader reports as its
/// current reading position when carrying it over to another mode (RSVP /
/// highlight).
///
/// The scroll reader must NOT move the carried word position just from being
/// opened and closed. It only updates the carried index when the reader has
/// real evidence the user moved: the page was scrolled past a threshold. With
/// no such evidence, the reported index is exactly the index the reader was
/// opened with — a no-op.
///
/// This type holds no view state; the view feeds it the facts it has measured
/// (did the user scroll past the threshold, the freshly computed visible index)
/// and gets back the index to report. Keeping it pure makes the
/// open/close-is-a-no-op guarantee directly testable.
public enum ReaderResumePositionResolver {

    /// How far (in points) the content offset must move from where the reader
    /// was opened before a scroll counts as a deliberate reposition. Smaller
    /// than a screen so a real scroll registers, larger than incidental layout
    /// jitter / rubber-band settle so merely opening the reader never trips it.
    public static let scrolledPastThresholdPoints: CGFloat = 44

    /// Whether the reader has scrolled far enough from its opening offset to
    /// count as a deliberate reposition.
    public static func scrolledPastThreshold(openOffsetY: CGFloat, currentOffsetY: CGFloat) -> Bool {
        abs(currentOffsetY - openOffsetY) >= scrolledPastThresholdPoints
    }

    /// The fastest a scroll can move and still plausibly be someone *reading* their
    /// way to a spot rather than flinging past it. Comfortable reading tops out around
    /// ~400 wpm; at body-text line metrics that is well under ~120 pt/s of travel, so
    /// this generous ceiling clears deliberate reading (even fast skimming) yet sits
    /// far below an inertial fling (thousands of pt/s). Used only to disqualify a fast
    /// fling that lands on the very start or end — see `shouldCountLanding`.
    public static let readableScrollSpeedPointsPerSecond: CGFloat = 600

    /// Whether a scroll that has just settled should update the shared reading
    /// position. The safety rule: a fast fling to the very START or END of the article
    /// (glancing at the top/bottom, then flinging back) must NOT move the persisted
    /// position — only a landing the reader could have *read* their way to counts.
    ///
    /// So a landing is disqualified only when BOTH hold: it is at an extreme edge, and
    /// it arrived faster than a human could read. Every other landing counts — a fast
    /// fling that stops MID-article, or a slow, deliberate scroll all the way to an
    /// edge.
    public static func shouldCountLanding(atExtreme: Bool, speedPointsPerSecond: CGFloat) -> Bool {
        !(atExtreme && speedPointsPerSecond > readableScrollSpeedPointsPerSecond)
    }

    /// The word index the scroll reader should report as its current reading
    /// position, given the index it was opened with and the evidence gathered
    /// while it was on screen.
    ///
    /// - If the user scrolled past the threshold, the visible position wins
    ///   (`firstFullyVisibleIndex`, falling back to the resume index if the
    ///   visible index couldn't be computed).
    /// - Otherwise the reader did nothing meaningful: return the unchanged
    ///   resume index (no update).
    public static func reportedWordIndex(
        resumeIndex: Int?,
        scrolledPastThreshold: Bool,
        firstFullyVisibleIndex: Int?
    ) -> Int? {
        if scrolledPastThreshold {
            return firstFullyVisibleIndex ?? resumeIndex
        }
        return resumeIndex
    }
}
