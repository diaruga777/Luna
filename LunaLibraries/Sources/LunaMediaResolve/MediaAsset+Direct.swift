//
//  MediaAsset+Direct.swift
//  LunaMediaResolve
//
//  Lives in LunaMediaResolve, with the resolvers, because it is
//  `SocialMediaResolver.resolveAssets`'s first step. LunaMediaDownload
//  re-exports this module, so its call sites use it unchanged.
//

import Foundation
import LunaModels
import LunaURLClassification

public extension MediaAsset {
    /// Treats a directly hosted media URL as its own resolved asset.
    static func direct(url: URL) -> MediaAsset? {
        guard let directKind = DirectMediaURL.kind(for: url) else { return nil }
        let kind: Kind
        switch directKind {
        case .image: kind = .image
        case .gif: kind = .gif
        case .video: kind = .video
        case .audio: kind = .audio
        }
        return MediaAsset(url: url, kind: kind)
    }
}
