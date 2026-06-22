import Foundation

public enum PaywallBypassRules {
    public static func trailingDotURL(for url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty, !host.hasSuffix(".") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host + "."
        return components?.url
    }

    public static func isNYTHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "nytimes.com" || host.hasSuffix(".nytimes.com")
            || host == "nyt.com" || host.hasSuffix(".nyt.com")
    }
}
