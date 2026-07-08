import Foundation

public enum ContentPlatform: String, Codable, CaseIterable, Sendable {
    case x, bluesky, reddit, tiktok, instagram, facebook, music, podcast

    public var kind: PlatformKind {
        switch self {
        case .tiktok, .facebook: .video
        case .x, .bluesky, .reddit, .instagram: .social
        case .music, .podcast: .audio
        }
    }

    public var displayName: String {
        switch self {
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

    public var isURLless: Bool { self == .music || self == .podcast }

    public var logoAssetName: String? {
        switch self {
        case .x: return "logo-x"
        case .bluesky: return "logo-bluesky"
        case .reddit: return "logo-reddit"
        case .tiktok: return "logo-tiktok"
        case .instagram: return "logo-instagram"
        case .facebook: return "logo-facebook"
        case .music, .podcast: return nil // cover art primary; SF Symbol fallback
        }
    }

    public var glyphSymbolName: String {
        switch self {
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

public enum PlatformKind: Equatable, Sendable { case video, social, audio }

public enum MusicProvider: String, Codable, CaseIterable, Sendable {
    case apple, spotify

    public var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .spotify: return "Spotify"
        }
    }
}

public enum ContentKind: Equatable, Sendable {
    case article
    case paywalledArticle(hardHost: Bool)
    case product(ProductSignal)
    case social(ContentPlatform, itemID: String?)
    case video(ContentPlatform, itemID: String?)
    case audio(ContentPlatform, MusicProvider?, itemID: String?)
    case document(type: String)
    case undetermined
}

public enum ProductSignal: Equatable, Sendable {
    case knownShopHost, structuredData, heuristicScore(Int)
}
