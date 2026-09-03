//
//  ReadAlongTheme.swift
//  LunaWriterReadAlong
//

import LunaDesignSystem
import LunaModels
import LunaWriterModels
import UIKit

/// The five annotation colours, and the two washes the reading band uses.
///
/// The colours are fixed hexes rather than palette entries: they carry the
/// meaning of the mark ("cut" is red everywhere), so they must not move with
/// the reading accent the user picked.
public enum ReadAlongTheme {

    public static let needsWork = UIColor(hex: 0x8A_4F_D6)
    public static let expand = UIColor(hex: 0x2F_7F_D6)
    public static let cut = UIColor(hex: 0xD6_4A_3C)
    public static let keep = UIColor(hex: 0x3F_9D_59)
    public static let comment = UIColor(hex: 0xE0_B4_00)

    public static func colour(for kind: Annotation.Kind) -> UIColor {
        switch kind {
        case .needsWork: return needsWork
        case .expand: return expand
        case .cut: return cut
        case .keep: return keep
        case .comment: return comment
        }
    }

    /// The comment mark is a wash rather than an underline: its text is in a
    /// note, so the mark says "there is more to read here".
    public static let commentWashAlpha: CGFloat = 0.18
    /// The band under the sentence being read.
    public static let bandAlpha: CGFloat = 0.10
    /// The part of that sentence already read.
    public static let trailAlpha: CGFloat = 0.20

    /// The reading band follows the user's reading accent, unlike the marks.
    public static var readingAccent: UIColor { GlassStyle.readingAccent }

    public static func title(for kind: Annotation.Kind) -> String {
        switch kind {
        case .needsWork: return L10n.string("WriterReadAlong_kindNeedsWork")
        case .expand: return L10n.string("WriterReadAlong_kindExpand")
        case .cut: return L10n.string("WriterReadAlong_kindCut")
        case .keep: return L10n.string("WriterReadAlong_kindKeep")
        case .comment: return L10n.string("WriterReadAlong_kindComment")
        }
    }
}

extension UIColor {
    /// A 0xRRGGBB literal. The annotation colours are specified as hexes, and
    /// spelling each as three divisions hides which colour it is.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
