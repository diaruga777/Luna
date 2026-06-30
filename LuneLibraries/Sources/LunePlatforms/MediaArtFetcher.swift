//
//  MediaArtFetcher.swift
//  Lune
//

import Foundation

/// Fetches album / podcast cover art from the keyless iTunes Search API by
/// artist+title — works regardless of the source service (the user asked for
/// "any online database"). Used for URL-less media items (the OCR intents) and
/// received media shares, which have no source URL to oEmbed.
public enum MediaArtFetcher {

    private struct SearchResult: Decodable {
        let results: [Entry]
        struct Entry: Decodable { let artworkUrl100: String? }
    }

    /// Best-effort 600px artwork bytes for a creator + title, or nil.
    public static func fetchArtwork(creator: String, title: String, isPodcast: Bool) async -> Data? {
        let term = "\(creator) \(title)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: isPodcast ? "podcast" : "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResult.self, from: data),
              let art = decoded.results.first?.artworkUrl100,
              let artURL = URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
        else { return nil }
        return try? await URLSession.shared.data(from: artURL).0
    }
}
