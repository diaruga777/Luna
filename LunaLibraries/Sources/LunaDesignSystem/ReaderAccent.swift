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
        case .blue: return L10n.string("Settings_readerAccent_blue")
        case .red: return L10n.string("Settings_readerAccent_red")
        case .green: return L10n.string("Settings_readerAccent_green")
        case .purple: return L10n.string("Settings_readerAccent_purple")
        case .yellow: return L10n.string("Settings_readerAccent_yellow")
        case .orange: return L10n.string("Settings_readerAccent_orange")
        case .teal: return L10n.string("Settings_readerAccent_teal")
        case .pink: return L10n.string("Settings_readerAccent_pink")
        case .indigo: return L10n.string("Settings_readerAccent_indigo")
        }
    }
}
