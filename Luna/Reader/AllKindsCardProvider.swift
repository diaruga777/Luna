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
            download: {
                Task {
                    // An explicit "download this one now" — bypasses the
                    // Wi-Fi-only setting, as the Downloader's own card does.
                    _ = await LiveMediaDownloadManager.shared.start(
                        urlString: media.sourceURLString, title: media.title, manual: true)
                }
            },
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

    func menuActions(
        for item: ReadingListItem, presenter: UIViewController, sourceView: UIView
    ) -> [UIMenuElement] {
        guard let media = media(for: item) else { return [] }
        switch media.storageState {
        case .undownloaded:
            return [UIAction(
                title: L10n.string("Download"), image: UIImage(systemName: "arrow.down.circle")
            ) { _ in
                Task {
                    _ = await LiveMediaDownloadManager.shared.start(
                        urlString: media.sourceURLString, title: media.title, manual: true)
                }
            }]
        case .localFile:
            var actions: [UIMenuElement] = [shareAction(media, presenter: presenter, sourceView: sourceView)]
            if media.kind?.canSaveToPhotos == true {
                actions.append(UIAction(
                    title: L10n.string("Save to Photos"), image: UIImage(systemName: "photo.badge.plus")
                ) { [weak self, weak presenter] _ in
                    guard let presenter else { return }
                    self?.saveToPhotos(media, from: presenter)
                })
            }
            return actions
        case .photosReference:
            return [shareAction(media, presenter: presenter, sourceView: sourceView)]
        }
    }

    /// The whole save goes when the card does: the downloaded file, its Photos
    /// asset, and the auto-download bookkeeping that would otherwise treat the
    /// URL as already fetched.
    func deleteCompanionStorage(for item: ReadingListItem) {
        guard let media = SavedMediaStore.shared.item(forURLString: item.urlString) else { return }
        AutoDownloadSettings.unmarkDownloaded(media.sourceURLString)
        if let localIdentifier = media.photosLocalIdentifier {
            Task { [photoSaver] in
                try? await SavedMediaPhotosSync.deletePhotosAssetIfPresent(
                    localIdentifier, saver: photoSaver)
            }
        }
        SavedMediaStore.shared.delete(media)
    }

    func fingerprint(for item: ReadingListItem) -> String {
        guard let media = media(for: item) else { return "" }
        switch media.storageState {
        case .undownloaded: return "undownloaded"
        case .localFile: return "local|\(media.fileName ?? "")"
        case .photosReference(let identifier, _, _): return "photos|\(identifier)"
        }
    }

    var changeNotificationNames: [Notification.Name] { [.savedMediaChanged] }

    // MARK: - Actions

    private func shareAction(
        _ media: SavedMediaItem, presenter: UIViewController, sourceView: UIView
    ) -> UIAction {
        UIAction(title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")) {
            [weak presenter] _ in
            guard let presenter else { return }
            Task { @MainActor in
                // A single concrete file URL is the whole payload — the system
                // derives the preview and no Luna metadata rides along.
                guard let export = await MediaAutoDownloader.exportFile(from: media) else {
                    Self.presentAlert(
                        title: L10n.string("Share Failed"),
                        message: L10n.string("Couldn't prepare this media for sharing."), from: presenter)
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

    /// Saves a defensive COPY to Photos — moving the original would risk losing
    /// Luna's own copy if the save fails.
    private func saveToPhotos(_ media: SavedMediaItem, from presenter: UIViewController) {
        Task { @MainActor in
            do {
                guard case .localFile = media.storageState,
                      let fileURL = media.fileURL, let kind = media.kind
                else { return }
                guard await photoSaver.requestReadAuthorization() else {
                    Self.presentAlert(
                        title: L10n.string("Photos Access Needed"),
                        message: L10n.string("Allow photo library access in Settings to save media."),
                        from: presenter)
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await SavedMediaPhotosSync.saveAndTransition(
                    itemID: media.id, fileURL: tempURL, kind: kind, shouldMoveFile: true,
                    saver: photoSaver, store: SavedMediaStore.shared)
                Self.presentAlert(
                    title: L10n.string("Saved to Photos"),
                    message: L10n.string("The media was added to your photo library."), from: presenter)
            } catch {
                Self.presentAlert(
                    title: L10n.string("Save Failed"),
                    message: L10n.string("Couldn't save this media to Photos."), from: presenter)
            }
        }
    }

    private static func presentAlert(
        title: String, message: String, from presenter: UIViewController
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        presenter.present(alert, animated: true)
    }
}
