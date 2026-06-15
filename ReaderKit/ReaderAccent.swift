//
//  ReaderAccent.swift
//  Clip
//

import UIKit

/// Preset highlight/focus colors for the readers (RSVP reticule + ORP letter,
/// scroll/chunk highlight). User-selectable in Settings; defaults to blue.
enum ReaderAccent: String, CaseIterable {
    case blue, red, green, purple, yellow, orange, teal, pink, indigo

    var color: UIColor {
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

    var displayName: String { rawValue.capitalized }
}
