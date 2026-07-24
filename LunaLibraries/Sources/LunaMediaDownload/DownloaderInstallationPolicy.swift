import LunaStorage
import Foundation
import Photos

// `LunaInstallationMarkers` moved to LunaStorage (kind-neutral App-Group
// bookkeeping shared by every app's launch path).

/// Photos authorization boundary for media-owned App Intent downloads. Only a
/// media-handling process (Downloader, the central Luna app) ever starts one.
public enum DownloaderIntentPhotoPermission {
    public static var requiresForegroundRequest: Bool {
        MediaAutoDownloader.isRunningInDownloader
            && AutoDownloadSettings.autoSaveDownloadsToPhotos
            && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    /// Establishes read/write access when Photos saving is enabled. A declined
    /// request is not fatal: the download manager retains the file in shared storage.
    @discardableResult
    public static func requestIfNeeded() async -> Bool {
        guard MediaAutoDownloader.isRunningInDownloader,
              AutoDownloadSettings.autoSaveDownloadsToPhotos
        else { return true }
        return await PhotoLibrarySaver().requestReadAuthorization()
    }
}
