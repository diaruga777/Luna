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

    /// The web URL a clip was launched to act on: a `url`/`source`/`sourceURL`/`u`
    /// query item, else the fragment, else the invocation URL itself.
    ///
    /// `destination` decides how loosely the two looser forms are read, and both
    /// restrictions are the Downloader's — see `SourceRules`.
    public static func sourceURL(from invocationURL: URL, for destination: Destination) -> URL? {
        guard let components = URLComponents(url: invocationURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let rules = SourceRules.rules(for: destination)

        for name in ["url", "source", "sourceURL", "u"] {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value,
               let url = URL(string: value),
               isWebURL(url) {
                return url
            }
        }

        if rules.fragmentPath.map({ invocationURL.path == $0 }) ?? true,
           let fragment = components.fragment?.removingPercentEncoding,
           let url = URL(string: fragment),
           isWebURL(url) {
            return url
        }

        guard isWebURL(invocationURL) else { return nil }
        if let rejectedHostSubstring = rules.rejectedHostSubstring,
           invocationURL.host?.localizedCaseInsensitiveContains(rejectedHostSubstring) != false {
            return nil
        }
        return invocationURL
    }

    /// How much benefit of the doubt a clip gives an invocation URL that carries
    /// its source informally.
    ///
    /// The Reader gives all of it: whatever it is handed, it tries to read. The
    /// Downloader is stricter on both counts, because a download is a fetch of
    /// the page's own media rather than a render of the page: it takes a FRAGMENT
    /// only on its own `/download` path, and it never treats a Luna host's URL as
    /// the thing to download — that is its own invocation page.
    private struct SourceRules {
        /// The path a source carried in the fragment is accepted on; nil accepts
        /// any path.
        var fragmentPath: String?
        /// A host substring that disqualifies the invocation URL from standing in
        /// as its own source; nil accepts any host.
        var rejectedHostSubstring: String?

        static func rules(for destination: Destination) -> SourceRules {
            switch destination {
            case .reader:
                return SourceRules()
            case .downloader:
                return SourceRules(fragmentPath: "/download", rejectedHostSubstring: "luna")
            }
        }
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
