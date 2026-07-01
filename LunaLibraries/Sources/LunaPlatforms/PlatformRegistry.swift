//
//  PlatformRegistry.swift
//  Luna
//

import LunaURLClassification
import LunaModels
import Foundation

/// Central list of platform modules. Classification (`detect`) replaces the
/// hardcoded YouTube `if` in the ingestor; `module(for:)` drives rendering.
public final class PlatformRegistry {

    public static let shared = PlatformRegistry()

    /// Ordered modules — first classify hit wins. (Order matters only if hosts
    /// overlap, which they don't here.)
    private let modules: [PlatformModule]

    public init(modules: [PlatformModule]? = nil) {
        // Modules are added per platform as they're implemented.
        self.modules = modules ?? [
            YouTubePlatform(),
            BlueskyPlatform(),
            XPlatform(),
            TikTokPlatform(),
            RedditPlatform(),
            InstagramPlatform(),
            FacebookPlatform(),
            MusicPlatform(),
            PodcastPlatform(),
        ]
    }

    /// Classifies a URL via the single shared `PlatformRecognizer` (one source of
    /// truth, broad host coverage). Returns nil if no platform recognizes it.
    public func detect(_ urlString: String) -> PlatformMatch? {
        guard let recognized = PlatformRecognizer.recognize(urlString) else { return nil }
        return PlatformMatch(platform: recognized.platform, itemID: recognized.itemID,
                             sourceService: recognized.service)
    }

    /// The module for a platform (for rendering/opening).
    public func module(for platform: ContentPlatform) -> PlatformModule? {
        modules.first { $0.platform == platform }
    }
}
