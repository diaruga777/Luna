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

    /// Points of a neighboring card visible inside the container edge.
    public static let peek: CGFloat = 14
    /// Extra horizontal inset applied only to the centered card, giving the
    /// insets beside it enough width for paging swipes.
    public static let edgeGap: CGFloat = 10
    /// Resting scale of the non-centered (peeking) cards.
    public static let sideScale: CGFloat = 0.92
    /// Room kept above and below the card inside the card area.
    public static let verticalPadding: CGFloat = 12

    /// Reader previews use a continuous collection with two rows.
    public var isPreviewGrid = false
    public var columnStride: CGFloat { cardSize.width + 24 }

    public var containerSize: CGSize
    public var cardSize: CGSize
    /// Points of a neighboring card visibly inside the container edge.
    public var peek: CGFloat
    /// Resting scale of the non-centered (peeking) cards.
    public var sideScale: CGFloat

    public init(
        containerSize: CGSize,
        cardSize: CGSize,
        peek: CGFloat,
        sideScale: CGFloat
    ) {
        self.containerSize = containerSize
        self.cardSize = cardSize
        self.peek = peek
        self.sideScale = sideScale
    }

    /// Fits **the** card into `containerSize`: the largest exact-9:16 rectangle
    /// that leaves at least `peek + edgeGap` horizontal room on each side and
    /// `verticalPadding` above/below, centered in what remains. `edgeGap` insets
    /// only the centered card (the peeking neighbors stay `peek` points inside
    /// the screen edge regardless), giving the insets beside the card enough
    /// width for paging swipes. Small containers degrade gracefully (never a
    /// negative/zero size).
    ///
    /// **There is exactly one card shape, and this is it.** Every kind of save
    /// gets the same centered 9:16 rectangle, so paging between kinds never
    /// resizes or re-centers the card mid-transition, and the launch splash can
    /// match every kind's geometry at once. Nothing about a save justifies a
    /// different frame: the frame is the deck's, and the deck's frame is a
    /// function of the screen (`CardDeckGeometry`).
    ///
    /// This is deliberately an aspect-fit calculation, not a wide-screen width
    /// cap. The card area has already reserved the deck's top controls and
    /// scrubber, so a tall iPad can use that otherwise empty vertical space
    /// while still leaving the same paging insets at its sides.
    public static func resolve(
        containerSize: CGSize,
        peek: CGFloat = Self.peek,
        edgeGap: CGFloat = Self.edgeGap,
        sideScale: CGFloat = Self.sideScale,
        verticalPadding: CGFloat = Self.verticalPadding
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

    /// Two equal rows of article previews. Width follows available space instead
    /// of the portrait deck aspect ratio; all columns have equal visual weight.
    public static func readerGrid(containerSize: CGSize, prefersExpandedLayout: Bool = false) -> CardCarouselMetrics {
        var result = resolve(containerSize: containerSize)
        guard containerSize.width >= 700 || (prefersExpandedLayout && containerSize.width >= 560) else { return result }
        let height = max(40, (containerSize.height - 48) / 2)
        let width = min(340, max(260, (containerSize.width - 64) / 3))
        result.cardSize = CGSize(width: width, height: height)
        result.sideScale = 1
        result.isPreviewGrid = true
        return result
    }

    public func previewFrame(at index: Int) -> CGRect {
        CGRect(x: 24 + CGFloat(index / 2) * columnStride,
               y: 12 + CGFloat(index % 2) * (cardSize.height + 24),
               width: cardSize.width, height: cardSize.height)
    }

    public func previewContentWidth(count: Int) -> CGFloat {
        max(containerSize.width, 48 + CGFloat((max(0, count) + 1) / 2) * columnStride - 24)
    }

    /// One offscreen column on either side keeps native scrolling smooth.
    public func previewIndices(offset: CGFloat) -> ClosedRange<Int> {
        let first = max(0, Int(floor((offset - 24) / columnStride)) - 1)
        let last = max(first, Int(ceil((offset + containerSize.width) / columnStride)))
        return (first * 2)...(last * 2 + 1)
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
        if isPreviewGrid { return containerSize.width / 2 + CGFloat(offset) * columnStride }
        guard offset != 0 else { return containerSize.width / 2 }
        let scaledWidth = cardSize.width * sideScale
        let step = CGFloat(abs(offset) - 1) * scaledWidth
        if offset > 0 {
            return containerSize.width - peek + scaledWidth / 2 + step
        }
        return peek - scaledWidth / 2 - step
    }

    /// Vertical center shared by every slot: the container's midpoint. Every
    /// card is the same rectangle, so there is nothing else it could be.
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
