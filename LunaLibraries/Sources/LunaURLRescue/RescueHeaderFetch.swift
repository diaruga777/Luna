//
//  RescueHeaderFetch.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch

/// A one-shot URLSession fetch that applies a directive's validated
/// `RescueHeaders`. Used when a reroute needs a header combination the existing
/// `HTMLFetching` variants don't express. Mirrors `ArticleFetcher.fetch`: Safari
/// UA default, byte cap, HTML content-type check, bounded timeout.
enum RescueHeaderFetch {
    static let timeout: TimeInterval = 15

    static func fetchHTML(url: URL, headers: RescueHeaders) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(headers.userAgent ?? ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        if let referer = headers.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let lang = headers.acceptLanguage { request.setValue(lang, forHTTPHeaderField: "Accept-Language") }
        if let xff = headers.xForwardedFor { request.setValue(xff, forHTTPHeaderField: "X-Forwarded-For") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= ArticleFetcher.maxBytes else { return nil }
        // Best-effort HTML gate: accept when the content-type is missing or html/xml.
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !contentType.isEmpty,
           !(contentType.contains("html") || contentType.contains("xml") || contentType.contains("text/plain")) {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
