//
//  MediaAsset.swift
//  LunaModels
//
//  Moved from LunaMediaDownload so kind-neutral tiers (LunaURLRescue's
//  `.rescuedMedia` payload, the app shells' media seams) can speak in resolved
//  media assets without linking the download machinery. The download-specific
//  conveniences (`MediaAsset.direct(url:)`, `Kind.canSaveToPhotos`) stay in
//  LunaMediaDownload with the resolvers that use them.
//

import Foundation

/// A single downloadable media item resolved from a social post.
public struct MediaAsset: Equatable {
    /// What the file is, which decides how it's saved to Photos and its extension.
    public enum Kind: String, Codable, Equatable {
        case image   // still photo (jpg/png)
        case gif     // animated GIF
        case video   // mp4 (Twitter "GIFs" are mp4s and resolve as .video)
        case audio   // directly hosted audio (mp3/m4a/etc.)
    }
    public let url: URL
    public let kind: Kind
    /// A separate audio-only stream to mux with `url`, for platforms (Reddit)
    /// that host video and audio as two independent files rather than one
    /// playable URL. `nil` for every other platform's single-URL assets.
    public let audioURL: URL?
    /// The DASH manifest listing `audioURL`'s real location — `audioURL` itself
    /// is a filename-convention guess (Reddit doesn't hand back the audio URL
    /// directly), so this is the authoritative fallback `RedditAudioFetcher`
    /// consults if that guess (and a second, legacy-convention guess) both
    /// fail to actually download. `nil` for every non-Reddit asset.
    public let dashManifestURL: URL?
    /// A small static poster that can be displayed while the full media is still
    /// transferring. Unlike `url`, this is never treated as the downloaded result.
    public let thumbnailURL: URL?
    /// Best size advertised by the resolver. The preflight layer verifies with a
    /// HEAD request when this is absent.
    public let estimatedByteCount: Int64?
    /// Optional source-requested clip range. The remote asset is downloaded first,
    /// then trimmed locally before it becomes durable media.
    public let timeRange: MediaTimeRange?

    public init(
        url: URL,
        kind: Kind,
        audioURL: URL? = nil,
        dashManifestURL: URL? = nil,
        thumbnailURL: URL? = nil,
        estimatedByteCount: Int64? = nil,
        timeRange: MediaTimeRange? = nil
    ) {
        self.url = url
        self.kind = kind
        self.audioURL = audioURL
        self.dashManifestURL = dashManifestURL
        self.thumbnailURL = thumbnailURL
        self.estimatedByteCount = estimatedByteCount
        self.timeRange = timeRange
    }
}

/// A half-open media interval. A nil end means "from start to the source end".
public struct MediaTimeRange: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double?

    public init(startSeconds: Double, endSeconds: Double?) {
        self.startSeconds = max(0, startSeconds)
        if let endSeconds, endSeconds > self.startSeconds {
            self.endSeconds = endSeconds
        } else {
            self.endSeconds = nil
        }
    }

    public var isEffective: Bool { startSeconds > 0 || endSeconds != nil }
}

/// Resolves the direct, downloadable media asset(s) for a social post URL.
/// Lives with the neutral `MediaAsset` payload so kind-neutral modules (URL
/// Rescue) can hold a resolver without depending on the media-download
/// machinery; `LunaMediaDownload.SocialMediaResolver` is the implementation,
/// injected by media-handling apps' composition roots.
public protocol SocialMediaResolving {
    /// Returns the post's media assets in display order, or an empty array when the
    /// URL is unsupported or no media could be resolved.
    func resolveAssets(for url: URL) async -> [MediaAsset]
}
