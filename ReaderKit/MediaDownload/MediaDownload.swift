//
//  MediaDownload.swift
//  Clip
//

import Foundation

/// A single downloadable media item resolved from a social post.
struct MediaAsset: Equatable {
    /// What the file is, which decides how it's saved to Photos and its extension.
    enum Kind: Equatable {
        case image   // still photo (jpg/png)
        case gif     // animated GIF
        case video   // mp4 (Twitter "GIFs" are mp4s and resolve as .video)
    }
    let url: URL
    let kind: Kind
}

/// Why a media download failed, with a user-facing message.
enum MediaDownloadError: Error {
    case unsupported      // not an X / Instagram / TikTok / Facebook post
    case noMedia          // the post had no downloadable media
    case permissionDenied // Photos add access not granted
    case downloadFailed   // the media file couldn't be fetched
    case saveFailed       // PhotoKit rejected the save

    /// A short message suitable for a toast / status label.
    var message: String {
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
enum MediaDownloadablePlatform {
    /// The platforms whose posts expose downloadable still/gif/video media.
    static let supported: Set<ContentPlatform> = [.x, .instagram, .tiktok, .facebook]

    /// Whether `urlString` is a post on a platform we can pull media from.
    static func supports(_ urlString: String) -> Bool {
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return supported.contains(platform)
    }
}

/// Resolves the direct, downloadable media asset(s) for a social post URL.
protocol SocialMediaResolving {
    /// Returns the post's media assets in display order, or an empty array when the
    /// URL is unsupported or no media could be resolved.
    func resolveAssets(for url: URL) async -> [MediaAsset]
}

/// Saves a downloaded media file to the user's photo library.
protocol PhotoLibrarySaving {
    /// Requests add-only Photos authorization, returning whether it's granted.
    func requestAddAuthorization() async -> Bool
    /// Saves the file at `fileURL` (of the given kind) to the photo library.
    func save(fileURL: URL, kind: MediaAsset.Kind) async throws
}

/// Orchestrates resolve → download → save for a social post's first media item.
protocol MediaDownloading {
    /// Resolves the post's media, downloads the FIRST item, and saves it to Photos.
    /// Reports coarse 0…1 progress via `onProgress`. Returns the saved item's kind;
    /// throws `MediaDownloadError` on any failure.
    func downloadFirstMediaToPhotos(
        from url: URL, onProgress: @escaping (Double) -> Void
    ) async throws -> MediaAsset.Kind
}
