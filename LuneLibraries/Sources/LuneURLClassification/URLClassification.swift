import Foundation
import LuneModels

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

    public static func platform(for url: URL) -> (platform: ContentPlatform, itemID: String?, provider: MusicProvider?)? {
        guard let host = url.host?.lowercased() else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "youtu.be" || host.hasSuffix(".youtube.com") || host == "youtube.com" {
            guard let id = youTubeVideoID(in: url) else { return nil }
            return (.youtube, id, nil)
        }
        if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") {
            let index = segments.firstIndex { $0 == "status" || $0 == "statuses" }
            let id = index.flatMap { segments.indices.contains($0 + 1) ? segments[$0 + 1] : nil }
            return (.x, id?.allSatisfy(\.isNumber) == true ? id : nil, nil)
        }
        if host == "bsky.app", let index = segments.firstIndex(of: "profile"), segments.count > index + 3, segments[index + 2] == "post" {
            return (.bluesky, segments[index + 3], nil)
        }
        if host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it" {
            let index = segments.firstIndex(of: "comments")
            return (.reddit, index.flatMap { segments.indices.contains($0 + 1) ? segments[$0 + 1] : nil } ?? (host == "redd.it" ? segments.first : nil), nil)
        }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") { return (.tiktok, pathID(after: "video", in: segments), nil) }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") || host == "instagr.am" { return (.instagram, segments.drop { !$0.isEmpty }.dropFirst().first, nil) }
        if host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "fb.watch" || host == "fb.com" {
            return (.facebook, query.first(where: { $0.name == "v" })?.value ?? pathID(after: "reel", in: segments) ?? pathID(after: "videos", in: segments), nil)
        }
        if host.hasSuffix("spotify.com") {
            guard let kind = segments.first, let id = segments.dropFirst().first else { return nil }
            return (["episode", "show"].contains(kind) ? .podcast : .music, id, .spotify)
        }
        if host == "music.apple.com" { return (.music, query.first(where: { $0.name == "i" })?.value ?? segments.last, .apple) }
        if host == "podcasts.apple.com" { return (.podcast, query.first(where: { $0.name == "i" })?.value ?? segments.last, .apple) }
        return nil
    }

    private static func pathID(after marker: String, in segments: [String]) -> String? {
        guard let index = segments.firstIndex(of: marker), segments.indices.contains(index + 1) else { return nil }
        return segments[index + 1]
    }

    private static func validatedVideoID(_ id: String?) -> String? {
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }
}
