//
//  ScrollAssist.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation

/// Keeps the sentence being read inside a comfortable band of the viewport,
/// slowly, and never while the user is scrolling.
///
/// The three rules are what stop an assist from feeling like a fight: it acts
/// only outside the band, moves at most one frame's worth at a time, and
/// stands down for `userSettleDelay` after any touch on the scroll view.
public struct ScrollAssist: Equatable {

    public struct Configuration: Equatable {
        /// Top of the comfortable band, as a fraction of the viewport.
        public var lowFraction: CGFloat
        /// Bottom of it.
        public var highFraction: CGFloat
        /// Largest movement in one frame, in points.
        public var maximumStep: CGFloat
        /// How long a user scroll suppresses the assist.
        public var userSettleDelay: TimeInterval

        public init(
            lowFraction: CGFloat = 0.24,
            highFraction: CGFloat = 0.68,
            maximumStep: CGFloat = 18,
            userSettleDelay: TimeInterval = 1.4
        ) {
            self.lowFraction = lowFraction
            self.highFraction = highFraction
            self.maximumStep = maximumStep
            self.userSettleDelay = userSettleDelay
        }
    }

    public let configuration: Configuration
    private var lastUserScroll: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Records that the user moved the page.
    public mutating func userDidScroll(at time: TimeInterval) {
        lastUserScroll = time
    }

    public mutating func reset() {
        lastUserScroll = nil
    }

    /// True while a user scroll still suppresses the assist.
    public func isSuppressed(at time: TimeInterval) -> Bool {
        guard let lastUserScroll else { return false }
        return time - lastUserScroll < configuration.userSettleDelay
    }

    /// How far to move the content offset this frame, or nil for "leave it".
    ///
    /// - Parameters:
    ///   - bandCentreY: the active sentence's centre, in content coordinates.
    ///   - contentOffsetY: the scroll view's current offset.
    ///   - viewportHeight: the visible height.
    ///   - limit: the largest offset the content allows.
    public func adjustment(
        bandCentreY: CGFloat,
        contentOffsetY: CGFloat,
        viewportHeight: CGFloat,
        maximumOffsetY: CGFloat,
        at time: TimeInterval
    ) -> CGFloat? {
        guard viewportHeight > 0, !isSuppressed(at: time) else { return nil }
        let fraction = (bandCentreY - contentOffsetY) / viewportHeight
        let desired: CGFloat
        if fraction < configuration.lowFraction {
            desired = bandCentreY - configuration.lowFraction * viewportHeight
        } else if fraction > configuration.highFraction {
            desired = bandCentreY - configuration.highFraction * viewportHeight
        } else {
            return nil
        }
        let clamped = min(max(desired, 0), max(maximumOffsetY, 0))
        let delta = clamped - contentOffsetY
        guard abs(delta) > 0.5 else { return nil }
        return min(max(delta, -configuration.maximumStep), configuration.maximumStep)
    }
}
