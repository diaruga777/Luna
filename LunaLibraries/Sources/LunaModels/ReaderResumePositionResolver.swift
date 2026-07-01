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
/// real evidence the user moved: either the page was scrolled past a threshold,
/// or eye tracking locked onto several consecutive words. With neither, the
/// reported index is exactly the index the reader was opened with — a no-op.
///
/// This type holds no view state; the view feeds it the facts it has measured
/// (did the user scroll past the threshold, did the gaze lock, the freshly
/// computed visible/gaze indices) and gets back the index to report. Keeping it
/// pure makes the open/close-is-a-no-op guarantee directly testable.
public enum ReaderResumePositionResolver {

    /// How far (in points) the content offset must move from where the reader
    /// was opened before a scroll counts as a deliberate reposition. Smaller
    /// than a screen so a real scroll registers, larger than incidental layout
    /// jitter / rubber-band settle so merely opening the reader never trips it.
    public static let scrolledPastThresholdPoints: CGFloat = 44

    /// How many consecutive distinct word indices the gaze tracker must report
    /// before its estimate is treated as a stable lock allowed to move the
    /// carried position. A single noisy gaze sample (or a couple) never counts;
    /// only a gaze that steadily tracks across several words does.
    public static let consecutiveGazeWordsForLock = 4

    /// Whether the reader has scrolled far enough from its opening offset to
    /// count as a deliberate reposition.
    public static func scrolledPastThreshold(openOffsetY: CGFloat, currentOffsetY: CGFloat) -> Bool {
        abs(currentOffsetY - openOffsetY) >= scrolledPastThresholdPoints
    }

    /// The word index the scroll reader should report as its current reading
    /// position, given the index it was opened with and the evidence gathered
    /// while it was on screen.
    ///
    /// - If the user scrolled past the threshold, the visible position wins
    ///   (`firstFullyVisibleIndex`, falling back to the resume index if the
    ///   visible index couldn't be computed).
    /// - Otherwise, if eye tracking confirmed a multi-word lock, the confirmed
    ///   gaze index wins.
    /// - Otherwise the reader did nothing meaningful: return the unchanged
    ///   resume index (no update).
    public static func reportedWordIndex(
        resumeIndex: Int?,
        scrolledPastThreshold: Bool,
        confirmedGazeIndex: Int?,
        firstFullyVisibleIndex: Int?
    ) -> Int? {
        if scrolledPastThreshold {
            return firstFullyVisibleIndex ?? resumeIndex
        }
        if let confirmedGazeIndex {
            return confirmedGazeIndex
        }
        return resumeIndex
    }
}

/// Tracks whether the gaze tracker has produced a stable, multi-word lock —
/// several consecutive *distinct* word indices in a row — so a single noisy
/// gaze sample can't move the carried reading position. Feed it each gaze word
/// index as it arrives; `confirmedIndex` is non-nil only once the run reaches
/// `ReaderResumePositionResolver.consecutiveGazeWordsForLock`.
public struct GazeLockGate {

    private let wordsNeeded: Int
    private var lastIndex: Int?
    private var consecutiveDistinctCount = 0
    public private(set) var confirmedIndex: Int?

    public init(wordsNeeded: Int = ReaderResumePositionResolver.consecutiveGazeWordsForLock) {
        self.wordsNeeded = wordsNeeded
    }

    /// Records one gaze word-index sample, updating the lock state.
    public mutating func record(_ index: Int) {
        if index == lastIndex {
            // The same word repeating doesn't extend the lock — we want the
            // gaze to track ACROSS several words, not dwell on one.
            return
        }
        lastIndex = index
        consecutiveDistinctCount += 1
        if consecutiveDistinctCount >= wordsNeeded {
            confirmedIndex = index
        }
    }
}
