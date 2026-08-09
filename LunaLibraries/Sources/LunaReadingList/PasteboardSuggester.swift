//
//  PasteboardSuggester.swift
//  Luna
//

import LunaModels
import UIKit

/// Namespace holding the pasteboard preview art seam. The candidate-evaluation
/// flow this type used to carry (dedupe against the reading list, confirm
/// readable or recognized-platform content, resolve a preview thumbnail) was
/// dead — nothing called it — and was deleted; only the injection point below
/// is still live, kept under this name because its installers
/// (`KindWiring+Luna`, `KindWiring+Downloader`) and reader
/// (`Luna/UtilCard/RecentURLMatcher.swift`) all address it as
/// `PasteboardSuggester.platformPreviewArt`.
///
/// Deliberately a non-instantiable `final class`, not a case-less `enum`: an
/// enum namespace here reproducibly fails the app's link step with an
/// "unsafeMutableAddressor … not found" undefined symbol for exactly this
/// static var (a 3-parameter `async` closure wrapped in `Optional`) — verified
/// by swapping just this declaration between `enum`/`final class` with
/// everything else held constant. Every other case-less-enum seam in this
/// codebase has a simpler signature (1-2 params, no outer `Optional` on an
/// `async` closure) and links fine, so the failure looks like a toolchain
/// corner rather than something wrong with the seam itself — but `final
/// class` is the form proven to link, so it stays.
public final class PasteboardSuggester {
    private init() {}

    /// Best-effort preview art for a recognized platform URL, installed by the
    /// media-handling apps' `KindWiring` (it needs `PlatformRegistry`'s metadata
    /// fetchers, which LunaReadingList must not depend on). nil ⇒ no art.
    public static var platformPreviewArt:
        ((_ platform: ContentPlatform, _ itemID: String?, _ urlString: String) async -> UIImage?)?
}
