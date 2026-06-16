//
//  ArticleFetcher.swift
//  Clip
//

import Foundation

/// Downloads raw HTML for a weblink. Requests with a Googlebot user agent first —
/// many soft paywalls serve full content to crawlers and never trigger without
/// JavaScript — and falls back to a regular Safari user agent.
struct ArticleFetcher {
    static let googlebotUserAgent =
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    /// Cap on the HTML we hold in memory. Real article pages are far smaller;
    /// this keeps a mis-served large file or huge page from pushing the
    /// memory-limited share/action extension into jetsam.
    static let maxBytes = 8 * 1024 * 1024

    enum FetchError: Error {
        case badResponse
        case notHTML
        case tooLarge
    }

    func fetchHTML(from url: URL) async throws -> String {
        do {
            return try await fetch(url: url, userAgent: Self.googlebotUserAgent)
        } catch {
            return try await fetch(url: url, userAgent: Self.safariUserAgent)
        }
    }

    private func fetch(url: URL, userAgent: String) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse
        }
        // A server that declares an oversized body (a mis-served large file) is
        // rejected outright. For everything else, bound the page we parse so the
        // memory-limited extension can't be pushed into jetsam by a huge page.
        if http.expectedContentLength > Int64(Self.maxBytes) {
            throw FetchError.tooLarge
        }
        let bounded = data.count > Self.maxBytes ? data.prefix(Self.maxBytes) : data
        guard let html = String(data: bounded, encoding: .utf8)
            ?? String(data: bounded, encoding: .isoLatin1)
        else { throw FetchError.notHTML }
        return html
    }
}
