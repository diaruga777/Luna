//
//  PasteboardSuggester.swift
//  Luna
//

import LunaModels
import UIKit

/// Namespace holding the pasteboard preview art seam. The candidate-evaluation
/// flow this type used to carry (dedupe against the saves list, confirm
/// readable or recognized-platform content, resolve a preview thumbnail) was
/// dead — nothing called it — and was deleted; only the injection point below
/// is still live, kept under this name because its installers
/// (`KindWiring+Luna`, `KindWiring+Downloader`) and reader
/// (`Luna/UtilCard/RecentURLMatcher.swift`) all address it as
/// `PasteboardSuggester.platformPreviewArt`.
///
/// Deliberately a non-instantiable `final class`, not a case-less `enum`: an
/// enum namespace here reproducibly failed the app's link step with an
/// "unsafeMutableAddressor … not found" undefined symbol for exactly this
/// static var back when it held a 3-parameter `async` closure wrapped in
/// `Optional` — verified by swapping just this declaration between
/// `enum`/`final class` with everything else held constant. The seam is a
/// protocol witness now, but `final class` is the form proven to link, so it
/// stays.
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
    /// fetchers, which LunaReadingList must not depend on). Left uninstalled ⇒
    /// no art.
    public static var platformPreviewArt: (any PlatformPreviewArtProviding)?
}
