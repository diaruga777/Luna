//
//  YouTubeURL.swift
//  Luna
//

import Foundation

/// Recognizes YouTube video links and extracts the video ID.
public enum YouTubeURL {

    private static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// The video ID, or nil when the URL isn't a YouTube video link.
    public static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return URLClassification.youTubeVideoID(in: url)
    }

    /// Standard watch URL for a video ID.
    public static func watchURLString(videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }

    /// Deep link into the YouTube app.
    public static func appURL(videoID: String) -> URL? {
        URL(string: "youtube://watch?v=\(videoID)")
    }

    /// Highest-availability thumbnail (exists for every video).
    public static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Video IDs are 11 URL-safe-base64-ish characters; reject anything odd.
    private static func validated(_ candidate: String?) -> String? {
        guard let candidate,
              candidate.count == 11,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }
}
