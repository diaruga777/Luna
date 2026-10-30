import Foundation
import LunaModels
import LunaStorage

/// Resolves the owning save again before handing out a media file. In
/// particular, a stale Shortcut entity cannot export a deleted save's video.
public enum SavedItemVideoExport {
    public enum Failure: LocalizedError, Equatable {
        case missing, notDownloaded, unavailable
        public var errorDescription: String? {
            switch self {
            case .missing: return "This saved item is no longer available."
            case .notDownloaded: return "Download this item’s video in Luna Reader first."
            case .unavailable: return "Couldn’t read this video. Check photo library access if it is stored in Photos, or download it again in Luna Reader."
            }
        }
    }

    public static func video(
        saveID: UUID,
        store: SavesStore = .shared,
        mediaStore: SavedMediaStore = .shared,
        export: (SavedMediaItem) async -> DownloadedMedia? = MediaAutoDownloader.exportFile
    ) async throws -> DownloadedMedia {
        guard store.item(withID: saveID) != nil else { throw Failure.missing }
        guard let media = mediaStore.item(withID: saveID), media.kind == .video else { throw Failure.notDownloaded }
        guard media.storageState != .undownloaded else { throw Failure.notDownloaded }
        guard let file = await export(media) else { throw Failure.unavailable }
        return file
    }
}
