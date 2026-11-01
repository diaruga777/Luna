import Foundation

/// Carried inside the existing authenticated Music RPC. Jobs are polled so
/// extraction, Homebrew upgrades and downloads never occupy an RPC deadline.
public struct YouTubeAudioRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case availability, resolve, status, download, read, release }
    public var action: Action
    public var id: String
    public var url: String
    public var offset: Int64
    public var length: Int
    public var maximumBytes: Int64
    public init(_ action: Action, id: String = "", url: String = "", offset: Int64 = 0,
                length: Int = 0, maximumBytes: Int64 = 0) {
        self.action = action; self.id = id; self.url = url; self.offset = offset
        self.length = length; self.maximumBytes = maximumBytes
    }
}

public struct YouTubeAudioMetadata: Codable, Equatable, Sendable {
    public var videoID: String
    public var title: String
    public var author: String
    public var duration: Double
    public var downloadURL: URL
    public var headers: [String: String]
    public init(videoID: String, title: String, author: String, duration: Double,
                downloadURL: URL, headers: [String: String]) {
        self.videoID = videoID; self.title = title; self.author = author; self.duration = duration
        self.downloadURL = downloadURL; self.headers = headers
    }
}

public struct YouTubeAudioResponse: Codable, Sendable {
    public enum State: String, Codable, Sendable { case resolving, resolved, downloading, ready, failed }
    public var available: Bool?
    public var state: State?
    public var metadata: YouTubeAudioMetadata?
    public var size: Int64?
    public var data: Data?
    public var error: String?
    public init(available: Bool? = nil, state: State? = nil, metadata: YouTubeAudioMetadata? = nil,
                size: Int64? = nil, data: Data? = nil, error: String? = nil) {
        self.available = available; self.state = state; self.metadata = metadata
        self.size = size; self.data = data; self.error = error
    }
}

public enum YouTubeAudioURL {
    /// Strip sharing/tracking/playlist parameters and pass only a canonical
    /// single-video URL to the executable. No shell or arbitrary-site input.
    public static func videoID(_ input: String) -> String? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let id: String?
        if ["youtu.be", "www.youtu.be"].contains(host), parts.count == 1 { id = parts.first }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) {
            if parts == ["watch"] {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count == 2, ["shorts", "live", "embed", "v"].contains(parts[0]) { id = parts[1] }
            else { id = nil }
        } else { id = nil }
        guard let id, id.utf8.count == 11,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return id
    }
    public static func canonical(_ id: String) -> URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// Only server/media rejection warrants a second download from the Mac.
/// Connectivity, cancellation, policy and local filesystem errors do not.
public struct YouTubeMediaRejection: LocalizedError {
    public var errorDescription: String? { "YouTube didn’t return playable audio." }
    public init() {}
}
public enum YouTubeAudioFailurePolicy {
    public static func shouldUseMac(_ error: Error) -> Bool {
        if error is YouTubeMediaRejection { return true }
        guard let error = error as? URLError else { return false }
        return [.badServerResponse, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse].contains(error.code)
    }
}
