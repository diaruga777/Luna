//
//  LunaAppClipInvocationURL.swift
//  LunaURLClassification
//

import Foundation

/// Builds Luna App Clip invocation URLs once App Store Connect supplies a real
/// Advanced App Clip Experience URL. Before then callers can pass an empty base
/// URL and fall back to the original web URL.
public enum LunaAppClipInvocationURL {
    public enum Destination {
        case reader
        case downloader
    }

    public static func sourceURL(from invocationURL: URL) -> URL? {
        guard let components = URLComponents(url: invocationURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        for name in ["url", "source", "sourceURL", "u"] {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value,
               let url = URL(string: value),
               isWebURL(url) {
                return url
            }
        }

        if let fragment = components.fragment?.removingPercentEncoding,
           let url = URL(string: fragment),
           isWebURL(url) {
            return url
        }

        return isWebURL(invocationURL) ? invocationURL : nil
    }

    public static func invocationURL(baseURL: String, sourceURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let source = URL(string: sourceURL),
              isWebURL(source)
        else { return nil }

        if var components = URLComponents(string: trimmed) {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { ["url", "source", "sourceURL", "u"].contains($0.name) }
            queryItems.append(URLQueryItem(name: "url", value: source.absoluteString))
            components.queryItems = queryItems
            if let url = components.url { return url }
        }

        let join = trimmed.contains("?") ? "&" : "?"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return URL(string: trimmed + join + "url=" + source.absoluteString.addingPercentEncoding(
            withAllowedCharacters: allowed
        ).orEmpty)
    }

    public static func shareURL(
        for sourceURL: String,
        destination: Destination,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL? {
        let key: String
        switch destination {
        case .reader: key = "LunaReaderAppClipURL"
        case .downloader: key = "LunaDownloaderAppClipURL"
        }
        guard let baseURL = infoDictionary[key] as? String else { return nil }
        return invocationURL(baseURL: baseURL, sourceURL: sourceURL)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
