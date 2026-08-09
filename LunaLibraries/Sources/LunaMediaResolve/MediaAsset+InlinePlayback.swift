//
//  MediaAsset+InlinePlayback.swift
//  LunaMediaResolve
//
//  Whether a resolved asset can be handed straight to an HTML5 `<video>` — the
//  question the Safari extension's in-page player asks, kept here with the
//  resolvers that produce the assets rather than in the extension that consumes
//  them (`claudedocs/safari-extension.md`).
//

import Foundation
import LunaModels

public extension MediaAsset {
    /// True when ONE `<video src>` plays this asset as the user expects.
    ///
    /// Two things disqualify an asset, and neither is a platform name:
    ///  • a separate audio stream (`audioURL` / `dashManifestURL`) — Reddit hosts
    ///    video and audio as independent files, and a browser handed only the
    ///    video URL plays it silently. Muxing is the download pipeline's job
    ///    (`MediaMuxer`), so an asset that needs it is download-only.
    ///  • a still image — there is a video player to fill, and a poster frame is
    ///    not what the user tapped for.
    var isDirectlyPlayable: Bool {
        guard audioURL == nil, dashManifestURL == nil else { return false }
        switch kind {
        case .video, .gif: return true
        case .image, .audio: return false
        }
    }
}
