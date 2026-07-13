//
//  MediaDownload.swift
//  Luna
//

import LunaURLClassification
import LunaModels
import LunaStorage
import Foundation

/// A single downloadable media item resolved from a social post.
public struct MediaAsset: Equatable {
    /// What the file is, which decides how it's saved to Photos and its extension.
    public enum Kind: String, Codable, Equatable {
        case image   // still photo (jpg/png)
        case gif     // animated GIF
        case video   // mp4 (Twitter "GIFs" are mp4s and resolve as .video)
    }
    public let url: URL
    public let kind: Kind
    /// A separate audio-only stream to mux with `url`, for platforms (Reddit)
    /// that host video and audio as two independent files rather than one
    /// playable URL. `nil` for every other platform's single-URL assets.
    public let audioURL: URL?
    /// The DASH manifest listing `audioURL`'s real location — `audioURL` itself
    /// is a filename-convention guess (Reddit doesn't hand back the audio URL
    /// directly), so this is the authoritative fallback `RedditAudioFetcher`
    /// consults if that guess (and a second, legacy-convention guess) both
    /// fail to actually download. `nil` for every non-Reddit asset.
    public let dashManifestURL: URL?

    public init(url: URL, kind: Kind, audioURL: URL? = nil, dashManifestURL: URL? = nil) {
        self.url = url
        self.kind = kind
        self.audioURL = audioURL
        self.dashManifestURL = dashManifestURL
    }
}

/// Why a media download failed, with a user-facing message.
public enum MediaDownloadError: Error {
    case unsupported      // not an X / Instagram / TikTok / Facebook post
    case noMedia          // the post had no downloadable media
    case permissionDenied // Photos add access not granted
    case downloadFailed   // the media file couldn't be fetched
    case saveFailed       // PhotoKit rejected the save

    /// A short message suitable for a toast / status label.
    public var message: String {
        switch self {
        case .unsupported: return "This link has no downloadable media."
        case .noMedia: return "Couldn't find media to download."
        case .permissionDenied: return "Allow Photos access in Settings to save media."
        case .downloadFailed: return "Couldn't download the media."
        case .saveFailed: return "Couldn't save to your photo library."
        }
    }
}

/// Which platforms support direct media download to Photos. The two entry points
/// (the action extension's "Download media to photo roll" button and the reading
/// list row's long-press menu) both gate on this.
public enum MediaDownloadablePlatform {
    /// The platforms whose posts expose downloadable still/gif/video media.
    public static let supported: Set<ContentPlatform> = [.x, .instagram, .tiktok, .facebook, .reddit]

    /// Whether `urlString` is a post on a platform we can pull media from.
    public static func supports(_ urlString: String) -> Bool {
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return supported.contains(platform)
    }
}

/// Resolves the direct, downloadable media asset(s) for a social post URL.
public protocol SocialMediaResolving {
    /// Returns the post's media assets in display order, or an empty array when the
    /// URL is unsupported or no media could be resolved.
    func resolveAssets(for url: URL) async -> [MediaAsset]
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
