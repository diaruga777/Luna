import Foundation
import LunaModels

public enum URLClassification {
    public static let trackingParameterNames: Set<String> = [
        "mod", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "igshid", "ref", "cmpid", "ocid", "spm", "smid",
    ]

    public static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        components.queryItems = components.queryItems?
            .filter { !trackingParameterNames.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    public static func youTubeVideoID(in url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" { return validatedVideoID(url.pathComponents.dropFirst().first) }
        let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]
        guard hosts.contains(host) else { return nil }
        let segments = url.pathComponents.dropFirst()
        switch segments.first {
        case "watch": return validatedVideoID(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value)
        case "shorts", "embed", "live", "v": return validatedVideoID(segments.dropFirst().first)
        default: return nil
        }
    }

    private static func validatedVideoID(_ id: String?) -> String? {
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }
}
