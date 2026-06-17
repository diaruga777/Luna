//
//  ContentPlatform.swift
//  Clip
//

import Foundation

/// A recognized content platform a saved URL/item belongs to. `music`/`podcast`
/// are provider-agnostic kinds (Spotify vs Apple is captured separately in
/// `MusicProvider`). Lives in ReaderKit so `ReadingListItem` and the extensions
/// can refer to it.
enum ContentPlatform: String, Codable, CaseIterable {
    case youtube
    case x
    case bluesky
    case reddit
    case tiktok
    case instagram
    case facebook
    case music
    case podcast

    /// User-facing platform name.
    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .x: return "X"
        case .bluesky: return "Bluesky"
        case .reddit: return "Reddit"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        case .music: return "Music"
        case .podcast: return "Podcast"
        }
    }

    /// Whether items of this platform carry no shareable http URL (provider-
    /// agnostic media items keyed by a synthetic scheme).
    var isURLless: Bool { self == .music || self == .podcast }

    /// Asset name for a bundled brand logo, when one ships (else nil → SF Symbol).
    /// These are full-color favicon-derived PNGs, drawn untinted as the fallback.
    var logoAssetName: String? {
        switch self {
        case .youtube: return "logo-youtube"
        case .x: return "logo-x"
        case .bluesky: return "logo-bluesky"
        case .reddit: return "logo-reddit"
        case .tiktok: return "logo-tiktok"
        case .instagram: return "logo-instagram"
        case .facebook: return "logo-facebook"
        case .music, .podcast: return nil // cover art primary; SF Symbol fallback
        }
    }

    /// SF Symbol glyph fallback for the row / saved screen.
    var glyphSymbolName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .x: return "bird.fill"
        case .bluesky: return "bubble.left.and.bubble.right.fill"
        case .reddit: return "bubble.left.and.text.bubble.right.fill"
        case .tiktok: return "music.note"
        case .instagram: return "camera.fill"
        case .facebook: return "play.tv.fill"
        case .music: return "music.note"
        case .podcast: return "mic.fill"
        }
    }
}

/// Which streaming service a music/podcast item came from, or the user's
/// preferred service to open such items in.
enum MusicProvider: String, Codable, CaseIterable {
    case apple
    case spotify

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .spotify: return "Spotify"
        }
    }
}
