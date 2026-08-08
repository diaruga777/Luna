//
//  RedditSearchClient.swift
//  Luna
//

import Foundation
import LunaModels

/// Searches Reddit and returns the top post's permalink. Uses the public
/// `search.json` endpoint (no OAuth — best-effort, rate-limited).
public struct RedditSearchClient {
    public struct NoResultError: Error {}

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func topPostURL(query: String) async throws -> URL {
        guard var components = URLComponents(string: "https://www.reddit.com/search.json") else {
            throw NoResultError()
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "type", value: "link"),
        ]
        guard let url = components.url else { throw NoResultError() }
        try LiveNetworkPolicy.check(url, context: "RedditSearchClient")
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Luna/1.0 (reading list)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let listing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listingData = listing["data"] as? [String: Any],
              let children = listingData["children"] as? [[String: Any]],
              let postData = children.first?["data"] as? [String: Any],
              let permalink = postData["permalink"] as? String,
              let postURL = URL(string: "https://www.reddit.com\(permalink)")
        else { throw NoResultError() }
        return postURL
    }
}
