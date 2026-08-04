//
//  AllKindsCardProvider.swift
//  Luna
//
//  The central Luna app's implementation of `AllKindsCardProviding`: it lets the
//  one all-kinds deck render a Downloader save exactly as the Downloader does —
//  the real looping player, GIF, image, or in-card download progress, its
//  Photos badge, its platform chip, and its Share / Save to Photos verbs —
//  instead of a title with "Tap to open" under it.
//
//  Compiled ONLY into the central app (the other three targets exclude it via
//  the synchronized group's membership exceptions), which is what lets
//  `ArticleCardsViewController` — shared with Luna Reader — stay free of every
//  media symbol.
//

import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaStorage
import UIKit

final class AllKindsCardProvider: AllKindsCardProviding {

    private let photoSaver = PhotoLibrarySaver()

    /// The downloaded media behind a platform save, if Luna has any.
    private func media(for item: ReadingListItem) -> SavedMediaItem? {
        guard item.contentPlatform != nil else { return nil }
        return SavedMediaStore.shared.item(forURLString: item.urlString)
    }

    func cardContent(for item: ReadingListItem) -> CardContentViewController? {
        guard let media = media(for: item), !media.isArchived else { return nil }
        return MediaCardFactory.makeCard(
            for: media,
            scale: UIScreen.main.scale,
            download: { MediaItemActions.startManualDownload(media) },
            rescue: MediaCardRescue.starter(forSourceURLString: media.sourceURLString))
    }

    func topLeadingAccessory(for item: ReadingListItem) -> UIView? {
        media(for: item).flatMap(MediaCardFactory.photosBadge(for:))
    }

    /// A platform save is identified by its platform, not by its host's favicon.
    func sourceBadge(for item: ReadingListItem) -> CarouselSourceBadge? {
        guard let platform = item.contentPlatform else { return nil }
        if let asset = platform.logoAssetName, let logo = UIImage(named: asset) {
            return .icon(logo)
        }
        guard let glyph = PlatformRegistry.shared.module(for: platform)?.glyphSymbolName
        else { return nil }
        return .symbol(glyph)
    }

    func thumbnail(for item: ReadingListItem, completion: @escaping (UIImage?) -> Void) {
        guard let media = media(for: item) else {
            completion(nil)
            return
        }
        MediaCardFactory.loadThumbnail(
            for: media, scale: UIScreen.main.scale, completion: completion)
    }

    /// A media save's card is a picture, so its strip chip is that picture too —
    /// the same still the Downloader's own strip shows. An unarchived save with
    /// no still yet falls back to a badge chip inside the carousel.
    func prefersThumbnailChip(for item: ReadingListItem) -> Bool {
        guard let media = media(for: item) else { return false }
        return !media.isArchived
    }

    /// Only media cards are expensive to build — each one is an AVPlayer, and
    /// the mini-card strip prepares its whole visible window at once.
    func allowsPreparedPreviewContent(for item: ReadingListItem) -> Bool {
        media(for: item) == nil
    }

    /// The Downloader's own verbs for this row — the same switch over where its
    /// file is, from the same place its own deck reads it — offered above the
    /// deck's Archive/Delete.
    func menuActions(
        for item: ReadingListItem, presenter: UIViewController, sourceView: UIView
    ) -> [UIMenuElement] {
        guard let media = media(for: item) else { return [] }
        return MediaItemActions.menuActions(
            for: media,
            download: { MediaItemActions.startManualDownload(media) },
            share: { [weak presenter] in
                guard let presenter else { return }
                Self.share(media, from: presenter, sourceView: sourceView)
            },
            saveToPhotos: { [weak self, weak presenter] in
                guard let self, let presenter else { return }
                MediaItemActions.saveToPhotos(
                    media, saver: self.photoSaver, from: presenter)
            })
    }

    /// The whole save goes when the card does: the downloaded file, its Photos
    /// asset, and the auto-download bookkeeping that would otherwise treat the
    /// URL as already fetched. The reading-list row itself is the CARD here, and
    /// the deck deletes it directly.
    func deleteCompanionStorage(for item: ReadingListItem) {
        guard let media = SavedMediaStore.shared.item(forURLString: item.urlString) else { return }
        MediaItemActions.release(
            media, saver: photoSaver, deletesReadingListItem: false)
    }

    func fingerprint(for item: ReadingListItem) -> String {
        media(for: item).map(MediaItemActions.storageStateKey) ?? ""
    }

    var changeNotificationNames: [Notification.Name] { [.savedMediaChanged] }

    // MARK: - Actions

    /// A single concrete file URL is the whole payload — the system derives the
    /// preview and no Luna metadata rides along.
    private static func share(
        _ media: SavedMediaItem, from presenter: UIViewController, sourceView: UIView
    ) {
        Task { @MainActor in
            guard let export = await MediaAutoDownloader.exportFile(from: media) else {
                MediaItemActions.presentAlert(
                    title: L10n.string("Share Failed"),
                    message: L10n.string("Couldn't prepare this media for sharing."),
                    from: presenter)
                return
            }
            let activity = UIActivityViewController(
                activityItems: [export.fileURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                MediaDownloadStorage.discardIntentExport(at: export.fileURL)
            }
            activity.popoverPresentationController?.sourceView = sourceView
            activity.popoverPresentationController?.sourceRect = sourceView.bounds
            presenter.present(activity, animated: true)
        }
    }
}
