//
//  BlueskySearchClient.swift
//  Luna
//

import LunaURLClassification
import Foundation

/// Searches Bluesky posts (keyless public API) and returns the top match's web
/// URL. Used by `PlatformFieldSave`'s Bluesky route.
public struct BlueskySearchClient {
    public struct NoResultError: Error {}

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private struct SearchResponse: Decodable {
        let posts: [Post]
        struct Post: Decodable {
            let uri: String
            let author: Author
        }
        struct Author: Decodable { let handle: String }
    }

    public func topPostURL(query: String) async throws -> URL {
        guard var components = URLComponents(
            string: "https://public.api.bsky.app/xrpc/app.bsky.feed.searchPosts") else {
            throw NoResultError()
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { throw NoResultError() }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NoResultError()
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let post = decoded.posts.first,
              let urlString = BlueskyLink.webURL(fromATURI: post.uri, authorHandle: post.author.handle),
              let postURL = URL(string: urlString)
        else { throw NoResultError() }
        return postURL
    }
}
