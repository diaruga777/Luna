//
//  ReaderFont.swift
//  Luna
//

import UIKit

/// Preset reader typefaces. Every option ships with iOS — nothing is bundled
/// or downloaded — and the named families are openly licensed designs picked
/// for long-form readability: Charter (Bitstream's free license; the classic
/// reading-app serif) and STIX Two Text (SIL Open Font License, designed for
/// sustained text setting). User-selectable in Settings.
public enum ReaderFont: String, CaseIterable {
    /// San Francisco, the system sans.
    case system
    /// New York, the system serif design.
    case newYork
    case charter
    case stixTwo

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .newYork: return "New York"
        case .charter: return "Charter"
        case .stixTwo: return "STIX Two"
        }
    }

    /// The iOS font family backing this choice; nil for the two system designs,
    /// which resolve through `UIFont.systemFont` instead of a family lookup.
    private var familyName: String? {
        switch self {
        case .system, .newYork: return nil
        case .charter: return "Charter"
        case .stixTwo: return "STIX Two Text"
        }
    }

    public func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        resolved(size: size, weight: weight, italic: false)
    }

    public func italicFont(size: CGFloat) -> UIFont {
        resolved(size: size, weight: .regular, italic: true)
    }

    private func resolved(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont {
        if let familyName, !UIFont.fontNames(forFamilyName: familyName).isEmpty {
            // Request the face through descriptor matching rather than
            // hard-coded PostScript names, so each family's own weight/italic
            // lineup (Charter's Roman/Bold, STIX Two's optical weights) is
            // resolved by CoreText and never drifts out of sync with the OS.
            var symbolic: UIFontDescriptor.SymbolicTraits = []
            if italic { symbolic.insert(.traitItalic) }
            if weight.rawValue >= UIFont.Weight.semibold.rawValue { symbolic.insert(.traitBold) }
            var traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
            if !symbolic.isEmpty { traits[.symbolic] = symbolic.rawValue }
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: familyName,
                .traits: traits,
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        // The system designs — also the fallback should a named family ever be
        // missing, in which case the nearest system look (serif) stands in.
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if self != .system, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        if italic, let italicDescriptor = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italicDescriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}
