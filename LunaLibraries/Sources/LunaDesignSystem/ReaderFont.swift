//
//  ReaderFont.swift
//  Luna
//

import UIKit
import CoreText
import LunaModels

/// Preset reader typefaces. System and New York are provided by iOS; the
/// remaining families are bundled with LunaDesignSystem under the SIL Open
/// Font License. User-selectable in Settings.
public enum ReaderFont: String, CaseIterable {
    case lexend
    case literata
    case notoSans
    /// San Francisco, the system sans.
    case system
    /// New York, the system serif design.
    case newYork

    public var displayName: String {
        switch self {
        case .lexend: return L10n.string("Settings_readerFont_lexend")
        case .literata: return L10n.string("Settings_readerFont_literata")
        case .notoSans: return L10n.string("Settings_readerFont_notoSans")
        case .system: return L10n.string("Settings_readerFont_system")
        case .newYork: return L10n.string("Settings_readerFont_newYork")
        }
    }

    /// The iOS font family backing this choice; nil for the two system designs,
    /// which resolve through `UIFont.systemFont` instead of a family lookup.
    private var familyName: String? {
        switch self {
        case .lexend: return "Lexend"
        case .literata: return "Literata"
        case .notoSans: return "Noto Sans"
        case .system, .newYork: return nil
        }
    }

    public func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        resolved(size: size, weight: weight, italic: false)
    }

    public func italicFont(size: CGFloat) -> UIFont {
        resolved(size: size, weight: .regular, italic: true)
    }

    private func resolved(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont {
        Self.registerBundledFonts
        if let familyName, !UIFont.fontNames(forFamilyName: familyName).isEmpty {
            // Request the face through descriptor matching rather than
            // hard-coded PostScript names, so each family's own weight/italic
            // lineup is resolved by CoreText and never drifts out of sync with
            // the bundled variable font.
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
        // The system designs — also the fallback should a bundled family ever
        // be missing, in which case the nearest system look stands in.
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if self != .system, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        if italic, let italicDescriptor = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italicDescriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static let registerBundledFonts: Void = {
        let resources = [
            (name: "Lexend", ext: "ttf"),
            (name: "Literata", ext: "ttf"),
            (name: "Literata-Italic", ext: "ttf"),
            (name: "NotoSans", ext: "ttf"),
            (name: "NotoSans-Italic", ext: "ttf"),
        ]
        for resource in resources {
            guard let url = Bundle.module.url(
                forResource: resource.name,
                withExtension: resource.ext
            ) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
