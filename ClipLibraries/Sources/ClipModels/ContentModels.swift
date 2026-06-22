import Foundation

public enum ContentPlatform: String, Codable, CaseIterable, Sendable {
    case youtube, x, bluesky, reddit, tiktok, instagram, facebook, music, podcast

    public var kind: PlatformKind {
        switch self {
        case .youtube, .tiktok, .facebook: .video
        case .x, .bluesky, .reddit, .instagram: .social
        case .music, .podcast: .audio
        }
    }
}

public enum PlatformKind: Equatable, Sendable { case video, social, audio }

public enum MusicProvider: String, Codable, CaseIterable, Sendable { case apple, spotify }

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
