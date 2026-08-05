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

    /// How a card's size comes out of the room the container leaves it.
    public enum CardFit: Hashable {
        /// The 9:16 card, as large as fits, centered in the container.
        case aspectCentered
        /// All available width AND height — the aspect is ignored, for content
        /// that wants every vertical point (the Price Tracker's graph card).
        case fill
        /// All available width at the exact 9:16 aspect, anchored to the
        /// container's bottom padding. The card comes out TALLER than the
        /// container's usable height, so the extra height extends ABOVE the
        /// container's top — through at most `topOverflow` points of host chrome
        /// floating there, never past it. A container too wide for that
        /// allowance (iPad) keeps the aspect exact by narrowing instead.
        case aspectFromBottom
    }

    public var containerSize: CGSize
    public var cardSize: CGSize
    /// Points of a neighboring card visibly inside the container edge.
    public var peek: CGFloat
    /// Resting scale of the non-centered (peeking) cards.
    public var sideScale: CGFloat
    /// Vertical center shared by every slot. The container's midpoint for the
    /// centered fits; below it for `.aspectFromBottom`, whose card overflows the
    /// container's top.
    public var cardCenterY: CGFloat

    public init(
        containerSize: CGSize,
        cardSize: CGSize,
        peek: CGFloat,
        sideScale: CGFloat,
        cardCenterY: CGFloat? = nil
    ) {
        self.containerSize = containerSize
        self.cardSize = cardSize
        self.peek = peek
        self.sideScale = sideScale
        self.cardCenterY = cardCenterY ?? containerSize.height / 2
    }

    /// Fits a card into `containerSize`, leaving at least `peek + edgeGap`
    /// horizontal room on each side and `verticalPadding` above/below.
    /// `edgeGap` insets only the centered card (the peeking neighbors stay
    /// `peek` points inside the screen edge regardless), giving the insets
    /// beside the card enough width for paging swipes.
    ///
    /// `fit` decides how the card fills that room — see `CardFit`. Small
    /// containers degrade gracefully (never a negative/zero size).
    ///
    /// `topOverflow` applies to `.aspectFromBottom` only: how much extra height
    /// above the container's usable height the card may claim for its exact
    /// aspect. Since that height is spent from the card's own bottom padding
    /// upward, a clamped card's top edge stops `verticalPadding` short of the
    /// allowance rather than flush against it.
    ///
    /// On a container wide enough to have room to spare (`LunaLayout.isWide`),
    /// the card is additionally capped at `LunaLayout.cardWidthCap` — half the
    /// container minus padding — for EVERY fit. A card stretched across an iPad
    /// reads as a blown-up phone layout, and the cap is what leaves room for the
    /// side-by-side reader's second column at the identical width.
    public static func resolve(
        containerSize: CGSize,
        peek: CGFloat = 14,
        edgeGap: CGFloat = 30,
        sideScale: CGFloat = 0.92,
        verticalPadding: CGFloat = 12,
        fit: CardFit = .aspectCentered,
        topOverflow: CGFloat = 0
    ) -> CardCarouselMetrics {
        let availableHeight = max(40, containerSize.height - verticalPadding * 2)
        let widthCap = LunaLayout.cardWidthCap(forContainerWidth: containerSize.width)
        let availableWidth = min(
            max(40, containerSize.width - (peek + edgeGap) * 2),
            widthCap ?? .greatestFiniteMagnitude)
        var height = availableHeight
        var width: CGFloat
        var centerY = containerSize.height / 2
        switch fit {
        case .fill:
            width = availableWidth
        case .aspectCentered:
            width = height * cardAspectRatio
            if width > availableWidth {
                width = availableWidth
                height = width / cardAspectRatio
            }
        case .aspectFromBottom:
            width = availableWidth
            height = width / cardAspectRatio
            let maxHeight = availableHeight + max(0, topOverflow)
            if height > maxHeight {
                height = maxHeight
                width = height * cardAspectRatio
            }
            if height < availableHeight {
                // Only reachable on a wide container, where the width cap makes
                // the exact-aspect card SHORTER than the room instead of taller.
                // Anchoring its bottom would strand it under a band of empty
                // space, so it grows into the room (bounded by
                // `tallestCardAspectRatio`) and centers in what's left.
                height = min(availableHeight, width / LunaLayout.tallestCardAspectRatio)
                centerY = containerSize.height / 2
            } else {
                // The bottom edge stays exactly where a `.fill` card's was:
                // every extra point of height is added at the TOP.
                centerY = containerSize.height - verticalPadding - height / 2
            }
        }
        return CardCarouselMetrics(
            containerSize: containerSize,
            cardSize: CGSize(width: width, height: height),
            peek: peek,
            sideScale: sideScale,
            cardCenterY: centerY)
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
        cardCenterY
    }

    /// The centered card's frame at rest (scale 1).
    public func centeredCardFrame() -> CGRect {
        CGRect(
            x: containerSize.width / 2 - cardSize.width / 2,
            y: centerY() - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height)
    }

    /// Positions the transient playback indicator inside the centered card's
    /// bottom edge, overlaying the video it reports on — the controller backs
    /// it with a soft scrim for contrast, and the runway beneath the card
    /// stays clear for the strip.
    func playbackScrubProgressFrame(
        horizontalInset: CGFloat = 18,
        bottomInset: CGFloat = 12,
        height: CGFloat
    ) -> CGRect {
        let cardFrame = centeredCardFrame()
        return CGRect(
            x: cardFrame.minX + horizontalInset,
            y: cardFrame.maxY - bottomInset - height,
            width: max(cardFrame.width - horizontalInset * 2, 0),
            height: height)
    }
}

/// Shared math for the thumbnail scrub strip under the cards: which card index
/// a touch maps to.
public enum CarouselScrubberMath {
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
}
