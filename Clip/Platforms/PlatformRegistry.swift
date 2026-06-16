//
//  PlatformRegistry.swift
//  Clip
//

import Foundation

/// Central list of platform modules. Classification (`detect`) replaces the
/// hardcoded YouTube `if` in the ingestor; `module(for:)` drives rendering.
final class PlatformRegistry {

    static let shared = PlatformRegistry()

    /// Ordered modules — first classify hit wins. (Order matters only if hosts
    /// overlap, which they don't here.)
    private let modules: [PlatformModule]

    init(modules: [PlatformModule]? = nil) {
        // Modules are added per platform as they're implemented.
        self.modules = modules ?? [
            YouTubePlatform(),
            BlueskyPlatform(),
            XPlatform(),
            TikTokPlatform(),
            RedditPlatform(),
            InstagramPlatform(),
            FacebookPlatform(),
        ]
    }

    /// Classifies a URL, or nil if no platform recognizes it.
    func detect(_ urlString: String) -> PlatformMatch? {
        for module in modules {
            if let match = module.classify(urlString) { return match }
        }
        return nil
    }

    /// The module for a platform (for rendering/opening).
    func module(for platform: ContentPlatform) -> PlatformModule? {
        modules.first { $0.platform == platform }
    }
}
