//
//  RSVPPlaybackClock.swift
//  LunaReaderUI
//

import Foundation

/// Fired when a scheduled interval elapses. Class-bound and weak so the
/// clock never keeps its owner alive.
public protocol RSVPPlaybackClockDelegate: AnyObject {
    func playbackClockDidFire(_ clock: RSVPPlaybackClock)
}

/// The words-mode word-timer shared by the full RSVP reader and the link
/// preview: schedules one word's on-screen duration (already WPM-derived by
/// the caller, via `RSVPEngine.duration(at:wpm:)`) and remembers its
/// wall-clock start/length so a mid-flight speed change — the reader's
/// press-and-hold slow-motion, the preview's horizontal-drag speed control —
/// can rescale the REMAINING time instead of restarting the word. Neither
/// caller resumes a paused interval's remaining time: pausing always cancels,
/// and un-pausing schedules a fresh full-length duration for the current
/// word, exactly as both did before this was extracted.
///
/// Out of scope: the reader's Phrases-mode chunk timer and its speech/
/// audio-center-driven display stay reader-owned — this is the words-mode
/// timer only, so it knows nothing of `RSVPEngine`, WPM, or word indices.
public final class RSVPPlaybackClock {
    public weak var delegate: RSVPPlaybackClockDelegate?

    /// Overridable for tests — the wall clock the interval's elapsed time is
    /// measured against.
    private let now: () -> Date

    private var timer: Timer?
    private var intervalStart: Date?
    private var intervalDuration: TimeInterval?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var isScheduled: Bool { timer != nil }

    /// The duration most recently passed to `schedule`/`rescaleRemaining`,
    /// while it's still in flight — exposed for tests to assert against.
    public private(set) var scheduledDuration: TimeInterval?

    /// Schedules `delegate.playbackClockDidFire` after `duration`, replacing
    /// any interval already in flight.
    public func schedule(_ duration: TimeInterval) {
        timer?.invalidate()
        intervalStart = now()
        intervalDuration = duration
        scheduledDuration = duration
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            self.delegate?.playbackClockDidFire(self)
        }
    }

    /// Cancels the in-flight interval without firing — pause, skip, and mode
    /// switches all tear down this way before optionally rescheduling.
    public func cancel() {
        timer?.invalidate()
        timer = nil
        intervalStart = nil
        intervalDuration = nil
        scheduledDuration = nil
    }

    /// Rescales the REMAINING time of the in-flight interval by `factor` and
    /// reschedules it — a no-op if nothing is currently scheduled. Used both
    /// for the reader's press-and-hold (factor 2 on begin, 0.5 on release)
    /// and the preview's continuous horizontal-drag speed control (factor =
    /// oldWPM / newWPM).
    public func rescaleRemaining(by factor: Double) {
        guard let start = intervalStart, let duration = intervalDuration, timer != nil else { return }
        let remaining = max(0, duration - now().timeIntervalSince(start)) * factor
        schedule(remaining)
    }
}
