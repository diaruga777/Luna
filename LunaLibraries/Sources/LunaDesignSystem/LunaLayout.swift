//
//  LunaLayout.swift
//  LunaDesignSystem
//
//  The one place that decides what "there is more room here" means.
//
//  Every Luna app runs on iPhone and iPad from the same sources, so the
//  question "is this container wide?" gets asked from the card carousel, the
//  reader, onboarding, settings, and the share/action extensions. Answering it
//  locally in each of those produced nothing but drift, so it is answered once,
//  here, as pure geometry over a container WIDTH — never the device idiom.
//
//  Width, not idiom, is the honest input: an iPad app in a half-screen Split
//  View, an extension sheet, and an iPhone are all the same layout problem, and
//  a 13" iPad in landscape is a different one from the same device in portrait.
//

import CoreGraphics
import Foundation

/// Pure layout policy shared by every Luna surface. No UIKit view state, so it
/// is unit-tested directly (`LunaLayoutTests`).
public enum LunaLayout {
    /// A container at least this wide has room for two reader columns side by
    /// side, and therefore also has room to stop stretching one card across the
    /// whole screen. Below it, a surface lays out exactly as it does on iPhone.
    ///
    /// 700pt sits above every iPhone (the widest is 440pt) and below every iPad
    /// in portrait (the narrowest, iPad mini, is 744pt) — so it reads as "an
    /// iPad, or an iPad-sized share sheet", and a half-width Split View window
    /// correctly reads as phone-shaped.
    public static let wideThreshold: CGFloat = 700

    /// Horizontal breathing room kept outside the capped card (or the pair of
    /// them) on a wide container.
    public static let wideEdgePadding: CGFloat = 24

    /// Gap between the two columns of a side-by-side reader.
    public static let columnGap: CGFloat = 24

    /// Widest a body of running text — or a column of form rows — stays
    /// readable. Beyond roughly this, line length costs more than the extra room
    /// gains, so prose, settings tables, and status screens are centered at this
    /// width instead of stretched. Deliberately close to UIKit's own
    /// `readableContentGuide`, which is the same judgement.
    public static let readableWidth: CGFloat = 680

    /// Width the onboarding replicas (Messages, Safari) are drawn at. They are
    /// deliberate imitations of a PHONE, so on a wide container they keep phone
    /// proportions and center rather than growing into something the user has
    /// never seen.
    public static let phoneReplicaWidth: CGFloat = 430

    /// Whether `width` is wide enough to lay out for the extra room.
    public static func isWide(containerWidth width: CGFloat) -> Bool {
        width >= wideThreshold
    }

    /// How far a capped card's center sits from the container's center when the
    /// container holds two of them side by side. Half a card plus half the gap.
    ///
    /// Derived from the same numbers as `cardWidthCap`, so a left column at
    /// `-columnCenterOffset` and a right column at `+columnCenterOffset` land
    /// exactly `wideEdgePadding` inside each container edge.
    public static func columnCenterOffset(forContainerWidth width: CGFloat) -> CGFloat {
        (cardWidthCap(forContainerWidth: width) ?? width) / 2 + columnGap / 2
    }

    /// The widest a single carousel card may be: **half the container minus
    /// padding**, once the container is wide enough for a full-width card to
    /// read as a stretched phone layout. `nil` on a phone-shaped container,
    /// where the card keeps every point it can get.
    ///
    /// The subtracted inset is `wideEdgePadding + columnGap / 2`, not just the
    /// edge padding, so that TWO capped cards plus the gap between them span
    /// exactly the container minus `wideEdgePadding` on each side. That is what
    /// lets the side-by-side reader reuse this one width for both of its
    /// columns instead of resizing the card it slides aside.
    public static func cardWidthCap(forContainerWidth width: CGFloat) -> CGFloat? {
        guard isWide(containerWidth: width) else { return nil }
        return max(40, width / 2 - wideEdgePadding - columnGap / 2)
    }

    /// A centered, readability-capped width for text-forward content.
    public static func contentWidth(forContainerWidth width: CGFloat) -> CGFloat {
        guard isWide(containerWidth: width) else { return width }
        return min(width - wideEdgePadding * 2, readableWidth)
    }

    /// Insets that center `contentWidth(forContainerWidth:)` inside `width`.
    /// Zero on a phone-shaped container, so callers can apply them
    /// unconditionally.
    public static func contentHorizontalInset(forContainerWidth width: CGFloat) -> CGFloat {
        max(0, (width - contentWidth(forContainerWidth: width)) / 2)
    }

    /// Widest an edge drawer (the archive arc, the left setup tray) gets. Their
    /// phone widths are fractions of the screen, and a two-thirds drawer on a 13"
    /// iPad is 911 points of arc carrying 128pt-tall cells — the fraction has to
    /// stop somewhere.
    public static let maximumDrawerWidth: CGFloat = 520

    /// A drawer `fraction` of the container wide, capped on a wide container.
    public static func drawerWidth(
        forContainerWidth width: CGFloat, fraction: CGFloat
    ) -> CGFloat {
        let proportional = width * fraction
        guard isWide(containerWidth: width) else { return proportional }
        return min(proportional, maximumDrawerWidth)
    }

    /// Insets that center a phone-proportioned replica inside `width`.
    public static func phoneReplicaHorizontalInset(forContainerWidth width: CGFloat) -> CGFloat {
        guard isWide(containerWidth: width) else { return 0 }
        return max(0, (width - min(width - wideEdgePadding * 2, phoneReplicaWidth)) / 2)
    }
}
