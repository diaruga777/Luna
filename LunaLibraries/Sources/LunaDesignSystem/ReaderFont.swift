//
//  ReaderFont.swift
//  Luna
//

import UIKit
import CoreText
import LunaModels

/// Preset reader typefaces. System and New York are provided by iOS; the
/// remaining families ship at the containing app's bundle root under the SIL
/// Open Font License. User-selectable in Settings.
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

    /// The bundle carrying the typeface files: the CONTAINING APP's bundle.
    ///
    /// One copy of the five faces ships at the app bundle root, so the app and
    /// every extension of it register the same files. An extension's own
    /// `Bundle.main` is its `.appex`, which sits two levels down at
    /// `<app>.app/PlugIns/<name>.appex`.
    private static var typefaceBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return .main }
        let app = url.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)
    }

    private static let registerBundledFonts: Void = {
        guard let bundle = typefaceBundle else { return }
        let names = ["Lexend", "Literata", "Literata-Italic", "NotoSans", "NotoSans-Italic"]
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
