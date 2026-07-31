//
//  PhotosBackingPresence.swift
//  LunaMediaDownload
//

import Foundation
import Photos

/// Whether the Photos asset behind a `.photosReference` row still exists.
///
/// `indeterminate` is the honest answer without FULL read authorization: with
/// limited access (or none at all) an empty fetch means "outside the selected
/// set", not "the user deleted it", and must never be read as evidence of
/// deletion — the same rule the root carousel's reconcile sweep follows.
public enum PhotosBackingPresence: Equatable {
    case present
    case deleted
    case indeterminate
}

/// The presence probe `SavedMediaStore` consults before it answers "this URL is
/// already downloaded". A protocol so tests can state a verdict without a photo
/// library, and so the probe stays NON-PROMPTING: it runs inside App Intents and
/// extensions, where a permission prompt has no host to appear over.
public protocol PhotosBackingProbing {
    func presence(ofAssetWithLocalIdentifier localIdentifier: String) -> PhotosBackingPresence
}

/// The real probe: one PhotoKit fetch, gated on full read authorization. A
/// process without it (a share extension, a Shortcuts run in a sibling app)
/// reports `indeterminate` and leaves the row exactly as it found it.
public struct PhotoKitBackingProbe: PhotosBackingProbing {
    public init() {}

    public func presence(
        ofAssetWithLocalIdentifier localIdentifier: String
    ) -> PhotosBackingPresence {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return .indeterminate
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return assets.firstObject == nil ? .deleted : .present
    }
}
