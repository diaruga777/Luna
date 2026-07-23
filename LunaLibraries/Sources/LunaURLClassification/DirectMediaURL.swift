import Foundation

/// URL-only recognition for files that are already media assets rather than web
/// pages which need a platform resolver. Keeping this in the low-level URL
/// classification module lets ingestion and downloading make the same decision.
public enum DirectMediaKind: String, Equatable, Sendable {
    case image
    case gif
    case video
    case audio
}

public enum DirectMediaURL {
    private static let imageExtensions: Set<String> = [
        "avif", "heic", "heif", "jpeg", "jpg", "png", "webp",
    ]
    private static let videoExtensions: Set<String> = [
        "m4v", "mov", "mp4",
    ]
    private static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav",
    ]

    /// Recognizes an HTTP(S) URL whose final path component names a media file.
    /// Query strings and fragments do not affect `pathExtension`, so signed CDN
    /// links such as `clip.mp4?token=…` remain recognizable.
    public static func kind(for url: URL) -> DirectMediaKind? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return .gif }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    public static func kind(for urlString: String) -> DirectMediaKind? {
        URL(string: urlString).flatMap(kind(for:))
    }
}
