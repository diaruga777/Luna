//
//  SavedMediaItem+Files.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels

/// Where a media row's files are. The model itself lives in LunaModels, beside
/// `SavedItem`, and names its files without knowing which directory holds them;
/// these read that from the store.
public extension SavedMediaItem {
    var fileURL: URL? {
        fileName.map { SavedMediaStore.shared.mediaDirectory.appendingPathComponent($0) }
    }

    var thumbnailURL: URL? {
        thumbnailFileName.map {
            SavedMediaStore.shared.thumbnailDirectory.appendingPathComponent($0)
        }
    }
}
