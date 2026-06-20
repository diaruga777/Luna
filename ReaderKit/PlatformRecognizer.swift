//
//  PlatformRecognizer.swift
//  ReaderKit
//

import Foundation

/// A URL recognized as belonging to a content platform, with the extracted item
/// id (nil for short links / opaque pages that still classify as the platform)
/// and the streaming service for audio platforms.
struct RecognizedPlatform: Equatable {
    let platform: ContentPlatform
    let itemID: String?
    let service: MusicProvider?

    /// The broad category (video / social / audio) the recognized platform is in.
    var kind: PlatformKind { platform.kind }
}

/// The already-parsed pieces of a URL handed to a `PlatformRule`'s recognizer, so
/// each rule reads exactly what it needs (path segments, query, the host, or the
/// whole URL) without re-parsing. Pure value type.
struct PlatformURLParts {
    /// The lowercased host that matched the rule.
    let host: String
    /// Path components with the leading "/" element dropped (e.g. `["watch"]`).
    let segments: [String]
    /// The URL's query items (empty when there are none).
    let query: [URLQueryItem]
    /// The full URL, for rules whose id helper works on the whole URL (YouTube).
    let url: URL
}

/// One declarative URL → platform rule. Recognition only — no fetching, no
/// rendering. Adding a platform means appending one `PlatformRule` to
/// `PlatformRecognizer.rules`; the recognizer needs no control-flow edits.
struct PlatformRule {
    /// The platform a matching URL belongs to.
    let platform: ContentPlatform
    /// The streaming service, for `.music` / `.podcast` platforms only (else nil).
    let service: MusicProvider?
    /// Hosts matched exactly OR as a subdomain (e.g. `tiktok.com` matches
    /// `vm.tiktok.com`). Lowercased.
    let hosts: [String]
    /// Whether this rule recognizes a URL on a matching host. A rule may decline a
    /// host it shares with another platform (Spotify splits music vs podcast by
    /// path), in which case the recognizer keeps scanning later rules. Default:
    /// host match is enough.
    let recognizes: (PlatformURLParts) -> Bool
    /// Extracts the item id from the parsed parts. A nil result is allowed — a
    /// short link or opaque page still classifies as the platform.
    let itemID: (PlatformURLParts) -> String?

    init(
        platform: ContentPlatform,
        service: MusicProvider?,
        hosts: [String],
        recognizes: @escaping (PlatformURLParts) -> Bool = { _ in true },
        itemID: @escaping (PlatformURLParts) -> String?
    ) {
        self.platform = platform
        self.service = service
        self.hosts = hosts
        self.recognizes = recognizes
        self.itemID = itemID
    }
}

/// The single deterministic platform recognizer, used identically on every
/// surface (ingest, paste, share/action extensions, intents, friend receive).
/// Pure: no network, no UIKit — compiles in extensions. This is the ONE place
/// URL → platform rules live; the per-module `classify` bodies and the inline
/// ladder in `PlatformClassifier` are shims/legacy over this table (removed in a
/// later stage).
enum PlatformRecognizer {

    /// EXTEND HERE: add a platform by appending one rule. Order matters only when
    /// host lists overlap; the first rule that both matches a host AND `recognizes`
    /// the URL wins. Spotify's two rows (music, podcast) share a host and split by
    /// path, so the music row must precede the podcast row.
    static let rules: [PlatformRule] = [
        youTube,
        x,
        bluesky,
        reddit,
        tiktok,
        instagram,
        facebook,
        spotifyMusic,
        spotifyPodcast,
        appleMusic,
        applePodcasts,
    ]

    /// Recognizes `urlString` as a platform URL, or nil for an ordinary
    /// article/document/junk URL. The first rule that matches a host and accepts
    /// the URL wins.
    static func recognize(_ urlString: String) -> RecognizedPlatform? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let parts = PlatformURLParts(
            host: host,
            segments: Array(url.pathComponents.dropFirst()),
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [],
            url: url)
        for rule in rules
        where rule.hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) && rule.recognizes(parts) {
            return RecognizedPlatform(platform: rule.platform, itemID: rule.itemID(parts), service: rule.service)
        }
        return nil
    }

    // MARK: - The rules
    //
    // Each rule reuses the SAME host/path logic the live `PlatformClassifier`
    // ladder applies, so the recognizer and the classifier agree exactly.

    /// YouTube — delegates id extraction to the one extracted recognizer
    /// (`YouTubeURL`), which owns the broad host coverage and the 11-char id
    /// validation. A YouTube host with no extractable video id (e.g. a channel
    /// page) is NOT a video, so the rule declines it.
    static let youTube = PlatformRule(
        platform: .youtube, service: nil,
        hosts: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
        recognizes: { YouTubeURL.videoID(from: $0.url.absoluteString) != nil },
        itemID: { YouTubeURL.videoID(from: $0.url.absoluteString) })

    /// X / Twitter — `/<user>/status/<id>` (numeric id only); the platform is
    /// recognized even without a status (id nil), matching the live ladder.
    static let x = PlatformRule(
        platform: .x, service: nil, hosts: ["x.com", "twitter.com"],
        itemID: { parts in
            guard let statusIndex = parts.segments.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
                  statusIndex + 1 < parts.segments.count else { return nil }
            let id = parts.segments[statusIndex + 1]
            return id.allSatisfy(\.isNumber) ? id : nil
        })

    /// Bluesky — `bsky.app/profile/<author>/post/<rkey>`.
    static let bluesky = PlatformRule(
        platform: .bluesky, service: nil, hosts: ["bsky.app"],
        itemID: { parts in
            guard let authorIndex = parts.segments.firstIndex(of: "profile"),
                  parts.segments.count > authorIndex + 3, parts.segments[authorIndex + 2] == "post"
            else { return nil }
            return parts.segments[authorIndex + 3]
        })

    /// Reddit — `reddit.com/r/<sub>/comments/<id>/…`, or `redd.it/<id>`.
    static let reddit = PlatformRule(
        platform: .reddit, service: nil, hosts: ["reddit.com", "redd.it"],
        itemID: { parts in
            if let commentsIndex = parts.segments.firstIndex(of: "comments"),
               commentsIndex + 1 < parts.segments.count {
                return parts.segments[commentsIndex + 1]
            }
            return parts.host == "redd.it" ? parts.segments.first : nil
        })

    /// TikTok — `/@user/video/<numeric id>` (short `vm.`/`vt.` links recognized,
    /// id nil).
    static let tiktok = PlatformRule(
        platform: .tiktok, service: nil, hosts: ["tiktok.com"],
        itemID: { parts in
            guard let videoIndex = parts.segments.firstIndex(of: "video"),
                  videoIndex + 1 < parts.segments.count else { return nil }
            let id = parts.segments[videoIndex + 1]
            return id.allSatisfy(\.isNumber) ? id : nil
        })

    /// Instagram — `instagram.com` (+ `instagr.am`) `/(p|reel|reels|tv)/<shortcode>`.
    static let instagram = PlatformRule(
        platform: .instagram, service: nil, hosts: ["instagram.com", "instagr.am"],
        itemID: { parts in
            let mediaKinds: Set<String> = ["p", "reel", "reels", "tv"]
            guard let mediaIndex = parts.segments.firstIndex(where: { mediaKinds.contains($0) }),
                  mediaIndex + 1 < parts.segments.count else { return nil }
            return parts.segments[mediaIndex + 1]
        })

    /// Facebook — `facebook.com` (+ subdomains), `fb.watch`, `fb.com`; id from `?v=`
    /// or a `/reel|/videos/<id>` path segment.
    static let facebook = PlatformRule(
        platform: .facebook, service: nil, hosts: ["facebook.com", "fb.watch", "fb.com"],
        itemID: { parts in
            if let queryV = parts.query.first(where: { $0.name == "v" })?.value { return queryV }
            for key in ["reel", "videos"] {
                if let index = parts.segments.firstIndex(of: key), index + 1 < parts.segments.count {
                    return parts.segments[index + 1]
                }
            }
            return nil
        })

    /// Spotify music — `open.spotify.com/{track|album|artist}/<id>`. Declines
    /// episode/show paths so the podcast rule can claim them.
    static let spotifyMusic = PlatformRule(
        platform: .music, service: .spotify, hosts: ["spotify.com"],
        recognizes: { spotifyKind($0.segments) == .music },
        itemID: { $0.segments.count > 1 ? $0.segments[1] : nil })

    /// Spotify podcast — `open.spotify.com/{episode|show}/<id>`.
    static let spotifyPodcast = PlatformRule(
        platform: .podcast, service: .spotify, hosts: ["spotify.com"],
        recognizes: { spotifyKind($0.segments) == .audioPodcast },
        itemID: { $0.segments.count > 1 ? $0.segments[1] : nil })

    /// Apple Music — `music.apple.com`; id from `?i=` or the last path segment.
    static let appleMusic = PlatformRule(
        platform: .music, service: .apple, hosts: ["music.apple.com"],
        itemID: { $0.query.first(where: { $0.name == "i" })?.value ?? $0.segments.last })

    /// Apple Podcasts — `podcasts.apple.com`; id from `?i=` or the last path segment.
    static let applePodcasts = PlatformRule(
        platform: .podcast, service: .apple, hosts: ["podcasts.apple.com"],
        itemID: { $0.query.first(where: { $0.name == "i" })?.value ?? $0.segments.last })

    /// The Spotify content kind named by the leading path segment, mirroring the
    /// live `PlatformClassifier` split (track/album/artist → music; episode/show →
    /// podcast; anything else → nil so no Spotify rule claims the URL).
    private enum SpotifyKind { case music, audioPodcast }
    private static func spotifyKind(_ segments: [String]) -> SpotifyKind? {
        switch segments.first {
        case "track", "album", "artist": return .music
        case "episode", "show": return .audioPodcast
        default: return nil
        }
    }
}
