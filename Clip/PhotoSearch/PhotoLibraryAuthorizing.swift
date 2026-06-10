//
//  PhotoLibraryAuthorizing.swift
//  clipper
//

import Photos

/// Wraps photo-library read authorization so it can be mocked in tests (the
/// simulator/test environment can't grant real Photos access).
protocol PhotoLibraryAuthorizing: Sendable {
    /// The current read/write authorization status.
    var currentStatus: PHAuthorizationStatus { get }

    /// Requests read/write access and returns the resulting status.
    func requestReadAccess() async -> PHAuthorizationStatus
}

final class PhotoLibraryAuthorizer: PhotoLibraryAuthorizing {

    var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestReadAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
