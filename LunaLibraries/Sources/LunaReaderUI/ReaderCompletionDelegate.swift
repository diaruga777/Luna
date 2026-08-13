//
//  ReaderCompletionDelegate.swift
//  LunaReaderUI
//

import UIKit

/// Notifications a reader (RSVP or scroll) sends its host when it reaches, or
/// moves away from, the end of the article. Both `RSVPViewController` and
/// `ScrollReaderViewController` conform; `ReaderViewController` and
/// `RabbitHoleLayerViewController` each wire one delegate to whichever of the
/// two is currently embedded.
public protocol ReaderCompletionDelegate: AnyObject {
    /// Fired once when playback/scrolling reaches the end of the article.
    func readerDidFinishReading(_ reader: UIViewController)
    /// Fired when a reader that had reached the end moves back before it.
    func readerDidMoveAwayFromEnd(_ reader: UIViewController)
}

/// The fire-once/fire-back bookkeeping shared by both readers' "reached the
/// end" detection. Each reader supplies its own edge test (scroll-ratio vs
/// frame-index) via `reachedEnd`; this only tracks the transition so "finished"
/// fires exactly once per arrival at the end, and "moved away" exactly once
/// per departure from it.
public struct FinishedReadingTracker {
    public enum Transition { case finished, movedAway }

    public private(set) var isFinished = false

    public init() {}

    /// Feed a fresh `reachedEnd` reading. Returns the transition that just
    /// fired, or nil when the state didn't change (repeated calls in the same
    /// state are a no-op).
    @discardableResult
    public mutating func update(reachedEnd: Bool) -> Transition? {
        if reachedEnd, !isFinished {
            isFinished = true
            return .finished
        } else if !reachedEnd, isFinished {
            isFinished = false
            return .movedAway
        }
        return nil
    }

    /// Unconditionally marks finished, for a host that reports "the article
    /// just finished" as a one-off event (e.g. the legacy `SpeechController`
    /// completion callback) rather than a re-checkable state — fires every
    /// time it's called, even if already finished.
    public mutating func markFinished() {
        isFinished = true
    }
}
