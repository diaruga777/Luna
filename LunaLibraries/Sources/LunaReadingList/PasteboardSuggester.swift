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
public enum PasteboardSuggester {

    /// Best-effort preview art for a recognized platform URL, installed by the
    /// media-handling apps' `KindWiring` (it needs `PlatformRegistry`'s metadata
    /// fetchers, which LunaReadingList must not depend on). nil ⇒ no art.
    public static var platformPreviewArt:
        ((_ platform: ContentPlatform, _ itemID: String?, _ urlString: String) async -> UIImage?)?
}
