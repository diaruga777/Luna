//
//  PluginBrowserModels.swift
//  LunaPluginUI
//

import Foundation

/// One `luna.browser.open` call (`claudedocs/plans/plugin-platform.md` §6.10).
///
/// It is `Codable` because a request outlives the process that made it: an
/// extension writes it into `plugin_browser_requests` and the app reads it back
/// to present the modal, so the field names here ARE the stored shape.
public struct PluginBrowserRequest: Equatable, Codable, Sendable {

    /// Which cookie jar the page runs against.
    public enum CookieStore: String, Codable, Sendable {
        case persistent, ephemeral
    }

    /// The default the modal closes itself after.
    public static let defaultTimeout: TimeInterval = 300

    /// The two headers a plugin may set. Everything else is the browser's own
    /// business, and a plugin that could write `User-Agent` here would defeat
    /// `userAgent`.
    public static let allowedHeaders = ["referer", "accept-language"]

    /// The `userAgent` value that asks for the device-matched Safari UA. It is
    /// also the default.
    public static let deviceSafariUserAgent = "device-safari"

    public let url: URL
    /// Nil, or `device-safari`, means the device-matched Safari UA.
    public let userAgent: String?
    public let headers: [String: String]
    public let cookies: CookieStore
    /// JS evaluated in the page every tick. It must answer
    /// `"wait" | "challenge" | "done" | "error"`.
    public let detect: String
    public let title: String?
    public let timeout: TimeInterval

    public init(
        url: URL, userAgent: String? = nil, headers: [String: String] = [:],
        cookies: CookieStore = .persistent, detect: String, title: String? = nil,
        timeout: TimeInterval = PluginBrowserRequest.defaultTimeout
    ) {
        self.url = url
        self.userAgent = userAgent
        self.headers = PluginBrowserRequest.allowed(headers)
        self.cookies = cookies
        self.detect = detect
        self.title = title
        self.timeout = timeout
    }

    /// Reads the object a plugin passed. Nil for a request Luna cannot act on:
    /// no URL, or no probe to read the page with.
    public init?(jsObject object: [String: Any]) {
        guard let urlText = object["url"] as? String, let url = URL(string: urlText),
              url.scheme?.hasPrefix("http") == true,
              let detect = object["detect"] as? String, !detect.isEmpty
        else { return nil }
        let timeout = (object["timeout"] as? NSNumber)?.doubleValue
        self.init(
            url: url,
            userAgent: object["userAgent"] as? String,
            headers: (object["headers"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:],
            cookies: (object["cookies"] as? String)
                .flatMap(CookieStore.init(rawValue:)) ?? .persistent,
            detect: detect,
            title: object["title"] as? String,
            timeout: timeout.map { max(5, min($0, 900)) } ?? PluginBrowserRequest.defaultTimeout)
    }

    public init?(json: String) {
        guard let decoded = try? JSONDecoder().decode(
            PluginBrowserRequest.self, from: Data(json.utf8))
        else { return nil }
        self = decoded
    }

    public var jsonText: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when `other` asks for the same page, so a stored answer may serve
    /// it. The probe may differ — a resumed run often looks for the unlocked
    /// page rather than the challenge.
    public func addressesSamePage(as other: PluginBrowserRequest) -> Bool {
        url == other.url
    }

    private static func allowed(_ headers: [String: String]) -> [String: String] {
        headers.filter { allowedHeaders.contains($0.key.lowercased()) }
    }
}

/// What the browser step produced (§6.10).
public struct PluginBrowserResult: Equatable, Codable, Sendable {

    /// The cap on `html`. A page past it is truncated rather than refused: the
    /// plugin asked for a page, and 6 MB of it is more than any extractor reads.
    public static let maxHTMLBytes = 6 * 1024 * 1024

    public struct Cookie: Equatable, Codable, Sendable {
        public let name: String
        public let value: String
        public let domain: String

        public init(name: String, value: String, domain: String) {
            self.name = name
            self.value = value
            self.domain = domain
        }
    }

    public let url: String
    public let html: String
    public let title: String
    public let cookieHeader: String
    public let cookies: [Cookie]

    public init(
        url: String, html: String, title: String, cookieHeader: String, cookies: [Cookie]
    ) {
        self.url = url
        self.html = PluginBrowserResult.capped(html)
        self.title = title
        self.cookieHeader = cookieHeader
        self.cookies = cookies
    }

    public init?(json: String) {
        guard let decoded = try? JSONDecoder().decode(
            PluginBrowserResult.self, from: Data(json.utf8))
        else { return nil }
        self = decoded
    }

    public var jsonText: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The shape the plugin receives.
    public var jsObject: [String: Any] {
        [
            "url": url,
            "html": html,
            "title": title,
            "cookieHeader": cookieHeader,
            "cookies": cookies.map {
                ["name": $0.name, "value": $0.value, "domain": $0.domain]
            },
        ]
    }

    /// Truncates on a character boundary at or under the byte cap.
    static func capped(_ html: String) -> String {
        guard html.utf8.count > maxHTMLBytes else { return html }
        var kept = ""
        var bytes = 0
        for character in html {
            let size = String(character).utf8.count
            if bytes + size > maxHTMLBytes { break }
            kept.append(character)
            bytes += size
        }
        return kept
    }
}
