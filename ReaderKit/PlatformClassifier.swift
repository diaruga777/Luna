//
//  PlatformClassifier.swift
//  Clip
//

import Foundation

/// The result of classifying a URL by platform. Lives in ReaderKit so the main
/// app AND the extensions classify identically from one source of truth.
struct PlatformClassification: Equatable {
    let platform: ContentPlatform
    let itemID: String?
    let sourceService: MusicProvider?
}

/// Recognizes a URL's content platform from its host (with common variants) and
/// extracts the item id. The single classification authority for every entry
/// point: ingest, pasteboard, share/action extensions, typing, friend shares.
enum PlatformClassifier {

    static func classify(_ urlString: String) -> PlatformClassification? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return nil }
        let segments = Array(url.pathComponents.dropFirst())

        // YouTube (broad host coverage already in YouTubeURL: youtube.com/www/m/
        // music/nocookie + youtu.be).
        if let videoID = YouTubeURL.videoID(from: urlString) {
            return PlatformClassification(platform: .youtube, itemID: videoID, sourceService: nil)
        }

        // Bluesky: bsky.app/profile/<author>/post/<rkey>
        if matches(host, "bsky.app"),
           let authorIndex = segments.firstIndex(of: "profile"),
           segments.count > authorIndex + 3, segments[authorIndex + 2] == "post" {
            return PlatformClassification(platform: .bluesky, itemID: segments[authorIndex + 3], sourceService: nil)
        }

        // X / Twitter: (x|twitter).com/<user>/status/<id>
        if matches(host, "x.com", "twitter.com") {
            if let statusIndex = segments.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
               statusIndex + 1 < segments.count {
                let id = segments[statusIndex + 1]
                return PlatformClassification(
                    platform: .x, itemID: id.allSatisfy(\.isNumber) ? id : nil, sourceService: nil)
            }
            return PlatformClassification(platform: .x, itemID: nil, sourceService: nil)
        }

        // TikTok: tiktok.com (+ vm./vt./m./www) /@user/video/<id> or short codes.
        if matches(host, "tiktok.com") {
            let id = segments.firstIndex(of: "video").flatMap {
                $0 + 1 < segments.count ? segments[$0 + 1] : nil
            }
            return PlatformClassification(platform: .tiktok,
                                          itemID: (id?.allSatisfy(\.isNumber) ?? false) ? id : nil,
                                          sourceService: nil)
        }

        // Reddit: reddit.com (+ subdomains) /r/<sub>/comments/<id>/… or redd.it
        if matches(host, "reddit.com") || host == "redd.it" {
            let id = segments.firstIndex(of: "comments").flatMap {
                $0 + 1 < segments.count ? segments[$0 + 1] : nil
            } ?? (host == "redd.it" ? segments.first : nil)
            return PlatformClassification(platform: .reddit, itemID: id, sourceService: nil)
        }

        // Instagram: instagram.com (+ instagr.am) /(p|reel|reels|tv)/<shortcode>
        if matches(host, "instagram.com") || host == "instagr.am" {
            let mediaKinds: Set<String> = ["p", "reel", "reels", "tv"]
            let id = segments.firstIndex(where: { mediaKinds.contains($0) }).flatMap {
                $0 + 1 < segments.count ? segments[$0 + 1] : nil
            }
            return PlatformClassification(platform: .instagram, itemID: id, sourceService: nil)
        }

        // Facebook: facebook.com (+ subdomains), fb.watch, fb.com
        if matches(host, "facebook.com") || host == "fb.watch" || host == "fb.com" {
            let queryV = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
            let pathID = ["reel", "videos"].lazy.compactMap { key -> String? in
                segments.firstIndex(of: key).flatMap { $0 + 1 < segments.count ? segments[$0 + 1] : nil }
            }.first
            return PlatformClassification(platform: .facebook, itemID: queryV ?? pathID, sourceService: nil)
        }

        // Spotify: open.spotify.com (+ play.spotify.com) /{track|album|artist|episode|show}/<id>
        if matches(host, "spotify.com"), let kind = segments.first {
            let id = segments.count > 1 ? segments[1] : nil
            switch kind {
            case "track", "album", "artist":
                return PlatformClassification(platform: .music, itemID: id, sourceService: .spotify)
            case "episode", "show":
                return PlatformClassification(platform: .podcast, itemID: id, sourceService: .spotify)
            default: break
            }
        }

        // Apple Music / Podcasts.
        let appleQueryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "i" })?.value
        if matches(host, "music.apple.com") {
            return PlatformClassification(platform: .music, itemID: appleQueryID ?? segments.last, sourceService: .apple)
        }
        if matches(host, "podcasts.apple.com") {
            return PlatformClassification(platform: .podcast, itemID: appleQueryID ?? segments.last, sourceService: .apple)
        }

        return nil
    }

    /// True if `host` equals any base domain or is a subdomain of it.
    private static func matches(_ host: String, _ domains: String...) -> Bool {
        domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
