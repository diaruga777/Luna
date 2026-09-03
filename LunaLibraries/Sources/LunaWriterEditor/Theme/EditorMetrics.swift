//
//  EditorMetrics.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterStorage
import LunaWriterText

/// The editor's geometry, as pure arithmetic over the body size and the
/// container width. Nothing here reads a view, so the styler, the accessory
/// bar and a test all get the same numbers.
public struct EditorMetrics: Equatable {

    /// The body point size every other size derives from.
    public var bodySize: CGFloat
    public var lineWidth: EditorLineWidth

    public init(bodySize: CGFloat = CGFloat(WriterSettings.defaultFontSize), lineWidth: EditorLineWidth = .medium) {
        self.bodySize = bodySize
        self.lineWidth = lineWidth
    }

    public init(settings: WriterSettings) {
        self.init(bodySize: CGFloat(settings.fontSize), lineWidth: settings.lineWidth)
    }

    /// iA's heading ladder. Levels past three read as body with a heavier face.
    public static func headingScale(forLevel level: Int) -> CGFloat {
        switch level {
        case 1: return 1.6
        case 2: return 1.35
        case 3: return 1.15
        default: return 1.0
        }
    }

    public func headingSize(forLevel level: Int) -> CGFloat {
        (bodySize * Self.headingScale(forLevel: level)).rounded()
    }

    /// A line box tall enough for descenders and the markup glyphs above them.
    public var lineHeightMultiple: CGFloat { 1.5 }

    public var paragraphSpacing: CGFloat { (bodySize * 0.75).rounded() }

    public func headingSpacingBefore(level: Int) -> CGFloat {
        level <= 2 ? (bodySize * 1.4).rounded() : (bodySize * 1.0).rounded()
    }

    /// 2.2 em, the indent iA gives a list marker.
    public var listIndent: CGFloat { (bodySize * 2.2).rounded() }

    public var quoteIndent: CGFloat { (bodySize * 1.4).rounded() }

    public var codeIndent: CGFloat { (bodySize * 0.9).rounded() }

    public var codeSize: CGFloat { (bodySize * 0.92).rounded() }

    /// The widest the text column may grow, whatever the screen does.
    public var maximumColumnWidth: CGFloat {
        switch lineWidth {
        case .narrow: return (LunaLayout.readableWidth * 0.78).rounded()
        case .medium: return LunaLayout.readableWidth
        case .wide: return (LunaLayout.readableWidth * 1.25).rounded()
        }
    }

    /// The smallest side padding a phone keeps, so a glyph never touches the edge.
    public static let minimumSidePadding: CGFloat = 20

    public func columnWidth(forContainerWidth width: CGFloat) -> CGFloat {
        max(0, min(maximumColumnWidth, width - Self.minimumSidePadding * 2))
    }

    /// Centres the column inside the container and leaves room to scroll the
    /// last line up to the typewriter position.
    public func textContainerInset(forContainerWidth width: CGFloat) -> UIEdgeInsets {
        let column = columnWidth(forContainerWidth: width)
        let side = max(Self.minimumSidePadding, ((width - column) / 2).rounded())
        return UIEdgeInsets(top: (bodySize * 1.6).rounded(), left: side, bottom: (bodySize * 4).rounded(), right: side)
    }

    /// Where the caret line sits when typewriter scrolling is on.
    public static let typewriterFraction: CGFloat = 0.45
}
