//
//  PasteboardSuggester.swift
//  Luna
//

import LunaModels
import UIKit

/// Namespace holding the pasteboard preview art seam. Its installers
/// (`KindWiring+Luna`, `KindWiring+Downloader`) and its reader
/// (`Luna/UtilCard/RecentURLMatcher.swift`) all address the injection point
/// below as `PasteboardSuggester.platformPreviewArt`.
///
/// This is a non-instantiable `final class`, not a case-less `enum`: an enum
/// namespace here reproducibly failed the app's link step with an
/// "unsafeMutableAddressor … not found" undefined symbol for this exact
/// static var, back when it held a 3-parameter `async` closure wrapped in
/// `Optional`. Swapping only this declaration between `enum` and `final
/// class`, with everything else held constant, confirmed the cause. The seam
/// is a protocol witness now, but `final class` is the form proven to link,
/// so it stays.
/// Preview art for a recognized social/video URL, drawn from the platform's own
/// metadata. Installed by the media apps' shell over `PlatformRegistry`.
@MainActor
public protocol PlatformPreviewArtProviding {
    /// The art, or nil when the platform has none to give.
    func previewArt(
        platform: ContentPlatform, itemID: String?, urlString: String
    ) async -> UIImage?
}

public final class PasteboardSuggester {
    private init() {}

    /// Best-effort preview art for a recognized platform URL, installed by the
    /// media-handling apps' shell (it needs `PlatformRegistry`'s metadata
    /// fetchers, which LunaSaves must not depend on). Left uninstalled ⇒
    /// no art.
    public static var platformPreviewArt: (any PlatformPreviewArtProviding)?
}
