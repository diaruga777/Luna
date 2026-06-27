//
//  PhotoLibrarySaver.swift
//  Clip
//

import Foundation
import Photos

/// Saves downloaded media files to the user's photo library via PhotoKit,
/// requesting add-only authorization first.
struct PhotoLibrarySaver: PhotoLibrarySaving {

    func requestAddAuthorization() async -> Bool {
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

    func save(fileURL: URL, kind: MediaAsset.Kind) async throws {
        // GIFs and stills are photo resources; mp4s are video resources.
        let resourceType: PHAssetResourceType = kind == .video ? .video : .photo
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // Stamp with the current save time (not the post's original/embedded
                // date) so the saved item always sorts as the newest in Photos.
                request.creationDate = Date()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true   // consume the temp file
                request.addResource(with: resourceType, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? MediaDownloadError.saveFailed)
                }
            }
        }
    }
}
