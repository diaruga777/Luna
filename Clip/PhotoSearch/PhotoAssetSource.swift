//
//  PhotoAssetSource.swift
//  clipper
//

import CoreGraphics
import Foundation
import Photos
import UIKit

/// A lightweight reference to a photo-library image asset.
struct PhotoAssetRef: Sendable, Equatable {
    let localIdentifier: String
    let creationDate: Date
}

/// Supplies the list of image assets and loads pixel data for them. Abstracted
/// behind a protocol so the indexer can be unit-tested without a real photo
/// library (which the simulator/test host lacks).
protocol PhotoAssetSource: Sendable {
    /// All image assets, newest first.
    func fetchImageAssets() -> [PhotoAssetRef]

    /// Loads a downscaled `CGImage` (roughly `targetSize` on its long edge), or
    /// nil if the asset can't be loaded.
    func loadImage(localIdentifier: String, targetSize: Int) async -> CGImage?
}

/// PhotoKit-backed asset source.
final class PhotoKitAssetSource: PhotoAssetSource {

    private let imageManager = PHImageManager.default()

    func fetchImageAssets() -> [PhotoAssetRef] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)

        var assets: [PhotoAssetRef] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(
                PhotoAssetRef(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate ?? .distantPast
                )
            )
        }
        return assets
    }

    func loadImage(localIdentifier: String, targetSize: Int) async -> CGImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        let pixelSize = CGSize(width: targetSize, height: targetSize)
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ result: CGImage?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            imageManager.requestImage(
                for: asset,
                targetSize: pixelSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Resume on terminal outcomes so the continuation can never hang:
                // an error, a cancellation, or a non-degraded (final) image.
                if (info?[PHImageErrorKey] != nil) || ((info?[PHImageCancelledKey] as? Bool) ?? false) {
                    finish(nil)
                    return
                }
                // PhotoKit may deliver a low-res placeholder before the final
                // image; wait for the non-degraded result.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                finish(image?.cgImage)
            }
        }
    }
}
