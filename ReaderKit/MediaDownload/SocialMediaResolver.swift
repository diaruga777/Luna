//
//  SocialMediaResolver.swift
//  Clip
//

import Foundation

/// Resolves a social post URL to its downloadable media, using keyless,
/// client-side techniques mirroring public web downloaders:
///   • X      — the keyless fxtwitter JSON API (`media.all` → photo/video/gif).
///   • TikTok — the page's `__UNIVERSAL_DATA_FOR_REHYDRATION__` JSON
///              (`playAddr` video, or `imagePost` photo carousel).
///   • Instagram — the post/embed HTML (`video_url` / `display_url` / og tags).
/// Network fetching is injectable so the per-platform PARSERS can be unit-tested
/// against fixtures without hitting the network.
struct SocialMediaResolver: SocialMediaResolving {

    typealias Fetch = (URLRequest) async -> Data?
    private let fetch: Fetch

    init(fetch: @escaping Fetch = SocialMediaResolver.defaultFetch) {
        self.fetch = fetch
    }

    func resolveAssets(for url: URL) async -> [MediaAsset] {
        guard let classification = PlatformClassifier.classify(url.absoluteString) else { return [] }
        switch classification.platform {
        case .x:
            return await resolveX(id: classification.itemID)
        case .tiktok:
            return await resolveTikTok(url: url)
        case .instagram:
            return await resolveInstagram(url: url, shortcode: classification.itemID)
        default:
            return []
        }
    }

    // MARK: - Per-platform resolution

    private func resolveX(id: String?) async -> [MediaAsset] {
        guard let id, let url = URL(string: "https://api.fxtwitter.com/status/\(id)") else { return [] }
        guard let data = await fetch(jsonRequest(url)) else { return [] }
        return XMediaParser.assets(fromFxJSON: data)
    }

    private func resolveTikTok(url: URL) async -> [MediaAsset] {
        // The full watch page carries the rehydration JSON with the media URLs.
        guard let data = await fetch(htmlRequest(url)),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return TikTokMediaParser.assets(fromHTML: html)
    }

    private func resolveInstagram(url: URL, shortcode: String?) async -> [MediaAsset] {
        // Post page FIRST — it exposes `og:video` for video posts. The embed page
        // only carries the poster image, so trying it first would save a still from
        // a video (the bug this fixes). A crawler UA reliably gets the og preview.
        var assets: [MediaAsset] = []
        if let data = await fetch(metaScrapeRequest(url)),
           let html = String(data: data, encoding: .utf8) {
            assets = InstagramMediaParser.assets(fromHTML: html)
        }
        if assets.contains(where: { $0.kind == .video }) { return assets }

        // Embed fallback (sometimes carries a `video_url`, otherwise the image).
        if let code = shortcode,
           let embed = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/"),
           let data = await fetch(htmlRequest(embed)),
           let html = String(data: data, encoding: .utf8) {
            let embedAssets = InstagramMediaParser.assets(fromHTML: html)
            if embedAssets.contains(where: { $0.kind == .video }) { return embedAssets }
            if assets.isEmpty { return embedAssets }
        }
        return assets
    }

    // MARK: - Requests

    private func jsonRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func htmlRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    /// A request with a link-unfurler UA — sites serve the Open Graph preview
    /// (`og:video`/`og:image`) to it even when they'd otherwise show a login wall.
    private func metaScrapeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("facebookexternalhit/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    static let defaultFetch: Fetch = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}

/// Shared HTTP constants for media resolution/download.
enum MediaDownloadHTTP {
    /// A desktop Safari UA — social pages serve richer/less-walled markup to it.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
}

// MARK: - Pure parsers (unit-tested against fixtures)

/// Parses fxtwitter's JSON into ordered media assets.
enum XMediaParser {
    static func assets(fromFxJSON data: Data) -> [MediaAsset] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = root["tweet"] as? [String: Any],
              let media = tweet["media"] as? [String: Any] else { return [] }

        // `all` preserves display order and types; prefer it.
        if let all = media["all"] as? [[String: Any]] {
            let assets = all.compactMap { item -> MediaAsset? in
                guard let urlString = item["url"] as? String, let url = URL(string: urlString) else { return nil }
                let type = (item["type"] as? String)?.lowercased() ?? "photo"
                // Twitter GIFs and videos are both mp4 files → save as video.
                return MediaAsset(url: url, kind: type == "photo" ? .image : .video)
            }
            if !assets.isEmpty { return assets }
        }

        var assets: [MediaAsset] = []
        if let videos = media["videos"] as? [[String: Any]] {
            assets += videos.compactMap {
                ($0["url"] as? String).flatMap(URL.init(string:)).map { MediaAsset(url: $0, kind: .video) }
            }
        }
        if let photos = media["photos"] as? [[String: Any]] {
            assets += photos.compactMap {
                ($0["url"] as? String).flatMap(URL.init(string:)).map { MediaAsset(url: $0, kind: .image) }
            }
        }
        return assets
    }
}

/// Parses TikTok's rehydration JSON into media assets (photo carousel or video).
enum TikTokMediaParser {
    static func assets(fromHTML html: String) -> [MediaAsset] {
        guard let item = videoItemStruct(in: html) else { return [] }

        // Photo ("slides") posts: a carousel of images.
        if let imagePost = item["imagePost"] as? [String: Any],
           let images = imagePost["images"] as? [[String: Any]] {
            let assets = images.compactMap { image -> MediaAsset? in
                guard let imageURL = image["imageURL"] as? [String: Any],
                      let list = imageURL["urlList"] as? [String],
                      let first = list.first, let url = URL(string: first) else { return nil }
                return MediaAsset(url: url, kind: .image)
            }
            if !assets.isEmpty { return assets }
        }

        // Video: the watermark-free playAddr, else the watermarked downloadAddr.
        if let video = item["video"] as? [String: Any] {
            let address = (video["playAddr"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (video["downloadAddr"] as? String)
            if let address, let url = URL(string: address) {
                return [MediaAsset(url: url, kind: .video)]
            }
        }
        return []
    }

    private static func videoItemStruct(in html: String) -> [String: Any]? {
        let marker = "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">"
        guard let start = html.range(of: marker) else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: "</script>") else { return nil }
        let jsonString = String(rest[..<end.lowerBound])
        guard let root = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any],
              let info = detail["itemInfo"] as? [String: Any] else { return nil }
        return info["itemStruct"] as? [String: Any]
    }
}

/// Parses Instagram post/embed HTML into a single media asset (video preferred).
enum InstagramMediaParser {
    static func assets(fromHTML html: String) -> [MediaAsset] {
        // Videos / reels first.
        for pattern in [#""video_url":"(.*?)""#,
                        #"property="og:video" content="(.*?)""#,
                        #"property="og:video:secure_url" content="(.*?)""#] {
            if let raw = firstGroup(in: html, pattern: pattern),
               let url = URL(string: unescape(raw)) {
                return [MediaAsset(url: url, kind: .video)]
            }
        }
        // Still images.
        for pattern in [#""display_url":"(.*?)""#,
                        #"class="EmbeddedMediaImage"[^>]*?src="(.*?)""#,
                        #"property="og:image" content="(.*?)""#] {
            if let raw = firstGroup(in: html, pattern: pattern),
               let url = URL(string: unescape(raw)) {
                return [MediaAsset(url: url, kind: .image)]
            }
        }
        return []
    }

    /// Unescapes the JSON/HTML-encoded URLs Instagram embeds in markup.
    static func unescape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstGroup(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: html) else { return nil }
        let value = String(html[group])
        return value.isEmpty ? nil : value
    }
}
