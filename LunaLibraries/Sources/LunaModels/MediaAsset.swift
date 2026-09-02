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
public struct MediaAsset: Codable, Equatable {
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
    /// Headers the download request must carry, from a plugin's `MediaAssetSpec`
    /// (`PluginModelCaps.allowedHeaderNames` is the allowlist). Empty for every
    /// Swift-resolved asset. `LiveMediaDownloadManager` applies these to the
    /// task and persists them with the job, so a background resume after process
    /// death still sends what the CDN demands.
    public var requestHeaders: [String: String]
    /// The quality label a plugin gave this leg ("1080p", "audio-128k"). It is
    /// what matches a re-resolved asset back to the job that was downloading it
    /// (`MediaReresolving`). Nil for every Swift-resolved asset.
    public let quality: String?
    /// The plugin that resolved this asset, and when its URLs go stale. The
    /// download engine persists both with the job, so a background resume hours
    /// later knows whom to ask for a fresh URL. Nil for a Swift-resolved asset.
    public let pluginID: String?
    public let expiresAt: Date?

    public init(
        url: URL,
        kind: Kind,
        audioURL: URL? = nil,
        dashManifestURL: URL? = nil,
        thumbnailURL: URL? = nil,
        estimatedByteCount: Int64? = nil,
        timeRange: MediaTimeRange? = nil,
        requestHeaders: [String: String] = [:],
        quality: String? = nil,
        pluginID: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.url = url
        self.kind = kind
        self.audioURL = audioURL
        self.dashManifestURL = dashManifestURL
        self.thumbnailURL = thumbnailURL
        self.estimatedByteCount = estimatedByteCount
        self.timeRange = timeRange
        self.requestHeaders = requestHeaders
        self.quality = quality
        self.pluginID = pluginID
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case url, kind, audioURL, dashManifestURL, thumbnailURL
        case estimatedByteCount, timeRange, requestHeaders, quality, pluginID, expiresAt
    }

    /// Hand-written so an asset written before `requestHeaders` existed still
    /// decodes: the synthesized initializer would demand the key. Assets are
    /// persisted as JSON in the App Group (`ResolvedMediaStores`), so older
    /// files outlive this build.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        kind = try c.decode(Kind.self, forKey: .kind)
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        dashManifestURL = try c.decodeIfPresent(URL.self, forKey: .dashManifestURL)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        estimatedByteCount = try c.decodeIfPresent(Int64.self, forKey: .estimatedByteCount)
        timeRange = try c.decodeIfPresent(MediaTimeRange.self, forKey: .timeRange)
        requestHeaders = try c.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
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

/// Re-runs the plugin that owns a download when its asset URLs go stale.
///
/// A CDN URL a plugin returned is short-lived and often IP-bound, so a job that
/// resumes hours later gets a 403 instead of bytes. The durable engine calls
/// this, matches the answers back to the job by `(kind, quality)`, and restarts
/// the transfer with the new URL and headers
/// (`claudedocs/plans/plugin-platform.md` §7.6).
public protocol MediaReresolving {
    /// The post's assets as the plugin resolves them now, or nil when the plugin
    /// is gone, declined, or failed. `saveID` is the save that owns the
    /// download, resolved from the job's source URL — nil when that save has
    /// since been deleted, never the download engine's own job id.
    func reresolve(sourceURL: URL, pluginID: String, saveID: String?) async -> [MediaAsset]?
}

/// The media seams a plugin platform fills, held at the bottom of the stack.
///
/// LunaPluginIngest cannot import LunaMediaDownload — the media module knows
/// nothing about plugins and the package edge does not exist — so the plugin
/// side writes its witnesses here and the media side reads them at the moment it
/// needs one. `PluginPlatformComposition.install()` is the only writer.
public enum PluginMediaSeams {
    /// The plugin walk as an asset resolver. Central Luna hands this to URL
    /// Rescue in place of the Swift `SocialMediaResolver`.
    public static var resolver: (any SocialMediaResolving)?
    /// The §7.6 re-resolution witness, read by `LiveMediaDownloadManager`.
    public static var reresolver: (any MediaReresolving)?
}
