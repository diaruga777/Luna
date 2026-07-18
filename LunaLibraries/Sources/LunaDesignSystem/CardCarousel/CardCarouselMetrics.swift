//
//  CardCarouselMetrics.swift
//  LunaDesignSystem
//
//  Pure layout math for the vertical-card carousel (portrait 9:16 cards with the
//  neighbors' edges peeking in from the screen sides). No UIKit view state — kept
//  as plain geometry so it's covered by unit tests (see CardCarouselMetricsTests).
//

import CoreGraphics
import Foundation

/// Resolved geometry for one carousel container size: the card size, how much of
/// each neighbor peeks in from the side, and where each slot's center sits.
public struct CardCarouselMetrics: Equatable {
    /// Width : height of a card. Cards are portrait ("16:9 taller than wide").
    public static let cardAspectRatio: CGFloat = 9.0 / 16.0

    public var containerSize: CGSize
    public var cardSize: CGSize
    /// Points of a neighboring card visibly inside the container edge.
    public var peek: CGFloat
    /// Resting scale of the non-centered (peeking) cards.
    public var sideScale: CGFloat

    public init(containerSize: CGSize, cardSize: CGSize, peek: CGFloat, sideScale: CGFloat) {
        self.containerSize = containerSize
        self.cardSize = cardSize
        self.peek = peek
        self.sideScale = sideScale
    }

    /// Fits the largest 9:16 portrait card into `containerSize`, leaving at least
    /// `peek + edgeGap` horizontal room on each side (so the next card's edge is
    /// visible) and `verticalPadding` above/below. Small containers degrade
    /// gracefully (never a negative/zero size).
    public static func resolve(
        containerSize: CGSize,
        peek: CGFloat = 14,
        edgeGap: CGFloat = 10,
        sideScale: CGFloat = 0.92,
        verticalPadding: CGFloat = 12
    ) -> CardCarouselMetrics {
        let availableHeight = max(40, containerSize.height - verticalPadding * 2)
        let availableWidth = max(40, containerSize.width - (peek + edgeGap) * 2)
        var height = availableHeight
        var width = height * cardAspectRatio
        if width > availableWidth {
            width = availableWidth
            height = width / cardAspectRatio
        }
        return CardCarouselMetrics(
            containerSize: containerSize,
            cardSize: CGSize(width: width, height: height),
            peek: peek,
            sideScale: sideScale)
    }

    /// Resting scale for the slot `offset` cards away from center (0 = centered).
    public func scale(forSlotOffset offset: Int) -> CGFloat {
        offset == 0 ? 1 : sideScale
    }

    /// Horizontal center of the slot `offset` cards away from the centered slot.
    /// Side slots sit so exactly `peek` points of the (scaled) card lie inside the
    /// container edge; slots further out continue at one scaled-card-width steps,
    /// fully off screen.
    public func centerX(forSlotOffset offset: Int) -> CGFloat {
        guard offset != 0 else { return containerSize.width / 2 }
        let scaledWidth = cardSize.width * sideScale
        let step = CGFloat(abs(offset) - 1) * scaledWidth
        if offset > 0 {
            return containerSize.width - peek + scaledWidth / 2 + step
        }
        return peek - scaledWidth / 2 - step
    }

    /// Vertical center shared by every slot.
    public func centerY() -> CGFloat {
        containerSize.height / 2
    }

    /// The centered card's frame at rest (scale 1).
    public func centeredCardFrame() -> CGRect {
        CGRect(
            x: containerSize.width / 2 - cardSize.width / 2,
            y: centerY() - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height)
    }
}

/// Shared math for the thumbnail scrub strip under the cards: which card index a
/// touch maps to, and whether a released drag was a quick flick (page one card)
/// rather than a positional scrub (jump to the index under the finger).
public enum CarouselScrubberMath {
    /// A drag released within this many seconds…
    public static let flickMaximumDuration: TimeInterval = 0.3
    /// …that traveled at least this fast…
    public static let flickMinimumVelocity: CGFloat = 500
    /// …but no farther than this, is a flick (page ±1), not a positional scrub.
    public static let flickMaximumTranslation: CGFloat = 70

    /// Maps a touch x (in strip-content coordinates) to a card index.
    public static func index(
        forLocationX x: CGFloat,
        thumbnailWidth: CGFloat,
        spacing: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0, thumbnailWidth > 0 else { return 0 }
        let slot = Int(floor(x / (thumbnailWidth + spacing)))
        return min(max(slot, 0), count - 1)
    }

    /// Classifies a released drag. Returns the page step (+1 = next, -1 = previous)
    /// for a quick flick, or nil when the gesture was a positional scrub.
    public static func flickPageStep(
        translationX: CGFloat,
        velocityX: CGFloat,
        duration: TimeInterval
    ) -> Int? {
        guard duration <= flickMaximumDuration,
              abs(velocityX) >= flickMinimumVelocity,
              abs(translationX) <= flickMaximumTranslation
        else { return nil }
        // Swiping left (negative velocity) advances to the NEXT card, matching
        // scroll direction.
        return velocityX < 0 ? 1 : -1
    }
}
