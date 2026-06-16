//
//  OpenGraphScraper.swift
//  Clip
//

import Foundation

/// Best-effort Open Graph metadata scrape (`og:title`, `og:image`,
/// `og:description`) over `URLSession`. Used for platforms with no free API
/// (Instagram, Facebook). Often blocked by login walls → returns nil, and the
/// caller falls back to the platform logo.
enum OpenGraphScraper {

    struct Metadata {
        var title: String?
        var imageURL: URL?
        var description: String?
    }

    static func fetch(urlString: String, session: URLSession = .shared) async -> Metadata? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        // A desktop UA gets fuller og: tags from some sites.
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let title = ogContent(property: "og:title", in: html)
        let image = ogContent(property: "og:image", in: html).flatMap(URL.init(string:))
        let description = ogContent(property: "og:description", in: html)
        if title == nil && image == nil && description == nil { return nil }
        return Metadata(title: title, imageURL: image, description: description)
    }

    /// Extracts the `content` of a `<meta property="og:…">` tag (order-tolerant).
    static func ogContent(property: String, in html: String) -> String? {
        // Match a <meta …> tag mentioning the property, then pull its content="…".
        let pattern = "<meta[^>]*property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*>"
        guard let tagRange = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let tag = String(html[tagRange])
        guard let contentRange = tag.range(
            of: "content=[\"']([^\"']*)[\"']", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let content = String(tag[contentRange])
        // Strip the content=" … " wrapper.
        guard let valueRange = content.range(of: "[\"']([^\"']*)[\"']", options: .regularExpression) else {
            return nil
        }
        let quoted = String(content[valueRange]).dropFirst().dropLast()
        let decoded = String(quoted)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded.isEmpty ? nil : decoded
    }
}
