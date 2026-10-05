//
//  MediaModelAdopter.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaURLClassification

/// Turns a plugin's `media` Model into the assets the durable download engine
/// already knows how to fetch (`claudedocs/plans/plugin-platform.md` §5.1).
///
/// It produces ordinary `MediaAsset`s, so the media card, the Live Activity, the
/// Wi-Fi gate and the auto-download policy see no difference between a
/// plugin-resolved post and a Swift-resolved one. The only additions a plugin
/// brings are the per-request headers, the quality label that matches a leg back
/// on re-resolution, and the expiry that triggers it.
public struct MediaModelAdopter: MediaModelAdopting {
    public init() {}

    public func adopt(
        _ model: MediaModel, url: URL, pluginID: String
    ) async -> PluginAdoptedOutcome {
        let assets = model.assets.map {
            Self.asset(from: $0, pluginID: pluginID, expiresAt: model.expiresAt)
        }
        guard !assets.isEmpty else { return .declined }
        return .media(
            assets: assets,
            platform: Self.platform(named: model.platform, url: url),
            itemID: model.itemID,
            title: model.title,
            thumbnailURL: model.thumbnailURL)
    }

    static func asset(
        from spec: MediaAssetSpec, pluginID: String, expiresAt: Date?
    ) -> MediaAsset {
        MediaAsset(
            url: spec.url,
            kind: kind(of: spec.type),
            audioURL: spec.audioURL,
            dashManifestURL: spec.dashManifestURL,
            thumbnailURL: spec.thumbnailURL,
            estimatedByteCount: spec.estimatedBytes,
            timeRange: spec.timeRange.map {
                MediaTimeRange(startSeconds: $0.start, endSeconds: $0.end)
            },
            requestHeaders: spec.headers,
            quality: spec.quality,
            pluginID: pluginID,
            expiresAt: expiresAt)
    }

    static func kind(of type: MediaAssetSpec.AssetType) -> MediaAsset.Kind {
        switch type {
        case .video: return .video
        case .image: return .image
        case .gif: return .gif
        case .audio: return .audio
        }
    }

    /// The `platform` string a plugin wrote, mapped onto the case the cards and
    /// the Live Activity draw. Missing or unknown names use neutral `.web`
    /// presentation without interpreting the URL.
    static func platform(named raw: String?, url: URL) -> ContentPlatform {
        if let raw {
            let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let exact = ContentPlatform(rawValue: name) { return exact }
            if name == "twitter" { return .x }
        }
        return .web
    }
}
