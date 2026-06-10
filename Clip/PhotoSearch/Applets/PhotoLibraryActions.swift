//
//  PhotoLibraryActions.swift
//  Clip
//
//  Side-effects an applet can perform on a matched photo, beyond notifying. Each is
//  best-effort and a no-op without photo-library write access.
//

import Photos

enum PhotoLibraryActions {

    static let albumTitle = "Clip Matches"

    /// Marks the matched photo as a Favorite.
    static func favorite(_ localIdentifier: String) async {
        guard let asset = asset(for: localIdentifier) else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = true
        }
    }

    /// Adds the matched photo to the "Clip Matches" album, creating it if needed.
    static func addToClipAlbum(_ localIdentifier: String) async {
        guard let asset = asset(for: localIdentifier),
              let album = await clipAlbum() else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
    }

    private static func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private static func clipAlbum() async -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", albumTitle)
        if let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: options
        ).firstObject {
            return existing
        }
        var placeholderID: String?
        try? await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [placeholderID], options: nil
        ).firstObject
    }
}
