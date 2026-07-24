//
//  ListKindSupport.swift
//  Luna
//

import LunaModels
import LunaReadingListUI
import UIKit

/// Per-kind hooks for the shared list UI (`ReadingListViewController` and its
/// row menu), mirroring the `IngestKindProcessors` / `IngestorKindHandlers`
/// registries: the universal list code consults these seams, and each app's
/// `KindWiring` variant installs exactly the implementations whose kind modules
/// that target links (`ArticleListSupport` / `MediaListSupport` /
/// `ProductListSupport`, per-target compiled like the wiring itself). A nil
/// seam is a kind this app doesn't handle — its rows never surface here, so
/// the nil paths are effectively dead in single-kind apps.
enum ListKindSupport {
    static var article: ArticleListSupporting?
    static var media: MediaListSupporting?
    static var product: ProductListSupporting?
}

/// Article-kind list behavior: the native reader push, the archive CAPTCHA
/// unlock, and the ereader/eBook row actions (LunaReaderUI / LunaArchiveReader /
/// LunaSend stay behind this seam).
protocol ArticleListSupporting {
    /// Gates the row menu's "Send to Kindle" (only a configured destination is offered).
    var isKindleConfigured: Bool { get }
    /// Whether row subtitles append the estimated reading time / progress
    /// (the reader-settings toggles).
    var showsReadingTime: Bool { get }
    var showsReadingProgress: Bool { get }
    /// Pushes the native reader for a `.ready` readable item. A non-nil
    /// `transitionSourceView` requests the lunar-eclipse push transition
    /// (Reader's list-row tap treatment).
    func openArticle(
        _ item: ReadingListItem, content: ArticleContent,
        presenter: UIViewController, transitionSourceView: UIView?)
    /// Presents the interactive archive reader for a `.needsCaptcha` item and
    /// hands the now-`.ready` item back through `onReady`.
    func presentArchiveUnlock(
        item: ReadingListItem, articleURL: URL, presenter: UIViewController,
        onReady: @escaping (ReadingListItem, UIViewController) -> Void)
    /// Pushes a reader for a transient (not-yet-saved) pasteboard preview.
    func openTransientArticle(
        item: ReadingListItem, content: ArticleContent, on nav: UINavigationController?)
    func sendToKindle(_ item: ReadingListItem)
    func shareEbook(_ item: ReadingListItem, from presenter: UIViewController, sourceView: UIView)
    /// Kicks the pending ereader-send retry (pull-to-refresh).
    func retryPendingSends()
}

/// Media-kind list behavior: the platform open ladder, platform logo/subtitle
/// resolution, and the save-to-Photos download flows (LunaPlatforms /
/// LunaMediaDownload stay behind this seam).
protocol MediaListSupporting {
    func openPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController)
    /// The platform-logo thumbnail fallback for a row with no fetched art.
    func logoThumbnail(for platform: ContentPlatform) -> ReadingListItemCell.Thumbnail?
    /// The platform-specific leading label of the subtitle line (logical
    /// container), or nil for the platform display-name fallback.
    func subtitleLeadingLabel(for item: ReadingListItem) -> String?
    /// Gates the row menu's "Save to Photos" (downloadable, non-audio media).
    func canSaveMediaToPhotos(urlString: String) -> Bool
    /// Runs the save-to-Photos flow, reporting through the list's status pill.
    /// `isDownloaderSurface` selects the local saved-media path over the
    /// background live-download handoff.
    func saveMediaToPhotos(
        _ item: ReadingListItem, isDownloaderSurface: Bool, status: MediaDownloadStatusView)
}

/// Product-kind list behavior: the price-tracking editor pushes (LunaPriceUI
/// stays behind this seam).
protocol ProductListSupporting {
    func openTracker(itemID: UUID, on nav: UINavigationController?)
    /// An interactive save just became a tracker: present its editor
    /// (creation, or merge when a store URL was added to an existing tracker).
    func presentInteractiveSaveEditor(
        itemID: UUID, isMerge: Bool, highlightedURL: String?, on nav: UINavigationController?)
}

/// A main-list root that can open an item handed in from outside (the
/// `<scheme>://read` deep link). Both root shapes conform —
/// `ReadingListViewController` (universal) and `ArticleCardsViewController`
/// (article apps) — so `SceneDelegate` needs no kind-specific downcasts.
protocol ExternalItemOpening: AnyObject {
    func openExternally(_ item: ReadingListItem)
}
