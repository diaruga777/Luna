//
//  ReaderAccent.swift
//  Luna
//

import UIKit
import LunaModels

/// Preset highlight/focus colors for the readers (RSVP reticule + ORP letter,
/// scroll/chunk highlight). User-selectable in Settings; defaults to blue.
public enum ReaderAccent: String, CaseIterable {
    case blue, red, green, purple, yellow, orange, teal, pink, indigo

    public var color: UIColor {
        switch self {
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .teal: return .systemTeal
        case .pink: return .systemPink
        case .indigo: return .systemIndigo
        }
    }

    public var displayName: String {
        switch self {
        case .blue: return L10n.string("Blue")
        case .red: return L10n.string("Red")
        case .green: return L10n.string("Green")
        case .purple: return L10n.string("Purple")
        case .yellow: return L10n.string("Yellow")
        case .orange: return L10n.string("Orange")
        case .teal: return L10n.string("Teal")
        case .pink: return L10n.string("Pink")
        case .indigo: return L10n.string("Indigo")
        }
    }
}
