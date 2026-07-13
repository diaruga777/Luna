//
//  PhotoLibrarySaver.swift
//  Luna
//

import Foundation
import Photos

/// Saves downloaded media files to the user's photo library via PhotoKit,
/// requesting add-only authorization first.
public struct PhotoLibrarySaver: PhotoLibrarySaving {
    public init() {}

    public func requestAddAuthorization() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Requests read/write authorization, which is required to resolve a durable
    /// local identifier back to its PhotoKit asset on subsequent launches.
    public func requestReadAuthorization() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Fetches an asset by the durable identifier returned from `save`. This does
    /// not prompt; callers should establish read authorization at an appropriate
    /// UI boundary first.
    public func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Deletes the asset represented by a saved Photos local identifier.
    ///
    /// A missing asset is already deleted, so this is an idempotent no-op when
    /// full Photos access confirms that the identifier no longer resolves. With
    /// limited access, a missing fetch may simply mean that the asset is outside
    /// the selected set, so deletion is rejected rather than removing Luna's
    /// reference without being able to remove the Photos asset too.
    public func deleteAsset(localIdentifier: String) async throws {
        guard await requestReadAuthorization() else {
            throw MediaDownloadError.permissionDenied
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard let asset = fetchAsset(localIdentifier: localIdentifier) else {
            guard status == .authorized else {
                throw MediaDownloadError.permissionDenied
            }
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? MediaDownloadError.saveFailed)
                }
            }
        }
    }

    /// Writes the original PhotoKit resource to a file without materializing the
    /// media as `Data`. iCloud-backed resources may download on demand.
    public func writeResource(
        localIdentifier: String,
        kind: MediaAsset.Kind,
        to destinationURL: URL
    ) async throws {
        guard await requestReadAuthorization() else {
            throw MediaDownloadError.permissionDenied
        }
        guard let asset = fetchAsset(localIdentifier: localIdentifier),
              let resource = Self.preferredResource(for: asset, kind: kind)
        else {
            throw MediaDownloadError.noMedia
        }
        try? FileManager.default.removeItem(at: destinationURL)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: destinationURL, options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func save(
        fileURL: URL, kind: MediaAsset.Kind, shouldMoveFile: Bool
    ) async throws -> String {
        // GIFs and stills are photo resources; mp4s are video resources.
        let resourceType: PHAssetResourceType = kind == .video ? .video : .photo
        return try await withCheckedThrowingContinuation { continuation in
            var localIdentifier: String?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // Stamp with the current save time (not the post's original/embedded
                // date) so the saved item always sorts as the newest in Photos.
                request.creationDate = Date()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = shouldMoveFile
                request.addResource(with: resourceType, fileURL: fileURL, options: options)
                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success, let localIdentifier {
                    continuation.resume(returning: localIdentifier)
                } else {
                    continuation.resume(throwing: error ?? MediaDownloadError.saveFailed)
                }
            }
        }
    }

    private static func preferredResource(
        for asset: PHAsset, kind: MediaAsset.Kind
    ) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        switch kind {
        case .video:
            return resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .pairedVideo })
        case .gif, .image:
            return resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .alternatePhoto })
        }
    }
}
