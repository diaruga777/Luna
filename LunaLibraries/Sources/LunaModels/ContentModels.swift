import Foundation

public enum ContentPlatform: String, Codable, CaseIterable, Sendable {
    case x, bluesky, reddit, tiktok, instagram, facebook, youtube, web

    public var kind: PlatformKind {
        switch self {
        case .tiktok, .facebook, .youtube, .web: .video
        case .x, .bluesky, .reddit, .instagram: .social
        }
    }

    public var displayName: String {
        switch self {
        case .x: return L10n.string("Platform_x")
        case .bluesky: return L10n.string("Platform_bluesky")
        case .reddit: return L10n.string("Platform_reddit")
        case .tiktok: return L10n.string("Platform_tikTok")
        case .instagram: return L10n.string("Platform_instagram")
        case .facebook: return L10n.string("Platform_facebook")
        case .youtube: return L10n.string("Platform_youTube")
        case .web: return L10n.string("Platform_web")
        }
    }

    public var logoAssetName: String? {
        switch self {
        case .x: return "logo-x"
        case .bluesky: return "logo-bluesky"
        case .reddit: return "logo-reddit"
        case .tiktok: return "logo-tiktok"
        case .instagram: return "logo-instagram"
        case .facebook: return "logo-facebook"
        case .youtube, .web: return nil
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
        case .youtube: return "play.rectangle.fill"
        case .web: return "arrow.down.circle.fill"
        }
    }
}

public enum PlatformKind: Equatable, Sendable { case video, social }

public enum ContentKind: Equatable, Sendable {
    case article
    case paywalledArticle(hardHost: Bool)
    case product(ProductSignal)
    case social(ContentPlatform, itemID: String?)
    case video(ContentPlatform, itemID: String?)
    case document(type: String)
    case undetermined
}

public enum ProductSignal: Equatable, Sendable {
    case knownShopHost, structuredData, heuristicScore(Int)
}
