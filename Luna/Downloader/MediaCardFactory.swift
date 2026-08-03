//
//  MediaCardFactory.swift
//  Luna
//
//  Builds the Downloader's media card surfaces from a `SavedMediaItem`: the
//  looping video/audio player, the animated GIF, the full-resolution image, or
//  the not-yet-downloaded card with its in-card progress bar — plus the
//  card-sized thumbnail behind the scrub strip and the Photos-reference badge.
//
//  It exists because TWO decks render the same media card: the Downloader's own
//  root screen and the central Luna app's all-kinds deck, which must show a
//  downloaded save with the real player rather than a title and a link. Compiled
//  only into media-handling targets (Luna + LunaDownloader).
//

import AVFoundation
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaReadingList
import LunaStorage
import Photos
import UIKit

/// The "Try Apple Intelligence" leg of an undownloaded card: offered only when
/// a model is installed, and always against the reading-list item that owns the
/// source URL (created on the spot if the media was saved without one).
enum MediaCardRescue {
    static func starter(forSourceURLString sourceURLString: String) -> (() -> Void)? {
        guard URLRescueCoordinator.engine?.isAvailable() == true else { return nil }
        return {
            let store = ReadingListStore.shared
            let itemID = store.item(forURLString: sourceURLString)?.id
                ?? store.addIfAbsent(urlString: sourceURLString, source: .manual)?.id
            if let itemID {
                URLRescueCoordinator.shared.requestManualRescue(itemID: itemID, hint: .media)
            }
        }
    }
}

enum MediaCardFactory {

    /// The card content for one saved media item. `download` is invoked by the
    /// undownloaded card's button; `rescue`, when non-nil, offers the Apple
    /// Intelligence fallback after a no-media failure.
    static func makeCard(
        for item: SavedMediaItem,
        scale: CGFloat,
        download: @escaping () -> Void,
        rescue: (() -> Void)? = nil
    ) -> CardContentViewController {
        switch item.storageState {
        case .undownloaded:
            return UndownloadedMediaCardContentViewController(
                item: item, download: download, rescue: rescue)
        case .localFile:
            guard let fileURL = item.fileURL else { return CardContentViewController() }
            switch item.kind {
            case .video:
                let content = VideoCardContentViewController(fileURL: fileURL)
                loadThumbnail(for: item, scale: scale) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            case .audio:
                let content = VideoCardContentViewController(fileURL: fileURL)
                content.setPosterImage(UIImage(systemName: "waveform.circle.fill"))
                return content
            case .gif:
                return AnimatedImageCardContentViewController(fileURL: fileURL)
            default:
                return ImageCardContentViewController(loader: { completion in
                    // Full resolution (aspect-fit to the card) — decode off-main
                    // so a large photo doesn't hitch the carousel.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let raw = UIImage(contentsOfFile: fileURL.path)
                        completion(raw?.preparingForDisplay() ?? raw)
                    }
                })
            }
        case .photosReference(let identifier, _, _):
            if item.kind == .video || item.kind == .audio {
                let content = VideoCardContentViewController(itemProvider: { completion in
                    loadPhotosVideoItem(identifier: identifier, completion: completion)
                })
                loadThumbnail(for: item, scale: scale) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            }
            return ImageCardContentViewController(loader: { completion in
                loadPhotosImage(
                    identifier: identifier, targetSize: PHImageManagerMaximumSize,
                    completion: completion)
            })
        }
    }

    /// The badge pinned to a card's top-leading corner for media that lives in
    /// the photo library, opening the asset in Photos. Nil for everything else.
    static func photosBadge(for item: SavedMediaItem) -> UIView? {
        guard let identifier = item.photosLocalIdentifier else { return nil }
        return PhotosReferenceBadgeView { openInPhotos(localIdentifier: identifier) }
    }

    static func openInPhotos(localIdentifier: String) {
        // Photos routes assets by the UUID component of PhotoKit's durable
        // local identifier. Use its public redirect scheme and fall back to
        // opening the library if this OS cannot resolve the asset route.
        let uuid = localIdentifier.split(separator: "/", maxSplits: 1).first.map(String.init)
        var components = URLComponents()
        components.scheme = "photos-redirect"
        components.host = "asset"
        components.queryItems = uuid.map { [URLQueryItem(name: "uuid", value: $0)] }

        guard let destination = components.url else { return }
        UIApplication.shared.open(destination) { success in
            guard !success, let library = URL(string: "photos-redirect://") else { return }
            UIApplication.shared.open(library)
        }
    }

    /// A mid-size decode shared by the scrub strip and its card-sized preview
    /// (which is why thumbnails are decoded larger than the strip alone needs).
    static func loadThumbnail(
        for item: SavedMediaItem, scale: CGFloat, completion: @escaping (UIImage?) -> Void
    ) {
        if let url = item.thumbnailURL {
            DownsampledImageLoader.load(
                path: url.path,
                pointSize: CGSize(width: 300, height: 300),
                scale: scale,
                isStale: { false }
            ) { image in
                completion(image)
            }
        } else if let identifier = item.photosLocalIdentifier {
            loadPhotosImage(
                identifier: identifier,
                targetSize: CGSize(width: 600, height: 600),
                completion: completion)
        } else {
            completion(nil)
        }
    }

    static func loadPhotosImage(
        identifier: String,
        targetSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        Task { @MainActor in
            guard await PhotoLibrarySaver().requestReadAuthorization(),
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil).firstObject
            else {
                completion(nil)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                completion(image)
            }
        }
    }

    static func loadPhotosVideoItem(
        identifier: String,
        completion: @escaping (AVPlayerItem?) -> Void
    ) {
        Task { @MainActor in
            guard await PhotoLibrarySaver().requestReadAuthorization(),
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil).firstObject
            else {
                completion(nil)
                return
            }
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                avAsset, _, _ in
                completion(avAsset.map { AVPlayerItem(asset: $0) })
            }
        }
    }
}

/// The verbs a media row offers, and the storage work behind two of them.
///
/// It exists for the same reason `MediaCardFactory` does: TWO decks show the
/// same media save — the Downloader's own root and the central app's all-kinds
/// deck — and they were answering "what can you do with this?" and "what goes
/// when it goes?" with two copies of the same switch over `storageState`.
enum MediaItemActions {

    /// What you can do with a media row depends only on where its file is: an
    /// undownloaded row can be fetched, a local one can be shared and put in
    /// Photos, one that is ALREADY in Photos can only be shared. In that order,
    /// above whatever the deck adds of its own (Archive, Delete).
    static func menuActions(
        for item: SavedMediaItem,
        download: @escaping () -> Void,
        share: @escaping () -> Void,
        saveToPhotos: @escaping () -> Void
    ) -> [UIMenuElement] {
        switch item.storageState {
        case .undownloaded:
            return [UIAction(
                title: L10n.string("Download"), image: UIImage(systemName: "arrow.down.circle")
            ) { _ in download() }]
        case .localFile:
            var actions: [UIMenuElement] = [UIAction(
                title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in share() }]
            if item.kind?.canSaveToPhotos == true {
                actions.append(UIAction(
                    title: L10n.string("Save to Photos"),
                    image: UIImage(systemName: "photo.badge.plus")
                ) { _ in saveToPhotos() })
            }
            return actions
        case .photosReference:
            return [UIAction(
                title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in share() }]
        }
    }

    /// An explicit "download this exact item now" gesture — it bypasses the
    /// Wi-Fi-only setting, unlike the opportunistic resume sweep.
    static func startManualDownload(_ item: SavedMediaItem) {
        Task {
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.sourceURLString, title: item.title, manual: true)
        }
    }

    /// Where a media row's file actually is, as one string — the change key both
    /// decks fingerprint a media card by, so a download that finishes in the
    /// background re-renders the card instead of leaving a placeholder.
    static func storageStateKey(_ item: SavedMediaItem) -> String {
        switch item.storageState {
        case .undownloaded: return "undownloaded"
        case .localFile: return "local|\(item.fileName ?? "")"
        case .photosReference(let identifier, _, _): return "photos|\(identifier)"
        }
    }

    /// Saves a defensive COPY of the row's local file to Photos (never the file
    /// itself) — moving the original would risk losing Luna's own copy if the
    /// Photos save fails or is slow.
    static func saveToPhotos(
        _ item: SavedMediaItem,
        saver: PhotoLibrarySaver,
        from presenter: UIViewController
    ) {
        Task { @MainActor in
            do {
                guard case .localFile = item.storageState,
                      let fileURL = item.fileURL, let kind = item.kind
                else { return }
                guard await saver.requestReadAuthorization() else {
                    presentAlert(
                        title: L10n.string("Photos Access Needed"),
                        message: L10n.string("Allow photo library access in Settings to save media."),
                        from: presenter)
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await SavedMediaPhotosSync.saveAndTransition(
                    itemID: item.id, fileURL: tempURL, kind: kind, shouldMoveFile: true,
                    saver: saver, store: SavedMediaStore.shared)
                presentAlert(
                    title: L10n.string("Saved to Photos"),
                    message: L10n.string("The media was added to your photo library."),
                    from: presenter)
            } catch {
                presentAlert(
                    title: L10n.string("Save Failed"),
                    message: L10n.string("Couldn't save this media to Photos."), from: presenter)
            }
        }
    }

    /// Everything that belongs to a media row besides the row itself: its Photos
    /// asset and the auto-download bookkeeping that would otherwise treat the URL
    /// as already fetched. The whole save goes when the card does.
    ///
    /// - Parameters:
    ///   - deletesReadingListItem: true for a deck whose card IS the media row
    ///     (the Downloader's), false where the reading-list entry is the card and
    ///     its own deck deletes it.
    ///   - onPhotosDeletionFailure: the Downloader tells the user its Photos
    ///     deletion needs permission; the all-kinds deck lets it pass, having
    ///     already removed the card.
    static func release(
        _ item: SavedMediaItem,
        saver: PhotoLibrarySaver,
        deletesReadingListItem: Bool,
        onPhotosDeletionFailure: (@MainActor () -> Void)? = nil
    ) {
        Task { @MainActor in
            do {
                if let localIdentifier = item.photosLocalIdentifier {
                    try await SavedMediaPhotosSync.deletePhotosAssetIfPresent(
                        localIdentifier, saver: saver)
                }
                AutoDownloadSettings.unmarkDownloaded(item.sourceURLString)
                if deletesReadingListItem,
                   let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
                    ReadingListStore.shared.delete(saved)
                }
                SavedMediaStore.shared.delete(item)
            } catch {
                onPhotosDeletionFailure?()
            }
        }
    }

    static func presentAlert(title: String, message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        presenter.present(alert, animated: true)
    }
}
