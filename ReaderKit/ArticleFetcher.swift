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

    enum FetchError: Error {
        case badResponse
        case notHTML
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
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw FetchError.notHTML }
        return html
    }
}
