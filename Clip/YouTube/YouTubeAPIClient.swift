//
//  YouTubeAPIClient.swift
//  Clip
//

import Foundation

/// A search hit (video ID + title).
struct YouTubeSearchResult: Equatable {
    let videoID: String
    let title: String
}

/// One of the user's playlists.
struct YouTubePlaylist: Equatable {
    let id: String
    let title: String
}

/// The slice of the YouTube Data API v3 Clip uses, OAuth-authenticated.
protocol YouTubeAPIProviding {
    /// Top channel matching a free-text name, or nil when none.
    func searchChannelID(name: String) async throws -> String?
    /// Videos on a channel matching a query (relevance order).
    func searchVideos(channelID: String, query: String) async throws -> [YouTubeSearchResult]
    /// The signed-in user's playlists.
    func listMyPlaylists() async throws -> [YouTubePlaylist]
    /// Creates a new private playlist.
    func createPlaylist(title: String) async throws -> YouTubePlaylist
    /// Appends a video to a playlist.
    func addToPlaylist(playlistID: String, videoID: String) async throws
}

/// Live client against googleapis.com using `GoogleAuthProviding` tokens.
final class YouTubeAPIClient: YouTubeAPIProviding {

    struct APIError: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    private let auth: GoogleAuthProviding
    private let baseURL = "https://www.googleapis.com/youtube/v3"

    init(auth: GoogleAuthProviding = GoogleAuthClient.shared) {
        self.auth = auth
    }

    func searchChannelID(name: String) async throws -> String? {
        let data = try await get("/search", query: [
            "part": "snippet", "type": "channel", "q": name, "maxResults": "1",
        ])
        struct Wire: Decodable {
            struct Item: Decodable {
                struct ID: Decodable { let channelId: String? }
                let id: ID
            }
            let items: [Item]
        }
        return try JSONDecoder().decode(Wire.self, from: data).items.first?.id.channelId
    }

    func searchVideos(channelID: String, query: String) async throws -> [YouTubeSearchResult] {
        let data = try await get("/search", query: [
            "part": "snippet", "type": "video", "channelId": channelID,
            "q": query, "maxResults": "25",
        ])
        struct Wire: Decodable {
            struct Item: Decodable {
                struct ID: Decodable { let videoId: String? }
                struct Snippet: Decodable { let title: String }
                let id: ID
                let snippet: Snippet
            }
            let items: [Item]
        }
        return try JSONDecoder().decode(Wire.self, from: data).items.compactMap { item in
            guard let videoID = item.id.videoId else { return nil }
            // Search results HTML-escape titles.
            return YouTubeSearchResult(
                videoID: videoID, title: Self.htmlUnescaped(item.snippet.title))
        }
    }

    func listMyPlaylists() async throws -> [YouTubePlaylist] {
        let data = try await get("/playlists", query: [
            "part": "snippet", "mine": "true", "maxResults": "50",
        ])
        struct Wire: Decodable {
            struct Item: Decodable {
                struct Snippet: Decodable { let title: String }
                let id: String
                let snippet: Snippet
            }
            let items: [Item]
        }
        return try JSONDecoder().decode(Wire.self, from: data).items
            .map { YouTubePlaylist(id: $0.id, title: $0.snippet.title) }
    }

    func createPlaylist(title: String) async throws -> YouTubePlaylist {
        let body: [String: Any] = [
            "snippet": ["title": title],
            "status": ["privacyStatus": "private"],
        ]
        let data = try await post("/playlists", query: ["part": "snippet,status"], body: body)
        struct Wire: Decodable {
            struct Snippet: Decodable { let title: String }
            let id: String
            let snippet: Snippet
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return YouTubePlaylist(id: wire.id, title: wire.snippet.title)
    }

    func addToPlaylist(playlistID: String, videoID: String) async throws {
        let body: [String: Any] = [
            "snippet": [
                "playlistId": playlistID,
                "resourceId": ["kind": "youtube#video", "videoId": videoID],
            ],
        ]
        _ = try await post("/playlistItems", query: ["part": "snippet"], body: body)
    }

    // MARK: - HTTP plumbing

    private func get(_ path: String, query: [String: String]) async throws -> Data {
        try await send(path: path, query: query, method: "GET", body: nil)
    }

    private func post(_ path: String, query: [String: String], body: [String: Any]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await send(path: path, query: query, method: "POST", body: bodyData)
    }

    private func send(
        path: String, query: [String: String], method: String, body: Data?
    ) async throws -> Data {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw APIError(reason: "bad URL") }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(
                reason: "YouTube API error: \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        return data
    }

    private static func htmlUnescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Picks the saved video from search results, leniently: normalized exact →
/// either-direction prefix → substring → all-query-words-present → top result.
/// Normalization lowercases, strips punctuation/ellipsis, and collapses
/// whitespace so truncated/messy share text still matches. Pure, tested.
enum VideoMatchSelection {
    static func bestMatch(
        title: String, candidates: [YouTubeSearchResult]
    ) -> YouTubeSearchResult? {
        guard !candidates.isEmpty else { return nil }
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return candidates.first }

        let normalized = candidates.map { (candidate: $0, key: normalize($0.title)) }

        if let exact = normalized.first(where: { $0.key == wanted }) {
            return exact.candidate
        }
        if let prefix = normalized.first(where: {
            $0.key.hasPrefix(wanted) || wanted.hasPrefix($0.key)
        }) {
            return prefix.candidate
        }
        if let substring = normalized.first(where: { $0.key.contains(wanted) }) {
            return substring.candidate
        }
        let wantedWords = wanted.split(separator: " ").map(String.init)
        if let allWords = normalized.first(where: { entry in
            wantedWords.allSatisfy { entry.key.contains($0) }
        }) {
            return allWords.candidate
        }
        return candidates.first
    }

    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
