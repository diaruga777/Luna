//
//  RescueHint.swift
//  LunaModels
//

import Foundation

/// What a failed save should be rescued INTO. Lives in LunaModels (the lowest
/// tier) so the engine, the coordinator, the extension handoff store, and the
/// price/media UI can all name it without pulling in the rescue engine module
/// (which extensions must never link).
public enum RescueHint: String, Codable, CaseIterable {
    case article
    case product
    case media

    /// The user-facing label for the hint picker.
    public var displayName: String {
        switch self {
        case .article: return "Article"
        case .product: return "Price Tracker"
        case .media: return "Media Download"
        }
    }
}
