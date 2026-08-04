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
import LunaSocialUI
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
                let content = VideoCardContentViewController(
                    fileURL: fileURL, speedMemoryKey: speedMemoryKey(for: item))
                loadThumbnail(for: item, scale: scale) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            case .audio:
                let content = VideoCardContentViewController(
                    fileURL: fileURL, speedMemoryKey: speedMemoryKey(for: item))
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
                let content = VideoCardContentViewController(
                    itemProvider: { completion in
                        loadPhotosVideoItem(identifier: identifier, completion: completion)
                    },
                    speedMemoryKey: speedMemoryKey(for: item))
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

    /// The identity a playback speed is remembered against — the media row, not
    /// the card, so the speed survives the card being unmounted two slots out
    /// and rebuilt on the way back, and is the SAME memory whichever deck (the
    /// Downloader's or the central app's) or player surface shows the item.
    static func speedMemoryKey(for item: SavedMediaItem) -> String {
        "savedMedia.\(item.id.uuidString)"
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

    /// The share circle's menu for a media row, in the reader pill's ladder
    /// shape: the link verbs first, then the file itself once Luna actually
    /// holds one. The link is always `sourceURLString` — the original URL the
    /// save came from, never the resolved CDN asset — and it is shareable in
    /// every storage state, which is why an undownloaded row still gets a menu
    /// (just without its file row). Both decks that show media hang this off
    /// their trailing circle, so the options never diverge between apps.
    static func shareMenuRows(
        for item: SavedMediaItem,
        copyLink: @escaping () -> Void,
        shareLink: @escaping () -> Void,
        shareFile: @escaping () -> Void
    ) -> [ReaderShareSheet.Row] {
        var rows = linkRows(copyLink: copyLink, shareLink: shareLink)
        if case .undownloaded = item.storageState {} else {
            rows.append(.init(
                title: shareFileTitle(for: item.kind),
                systemImage: shareFileSymbol(for: item.kind),
                isPrimary: false, action: shareFile))
        }
        return rows
    }

    /// The two link rungs every save offers, whatever else it holds.
    private static func linkRows(
        copyLink: @escaping () -> Void,
        shareLink: @escaping () -> Void
    ) -> [ReaderShareSheet.Row] {
        [
            .init(title: L10n.string("Copy link"), systemImage: "doc.on.doc",
                  isPrimary: false, action: copyLink),
            .init(title: L10n.string("Share link"), systemImage: "square.and.arrow.up",
                  isPrimary: false, action: shareLink),
        ]
    }

    /// A nil kind renders as an image card (`MediaCardFactory.makeCard`), so
    /// its share row says the same.
    static func shareFileTitle(for kind: MediaAsset.Kind?) -> String {
        switch kind {
        case .video: return L10n.string("Share video")
        case .gif: return L10n.string("Share GIF")
        case .audio: return L10n.string("Share audio")
        case .image, nil: return L10n.string("Share image")
        }
    }

    private static func shareFileSymbol(for kind: MediaAsset.Kind?) -> String {
        switch kind {
        case .video: return "video"
        case .audio: return "waveform"
        case .gif, .image, nil: return "photo"
        }
    }

    /// The rows as the native menu the trailing circle presents, with the link
    /// verbs wired to the shared social sheet. `shareFile` stays injected — the
    /// export-and-present dance differs per deck (the Downloader prewarms and
    /// pauses its player; the all-kinds deck exports cold).
    static func shareMenu(
        for item: SavedMediaItem,
        presenter: UIViewController,
        sourceView: UIView?,
        shareFile: @escaping () -> Void
    ) -> UIMenu {
        ReaderShareSheet.menu(rows: shareMenuRows(
            for: item,
            copyLink: copyLinkVerb(urlString: item.sourceURLString, presenter: presenter),
            shareLink: shareLinkVerb(
                urlString: item.sourceURLString, presenter: presenter, sourceView: sourceView),
            shareFile: shareFile))
    }

    /// Copy link / Share link alone — for a save Luna knows only as a LINK: a
    /// platform item with no media row behind it. The pill still owes the user
    /// the link verbs there; it just has no file to name.
    static func linkShareMenu(
        urlString: String,
        presenter: UIViewController,
        sourceView: UIView?
    ) -> UIMenu {
        ReaderShareSheet.menu(rows: linkRows(
            copyLink: copyLinkVerb(urlString: urlString, presenter: presenter),
            shareLink: shareLinkVerb(
                urlString: urlString, presenter: presenter, sourceView: sourceView)))
    }

    private static func copyLinkVerb(
        urlString: String, presenter: UIViewController
    ) -> () -> Void {
        { [weak presenter] in
            guard let presenter else { return }
            SendToFriendSheet.copyLink(urlString: urlString, from: presenter)
        }
    }

    private static func shareLinkVerb(
        urlString: String, presenter: UIViewController, sourceView: UIView?
    ) -> () -> Void {
        { [weak presenter, weak sourceView] in
            guard let presenter else { return }
            SendToFriendSheet.shareLink(
                urlString: urlString, from: presenter, sourceView: sourceView)
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
