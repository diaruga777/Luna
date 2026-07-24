//
//  MediaItemProvider.swift
//  Luna
//

import LunaModels
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// A media source suitable for sharing or copying without eagerly loading its
/// bytes. Photo-library sources are resolved lazily when a consumer requests the
/// provider's file representation.
public enum MediaItemProviderBacking: Equatable {
    case localFile(URL)
    case photo(localIdentifier: String, kind: MediaAsset.Kind)
}

public enum MediaItemProviderFactory {
    public static func makeProvider(
        for backing: MediaItemProviderBacking,
        photoLibrary: PhotoLibrarySaver = PhotoLibrarySaver()
    ) -> NSItemProvider? {
        switch backing {
        case .localFile(let fileURL):
            return NSItemProvider(contentsOf: fileURL)

        case .photo(let localIdentifier, let kind):
            let provider = NSItemProvider()
            let contentType = contentType(for: kind)
            provider.registerFileRepresentation(
                forTypeIdentifier: contentType.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let progress = Progress(totalUnitCount: 1)
                Task {
                    guard !progress.isCancelled else {
                        completion(nil, false, CancellationError())
                        return
                    }
                    let destination = MediaDownloadStorage.newFileURL(
                        extension: fileExtension(for: kind))
                    do {
                        try await photoLibrary.writeResource(
                            localIdentifier: localIdentifier,
                            kind: kind,
                            to: destination)
                        progress.completedUnitCount = 1
                        completion(destination, false, nil)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        completion(nil, false, error)
                    }
                }
                return progress
            }
            provider.suggestedName = "Luna Media.\(fileExtension(for: kind))"
            return provider
        }
    }

    private static func contentType(for kind: MediaAsset.Kind) -> UTType {
        switch kind {
        case .video: return .mpeg4Movie
        case .audio: return .audio
        case .gif: return .gif
        case .image: return .jpeg
        }
    }

    private static func fileExtension(for kind: MediaAsset.Kind) -> String {
        switch kind {
        case .video: return "mp4"
        case .audio: return "m4a"
        case .gif: return "gif"
        case .image: return "jpg"
        }
    }
}

@MainActor
public enum MediaPasteboard {
    /// Places a lazy, file-backed representation on the general pasteboard. In
    /// particular, videos are never assigned as an eager in-memory Data value.
    @discardableResult
    public static func copy(_ backing: MediaItemProviderBacking) -> Bool {
        guard let provider = MediaItemProviderFactory.makeProvider(for: backing) else {
            return false
        }
        UIPasteboard.general.itemProviders = [provider]
        return true
    }
}

/// Copies a just-saved item to the pasteboard when the user has opted in,
/// shared by the background job engine (`LiveMediaDownloadManager`) and the
/// foreground service (`MediaDownloadService`) — both call this right after
/// a successful save.
@MainActor
func copyToClipboardIfEnabled(_ item: SavedMediaItem) {
    guard AutoDownloadSettings.autoCopyDownloadsToClipboard,
          let kind = item.kind else { return }
    switch item.storageState {
    case .localFile:
        if let url = item.fileURL { _ = MediaPasteboard.copy(.localFile(url)) }
    case .photosReference(let identifier, _, _):
        _ = MediaPasteboard.copy(.photo(localIdentifier: identifier, kind: kind))
    case .undownloaded:
        break
    }
}
