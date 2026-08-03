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
