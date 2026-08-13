//
//  CardDeckGeometry.swift
//  LunaDesignSystem
//
//  Where the one card sits on the screen — before any deck exists.
//

import UIKit

/// The card deck's frame, as pure arithmetic over a screen size and its safe
/// area. No views, no view controllers, no live layout pass.
///
/// The carousel builds the same rectangle out of constraints (`cardArea` pinned
/// below the safe area plus `topClearance`, above the scrub strip) and then asks
/// `CardCarouselMetrics.resolve` to fit the card into it. This type answers the
/// same question for the two callers that have no carousel to ask:
///
/// - **the launch splash**, which draws the card and its corona in the very
///   first frame — before a window has a root, and in a launch storyboard that
///   never runs any of our code at all;
/// - **tests**, which pin the two answers together so they cannot drift.
///
/// There is nothing to approximate: the deck's card frame is this function of
/// the screen, the same on every device, for every app and every content kind.
public enum CardDeckGeometry {
    /// Chrome clearance every deck reserves between the safe-area top and the
    /// card area.
    ///
    /// It is the Reader's floating control row (44pt of glass circles plus a 4pt
    /// gap), and it is reserved by **every** deck — including the three that
    /// float nothing there — because the card frame has to be a function of the
    /// screen rather than of which app you opened. The row still overhangs the
    /// card's own top edge, which is what its content edge fade is for.
    public static let topClearance: CGFloat = 48

    /// Gap between the scrub strip's bottom edge and the safe area.
    public static let scrubberBottomGap: CGFloat = 8

    /// Total height the deck's bottom chrome takes out of the screen below the
    /// safe area: the scrub strip and its gap.
    public static var bottomChromeHeight: CGFloat {
        CarouselScrubberView.preferredHeight + scrubberBottomGap
    }

    /// The card AREA — the room the carousel fits cards into — in the
    /// coordinate space of a full-screen deck.
    public static func cardArea(
        inScreenSize screenSize: CGSize,
        safeAreaInsets: UIEdgeInsets
    ) -> CGRect {
        let top = safeAreaInsets.top + topClearance
        let bottom = screenSize.height - safeAreaInsets.bottom - bottomChromeHeight
        return CGRect(
            x: 0,
            y: top,
            width: screenSize.width,
            height: max(40, bottom - top))
    }

    /// The centered card's resting frame in screen coordinates. Identical for
    /// every app, every deck and every content kind — which is exactly why the
    /// launch splash can be drawn at it.
    public static func cardFrame(
        inScreenSize screenSize: CGSize,
        safeAreaInsets: UIEdgeInsets
    ) -> CGRect {
        let area = cardArea(inScreenSize: screenSize, safeAreaInsets: safeAreaInsets)
        let metrics = CardCarouselMetrics.resolve(containerSize: area.size)
        return metrics.centeredCardFrame().offsetBy(dx: area.minX, dy: area.minY)
    }
}
