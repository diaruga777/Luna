//
//  PluginParsedURL.swift
//  LunaPluginRuntime
//

import Foundation

/// The value `luna.parseURL(url[, base])` hands a plugin (§6.1).
///
/// A bare `JSContext` has no `URL` and no `URLSearchParams` — they are DOM
/// globals WebKit adds to a page, not part of the language JavaScriptCore
/// ships, so `new URL(…)` throws `ReferenceError`. Every plugin parses a URL to
/// do its one job, so the runtime installs this OUTSIDE the capability gate.
///
/// Field semantics follow the browser `URL` a plugin author expects: `pathname`
/// and `search` stay percent-encoded, and query values are decoded with `+`
/// read as a space (`URLSearchParams` semantics, which `URLComponents` does not
/// do on its own).
public struct PluginParsedURL: Equatable, Sendable {

    public struct QueryPair: Equatable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// The absolute URL, resolved against the base when one was given.
    public let href: String
    /// The scheme with its colon, as `URL.protocol` reads in a browser.
    public let scheme: String
    /// Host with the port when the URL states one, as `URL.host` reads.
    public let host: String
    public let hostname: String
    /// The stated port as a string, or the empty string.
    public let port: String
    /// Percent-encoded path, `/` when the URL states none.
    public let pathname: String
    /// Percent-encoded query with its leading `?`, or the empty string.
    public let search: String
    /// Decoded query pairs in source order, duplicates kept.
    public let queryPairs: [QueryPair]
    /// Fragment WITH its leading `#`, or the empty string — what `URL.hash`
    /// reads in a browser.
    public let hash: String

    public static func parse(_ urlString: String, relativeTo base: String? = nil)
        -> PluginParsedURL?
    {
        let resolved: URL?
        if let base, !base.isEmpty, let baseURL = URL(string: base) {
            resolved = URL(string: urlString, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: urlString)
        }
        guard let url = resolved,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let hostname = components.host?.lowercased(),
              !hostname.isEmpty
        else { return nil }

        let encodedPath = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        let encodedQuery = components.percentEncodedQuery
        let portText = components.port.map(String.init) ?? ""
        let fragment = components.percentEncodedFragment ?? ""

        return PluginParsedURL(
            href: url.absoluteString,
            scheme: "\(scheme):",
            host: portText.isEmpty ? hostname : "\(hostname):\(portText)",
            hostname: hostname,
            port: portText,
            pathname: encodedPath,
            search: encodedQuery.map { $0.isEmpty ? "" : "?\($0)" } ?? "",
            queryPairs: Self.queryPairs(from: encodedQuery),
            hash: fragment.isEmpty ? "" : "#\(formDecode(fragment))")
    }

    /// First value per name — what a check like `?v=` wants.
    public func first(_ name: String) -> String? {
        queryPairs.first { $0.name == name }?.value
    }

    public func all(_ name: String) -> [String] {
        queryPairs.filter { $0.name == name }.map(\.value)
    }

    private static func queryPairs(from encodedQuery: String?) -> [QueryPair] {
        guard let encodedQuery, !encodedQuery.isEmpty else { return [] }
        return encodedQuery.split(separator: "&", omittingEmptySubsequences: true).map { field in
            guard let separator = field.firstIndex(of: "=") else {
                return QueryPair(name: formDecode(String(field)), value: "")
            }
            return QueryPair(
                name: formDecode(String(field[field.startIndex..<separator])),
                value: formDecode(String(field[field.index(after: separator)...])))
        }
    }

    /// `URLSearchParams` reads `+` as a space before percent-decoding.
    /// `URLComponents.queryItems` does not, so the decode is done here.
    private static func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
