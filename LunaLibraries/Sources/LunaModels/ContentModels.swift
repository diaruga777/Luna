import Foundation

public enum ContentPlatform: String, Codable, CaseIterable, Sendable {
    case x, bluesky, reddit, tiktok, instagram, facebook

    public var kind: PlatformKind {
        switch self {
        case .tiktok, .facebook: .video
        case .x, .bluesky, .reddit, .instagram: .social
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
