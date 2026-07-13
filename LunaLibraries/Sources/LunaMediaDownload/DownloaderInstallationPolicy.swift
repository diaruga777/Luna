import LunaAppConfig
import Foundation
import Photos

/// App-Group installation evidence used for cross-app Downloader behavior.
/// Markers intentionally survive uninstall: "was installed" is sufficient.
public enum LunaInstallationMarkers {
    public static let downloaderKey = "lunaInstalled.downloader"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    public static var downloaderWasInstalled: Bool {
        defaults.bool(forKey: downloaderKey)
    }

    public static func recordInstalled(surfaceIdentifier: String) {
        defaults.set(true, forKey: "lunaInstalled.\(surfaceIdentifier)")
    }

    public static func wasInstalled(surfaceIdentifier: String) -> Bool {
        defaults.bool(forKey: "lunaInstalled.\(surfaceIdentifier)")
    }
}

/// Photos authorization boundary for Downloader-owned App Intent downloads.
public enum DownloaderIntentPhotoPermission {
    public static var requiresForegroundRequest: Bool {
        LunaInstallationMarkers.downloaderWasInstalled
            && AutoDownloadSettings.autoSaveDownloadsToPhotos
            && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    /// Establishes read/write access when Photos saving is enabled. A declined
    /// request is not fatal: the download manager retains the file in shared storage.
    @discardableResult
    public static func requestIfNeeded() async -> Bool {
        guard LunaInstallationMarkers.downloaderWasInstalled,
              AutoDownloadSettings.autoSaveDownloadsToPhotos
        else { return true }
        return await PhotoLibrarySaver().requestReadAuthorization()
    }
}
