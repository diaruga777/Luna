//
//  BlueskyLink.swift
//  Luna
//

import Foundation

/// Recognizes Bluesky post links and converts between web URLs and AT-protocol
/// post references. Pure (no network).
public enum BlueskyLink {
    private static let hosts: Set<String> = ["bsky.app", "www.bsky.app"]

    public struct Post: Equatable {
        /// Handle or DID from the profile path segment.
        public let author: String
        /// Record key (the post id).
        public let rkey: String

        public init(author: String, rkey: String) {
            self.author = author
            self.rkey = rkey
        }
    }

    /// Parses `bsky.app/profile/<handle|did>/post/<rkey>`.
    public static func post(from urlString: String) -> Post? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              hosts.contains(host) else { return nil }
        let parts = url.pathComponents.dropFirst() // drop leading "/"
        let segments = Array(parts)
        guard segments.count >= 4, segments[0] == "profile", segments[2] == "post" else { return nil }
        let author = segments[1]
        let rkey = segments[3]
        guard !author.isEmpty, !rkey.isEmpty else { return nil }
        return Post(author: author, rkey: rkey)
    }

    /// Canonical web URL for an author handle + record key.
    public static func webURL(author: String, rkey: String) -> String {
        "https://bsky.app/profile/\(author)/post/\(rkey)"
    }

    /// Builds the web URL from a searchPosts result: an `at://did/app.bsky.feed.post/<rkey>`
    /// URI plus the author handle.
    public static func webURL(fromATURI uri: String, authorHandle: String) -> String? {
        guard let rkey = uri.split(separator: "/").last.map(String.init), !rkey.isEmpty else {
            return nil
        }
        return webURL(author: authorHandle, rkey: rkey)
    }
}
