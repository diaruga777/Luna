//
//  MediaDownload.swift
//  Luna
//

import LunaURLClassification
import LunaModels
import LunaStorage
import Foundation

// Re-exported so every existing `import LunaMediaDownload` call site keeps
// seeing `SocialMediaResolver` / the per-platform parsers / `MediaAsset.direct`
// unchanged. Those moved to LunaMediaResolve — a Foundation-only target the
// Safari extension can link without dragging UIKit/Photos/ActivityKit in with
// them (`claudedocs/safari-extension.md`).
@_exported import LunaMediaResolve

// `MediaAsset` + `MediaTimeRange` moved to LunaModels (kind-neutral payload
// for LunaURLRescue's `.rescuedMedia` and the app shells' media seams). The
// download-specific conveniences below stay here.

/// Why a media download failed, with a user-facing message.
public enum MediaDownloadError: Error {
    case unsupported      // not an X / Instagram / TikTok / Facebook post
    case noMedia          // the post had no downloadable media
    case permissionDenied // Photos add access not granted
    case downloadFailed   // the media file couldn't be fetched
    case saveFailed       // PhotoKit rejected the save
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64?)

    /// A short message suitable for a toast / status label.
    public var message: String {
        switch self {
        case .unsupported: return L10n.string("Downloader_media_error_unsupported")
        case .noMedia: return L10n.string("Downloader_media_error_noMedia")
        case .permissionDenied: return L10n.string("Downloader_media_error_permissionDenied")
        case .downloadFailed: return L10n.string("Downloader_media_error_downloadFailed")
        case .saveFailed: return L10n.string("Downloader_media_error_saveFailed")
        case .insufficientStorage(let required, _):
            let amount = ByteCountFormatter.string(
                fromByteCount: required, countStyle: .file)
            return L10n.string("Downloader_media_error_insufficientStorage", amount)
        }
    }
}

/// Which platforms support direct media download to Photos. The two entry points
/// (the action extension's "Download media to photo roll" button and the reading
/// list row's long-press menu) both gate on this.
public enum MediaDownloadablePlatform {
    /// The platforms whose posts expose downloadable still/gif/video media.
    public static let supported: Set<ContentPlatform> = [
        .x, .instagram, .tiktok, .facebook, .reddit, .youtube, .web,
    ]

    /// Whether `urlString` is a post on a platform we can pull media from.
    public static func supports(_ urlString: String) -> Bool {
        if DirectMediaURL.kind(for: urlString) != nil { return true }
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return supported.contains(platform)
    }
}

// `MediaAsset.direct(url:)` moved to LunaMediaResolve (the resolver's own
// first step), and comes back through the `@_exported import` above.

public extension MediaAsset.Kind {
    /// PhotoKit accepts still/animated images and video, but not standalone
    /// audio files. Callers use this before requesting Photos authorization.
    var canSaveToPhotos: Bool { self != .audio }
}

/// Saves a downloaded media file to the user's photo library.
public protocol PhotoLibrarySaving {
    /// Requests add-only Photos authorization, returning whether it's granted.
    func requestAddAuthorization() async -> Bool
    /// Requests read/write Photos access so saved identifiers can be resolved later.
    func requestReadAuthorization() async -> Bool
    /// Saves the file at `fileURL` (of the given kind) to the photo library and
    /// returns PhotoKit's durable local identifier for the created asset.
    func save(
        fileURL: URL, kind: MediaAsset.Kind, shouldMoveFile: Bool
    ) async throws -> String
}

public extension PhotoLibrarySaving {
    func save(fileURL: URL, kind: MediaAsset.Kind) async throws -> String {
        try await save(fileURL: fileURL, kind: kind, shouldMoveFile: true)
    }
}

/// A media item downloaded to a local file (in the temp dir), ready to preview
/// inline and optionally save to Photos.
public struct DownloadedMedia: Equatable {
    public let fileURL: URL
    public let kind: MediaAsset.Kind

    public init(fileURL: URL, kind: MediaAsset.Kind) {
        self.fileURL = fileURL
        self.kind = kind
    }
}

/// Disk location for transient downloaded media files. Durable Downloader saves
/// move into `SavedMediaStore`; this temp directory is only for previews and
/// in-flight foreground work.
public enum MediaDownloadStorage {

    /// The dedicated media-downloads directory, created on demand.
    public static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    /// A fresh unique file URL inside `directory` with the given extension.
    public static func newFileURL(extension ext: String) -> URL {
        directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// A unique directory lets simultaneous intent exports use the same friendly
    /// filename without collisions while preserving that filename as the URL's
    /// final path component for Shortcuts and share destinations.
    public static func newIntentExportURL(fileName: String) -> URL {
        let exportDirectory = directory
            .appendingPathComponent("IntentExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory.appendingPathComponent(fileName)
    }

    /// Removes one unique intent/share export directory. The containment check
    /// keeps a malformed or unrelated URL from broadening the deletion target.
    public static func discardIntentExport(at fileURL: URL) {
        let exportsRoot = directory
            .appendingPathComponent("IntentExports", isDirectory: true)
            .standardizedFileURL
        let exportDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        guard exportDirectory.deletingLastPathComponent() == exportsRoot else { return }
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    /// Deletes every file in the media-downloads directory. Called once at app
    /// launch to reclaim orphans from a previous run that was terminated before its
    /// preview view controller could delete its own file.
    public static func purgeAll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}

/// Orchestrates resolve → download → save for a social post's first media item.
public protocol MediaDownloading {
    /// Resolves the post's media, downloads the FIRST item, and saves it to Photos.
    /// Reports coarse 0…1 progress via `onProgress`. Returns the saved item's kind;
    /// throws `MediaDownloadError` on any failure.
    func downloadFirstMediaToPhotos(
        from url: URL, onProgress: @escaping (Double) -> Void
    ) async throws -> MediaAsset.Kind

    /// Resolves the post's media, downloads the FIRST item, and moves it into
    /// Luna Downloader's app-owned saved-media library.
    func downloadFirstMediaToAppStorage(
        from url: URL, title: String?, onProgress: @escaping (Double) -> Void
    ) async throws -> SavedMediaItem

    /// Resolves the post's media and downloads the FIRST item to a local file
    /// WITHOUT saving to Photos (so the action extension can show it inline and let
    /// the user decide whether to keep it). Streams to disk for memory safety.
    /// Reports coarse 0…1 progress; throws `MediaDownloadError` on any failure.
    func downloadFirstMediaToFile(
        from url: URL, onProgress: @escaping (Double) -> Void
    ) async throws -> DownloadedMedia

    /// Saves an already-downloaded media file to Photos (add-only). Requests
    /// authorization first; throws `MediaDownloadError` on failure.
    func saveDownloadedMediaToPhotos(_ media: DownloadedMedia) async throws -> String
}
