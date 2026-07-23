//
//  PlatformRecognizer.swift
//  ReaderKit
//

import LunaModels
import Foundation

/// A URL recognized as belonging to a content platform, with the extracted item
/// id (nil for short links / opaque pages that still classify as the platform)
/// and its extractable item id.
public struct RecognizedPlatform: Equatable {
    public let platform: ContentPlatform
    public let itemID: String?

    /// The broad category (video / social) the recognized platform is in.
    public var kind: PlatformKind { platform.kind }
}

/// The already-parsed pieces of a URL handed to a `PlatformRule`'s recognizer, so
/// each rule reads exactly what it needs (path segments, query, the host, or the
/// whole URL) without re-parsing. Pure value type.
public struct PlatformURLParts {
    /// The lowercased host that matched the rule.
    public let host: String
    /// Path components with the leading "/" element dropped (e.g. `["watch"]`).
    public let segments: [String]
    /// The URL's query items (empty when there are none).
    public let query: [URLQueryItem]
    /// The full URL, for rules whose id helper works on the whole URL.
    public let url: URL
}

/// One declarative URL → platform rule. Recognition only — no fetching, no
/// rendering. Adding a platform means appending one `PlatformRule` to
/// `PlatformRecognizer.rules`; the recognizer needs no control-flow edits.
public struct PlatformRule {
    /// The platform a matching URL belongs to.
    public let platform: ContentPlatform
    /// Hosts matched exactly OR as a subdomain (e.g. `tiktok.com` matches
    /// `vm.tiktok.com`). Lowercased.
    public let hosts: [String]
    /// Whether this rule recognizes a URL on a matching host. A rule may decline a
    /// host it shares with another platform, in which case the recognizer keeps
    /// scanning later rules. Default: host match is enough.
    public let recognizes: (PlatformURLParts) -> Bool
    /// Extracts the item id from the parsed parts. A nil result is allowed — a
    /// short link or opaque page still classifies as the platform.
    public let itemID: (PlatformURLParts) -> String?

    public init(
        platform: ContentPlatform,
        hosts: [String],
        recognizes: @escaping (PlatformURLParts) -> Bool = { _ in true },
        itemID: @escaping (PlatformURLParts) -> String?
    ) {
        self.platform = platform
        self.hosts = hosts
        self.recognizes = recognizes
        self.itemID = itemID
    }
}

/// The single deterministic platform recognizer, used identically on every
/// surface (ingest, paste, share/action extensions, intents, friend receive).
/// Pure: no network, no UIKit — compiles in extensions. This is the ONE place
/// URL → platform rules live; every caller (`PlatformRegistry.detect`,
/// `BypassGate`, the media-download path, `PasteboardSuggester`) recognizes
/// through this single table.
public enum PlatformRecognizer {

    /// EXTEND HERE: add a platform by appending one rule. Order matters only when
    /// host lists overlap; the first rule that both matches a host AND `recognizes`
    /// the URL wins.
    public static let rules: [PlatformRule] = [
        x,
        bluesky,
        reddit,
        tiktok,
        instagram,
        facebook,
        youtube,
    ]

    /// Recognizes `urlString` as a platform URL, or nil for an ordinary
    /// article/document/junk URL. The first rule that matches a host and accepts
    /// the URL wins.
    public static func recognize(_ urlString: String) -> RecognizedPlatform? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let parts = PlatformURLParts(
            host: host,
            segments: Array(url.pathComponents.dropFirst()),
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [],
            url: url)
        for rule in rules
        where HostMatching.hostSuffixMatches(host, anyOf: rule.hosts) && rule.recognizes(parts) {
            return RecognizedPlatform(platform: rule.platform, itemID: rule.itemID(parts))
        }
        return nil
    }

    // MARK: - The rules
    //
    // Each rule owns the host/path logic for its platform; the recognizer is the
    // single authority every surface classifies through.

    /// X / Twitter — `/<user>/status/<id>` (numeric id only); the platform is
    /// recognized even without a status (id nil), matching the live ladder.
    public static let x = PlatformRule(
        platform: .x, hosts: ["x.com", "twitter.com"],
        itemID: { parts in
            guard let statusIndex = parts.segments.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
                  statusIndex + 1 < parts.segments.count else { return nil }
            let id = parts.segments[statusIndex + 1]
            return id.allSatisfy(\.isNumber) ? id : nil
        })

    /// Bluesky — `bsky.app/profile/<author>/post/<rkey>`. Unlike the other social
    /// platforms, a bare Bluesky profile (no `/post/`) does NOT classify (matching
    /// other social platforms): only a post is a recognized item.
    public static let bluesky = PlatformRule(
        platform: .bluesky, hosts: ["bsky.app"],
        recognizes: { blueskyPostID($0.segments) != nil },
        itemID: { blueskyPostID($0.segments) })

    /// The Bluesky post rkey from `/profile/<author>/post/<rkey>`, or nil.
    private static func blueskyPostID(_ segments: [String]) -> String? {
        guard let authorIndex = segments.firstIndex(of: "profile"),
              segments.count > authorIndex + 3, segments[authorIndex + 2] == "post" else { return nil }
        return segments[authorIndex + 3]
    }

    /// Reddit — an individual post permalink: `/comments/<id>`,
    /// `/r|user|u/<name>/comments/<id>`, `/gallery/<id>`, `redd.it/<id>`, or the
    /// app-native share link `/r/<name>/s/<token>`. Unlike a host-only match, a bare
    /// subreddit or home feed does NOT classify (mirroring bluesky's post-only shape
    /// and the Safari content-script gate): only a post is a recognized item.
    public static let reddit = PlatformRule(
        platform: .reddit, hosts: ["reddit.com", "redd.it"],
        recognizes: { redditPostID($0) != nil || redditShareToken($0) != nil },
        itemID: { redditPostID($0) })

    /// The base-36 post id for a Reddit POST permalink, or nil. Structural matching
    /// (NOT `firstIndex(of: "comments")`): a subreddit literally named "comments"
    /// (`/r/comments/top/`) is a feed, and `/user/<name>/comments/` with no id is a
    /// comment-history listing — neither is a post.
    private static func redditPostID(_ parts: PlatformURLParts) -> String? {
        let segments = parts.segments
        func nonEmpty(_ i: Int) -> String? {
            guard i < segments.count, !segments[i].isEmpty else { return nil }
            return segments[i]
        }
        if parts.host == "redd.it" { return nonEmpty(0) }
        guard let first = segments.first else { return nil }
        if first == "comments" { return nonEmpty(1) }
        if first == "r" || first == "user" || first == "u", segments.count > 2, segments[2] == "comments" {
            return nonEmpty(3)
        }
        if first == "gallery" { return nonEmpty(1) }
        return nil
    }

    /// The opaque share token from Reddit's own app-native share link,
    /// `/r/<name>/s/<token>` — an increasingly common share format that carries no
    /// decodable post id. Reddit only resolves it via a live HTTP redirect to the
    /// canonical permalink, so (mirroring TikTok's short vm./vt. links) this is
    /// recognized as a Reddit post but `itemID` stays nil; callers that need the
    /// real post follow the redirect themselves.
    private static func redditShareToken(_ parts: PlatformURLParts) -> String? {
        let segments = parts.segments
        guard segments.first == "r", segments.count > 3, !segments[1].isEmpty, segments[2] == "s",
              !segments[3].isEmpty
        else { return nil }
        return segments[3]
    }

    /// TikTok — `/@user/video/<numeric id>` (short `vm.`/`vt.` links recognized,
    /// id nil).
    public static let tiktok = PlatformRule(
        platform: .tiktok, hosts: ["tiktok.com"],
        itemID: { parts in
            guard let videoIndex = parts.segments.firstIndex(of: "video"),
                  videoIndex + 1 < parts.segments.count else { return nil }
            let id = parts.segments[videoIndex + 1]
            return id.allSatisfy(\.isNumber) ? id : nil
        })

    /// Instagram — `instagram.com` (+ `instagr.am`) `/(p|reel|reels|tv)/<shortcode>`.
    public static let instagram = PlatformRule(
        platform: .instagram, hosts: ["instagram.com", "instagr.am"],
        itemID: { parts in
            let mediaKinds: Set<String> = ["p", "reel", "reels", "tv"]
            guard let mediaIndex = parts.segments.firstIndex(where: { mediaKinds.contains($0) }),
                  mediaIndex + 1 < parts.segments.count else { return nil }
            return parts.segments[mediaIndex + 1]
        })

    /// Facebook — `facebook.com` (+ subdomains), `fb.watch`, `fb.com`; id from `?v=`
    /// or a `/reel|/videos/<id>` path segment.
    public static let facebook = PlatformRule(
        platform: .facebook, hosts: ["facebook.com", "fb.watch", "fb.com"],
        itemID: { parts in
            if let queryV = parts.query.first(where: { $0.name == "v" })?.value { return queryV }
            for key in ["reel", "videos"] {
                if let index = parts.segments.firstIndex(of: key), index + 1 < parts.segments.count {
                    return parts.segments[index + 1]
                }
            }
            return nil
        })

    /// YouTube videos: long/mobile/no-cookie watch URLs, shorts/live/embed paths,
    /// youtu.be short links, and `/clip/<id>` range links. Clip URLs deliberately
    /// have no item id until their public page reveals the underlying video.
    public static let youtube = PlatformRule(
        platform: .youtube,
        hosts: ["youtube.com", "youtube-nocookie.com", "youtu.be"],
        recognizes: { youtubeVideoID($0) != nil || $0.segments.first == "clip" },
        itemID: { youtubeVideoID($0) })

    private static func youtubeVideoID(_ parts: PlatformURLParts) -> String? {
        func valid(_ value: String?) -> String? {
            guard let value, value.count == 11,
                  value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { return nil }
            return value
        }
        if parts.host == "youtu.be" { return valid(parts.segments.first) }
        if let queryID = parts.query.first(where: { $0.name == "v" })?.value,
           let validID = valid(queryID) {
            return validID
        }
        guard let first = parts.segments.first,
              ["shorts", "live", "embed", "v"].contains(first),
              parts.segments.count > 1
        else { return nil }
        return valid(parts.segments[1])
    }

}
