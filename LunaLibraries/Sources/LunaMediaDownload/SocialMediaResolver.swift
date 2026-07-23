//
//  SocialMediaResolver.swift
//  Luna
//

import LunaURLClassification
import LunaModels
import Foundation

/// Resolves a social post URL to its downloadable media, using keyless,
/// client-side techniques mirroring public web downloaders:
///   • X      — the keyless fxtwitter JSON API (`media.all` → photo/video/gif).
///   • TikTok — the page's `__UNIVERSAL_DATA_FOR_REHYDRATION__` JSON
///              (`playAddr` video, or `imagePost` photo carousel).
///   • Instagram — the post/embed HTML (`video_url` / `display_url` / og tags).
///   • YouTube — guest-bound Android VR player JSON (progressive MP4 with audio).
/// Network fetching is injectable so the per-platform PARSERS can be unit-tested
/// against fixtures without hitting the network.
public struct SocialMediaResolver: SocialMediaResolving {
    public typealias Fetch = (URLRequest) async -> Data?
    private let fetch: Fetch

    public init(fetch: @escaping Fetch = SocialMediaResolver.defaultFetch) {
        self.fetch = fetch
    }

    public func resolveAssets(for url: URL) async -> [MediaAsset] {
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString) else { return [] }
        switch recognized.platform {
        case .x:
            return await resolveX(id: recognized.itemID)
        case .tiktok:
            return await resolveTikTok(url: url)
        case .instagram:
            return await resolveInstagram(url: url, shortcode: recognized.itemID)
        case .facebook:
            return await resolveFacebook(url: url)
        case .reddit:
            return await resolveReddit(url: url, itemID: recognized.itemID)
        case .youtube:
            return await YouTubeMediaResolver(fetch: fetch).resolveAssets(for: url)
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
        // Embed page FIRST. Its `contextJSON` (gql_data.shortcode_media) carries the
        // real `video_url` for reels/videos and `display_url` for stills — the only
        // reliable keyless source. The crawler `og:` tags expose ONLY the poster image
        // behind a login wall, so relying on them would save a still for a video reel.
        // `/p/{code}/embed/` serves reels too.
        if let code = shortcode,
           let embed = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/"),
           let data = await fetch(htmlRequest(embed)),
           let html = String(data: data, encoding: .utf8) {
            let assets = InstagramMediaParser.assetsFromEmbedContextJSON(html)
            if !assets.isEmpty { return assets }
            // Older embed markup occasionally inlines an unescaped video_url/image.
            let legacy = InstagramMediaParser.assets(fromHTML: html)
            if !legacy.isEmpty { return legacy }
        }

        // Fallback: the post page's `og:` tags (image-only for walled video posts,
        // but better than nothing when the embed is unavailable).
        if let data = await fetch(metaScrapeRequest(url)),
           let html = String(data: data, encoding: .utf8) {
            return InstagramMediaParser.assets(fromHTML: html)
        }
        return []
    }

    /// Facebook reels/videos: the real playable video URL lives in the page's embedded
    /// JSON (`hd_src`/`sd_src`, `browser_native_hd_url`, `playable_url`, …), NOT the
    /// Open Graph tags — exactly like Instagram, a reel's crawler `og:` tags expose
    /// ONLY the poster still behind a login wall, so an og-first order saves a still
    /// from every video reel. Worse, Facebook frequently serves the logged-out
    /// reel/video PAGE itself as a stripped login wall (only `og:image`, no video), so
    /// the page can't be relied on. The `/plugins/video.php` embed, however, returns
    /// the real `hd_src`/`sd_src` MP4 for a public video even when the page is walled —
    /// it's the endpoint public downloaders use — so try it FIRST, then fall back to the
    /// full page and finally the og-unfurl tags. Best-effort: private/removed posts
    /// expose no asset and the caller keeps the saved link usable.
    private func resolveFacebook(url: URL) async -> [MediaAsset] {
        // Facebook changes its logged-out response when app-share tracking parameters
        // are present: the same public reel permalink exposes video metadata, while
        // `?fs=…&mibextid=…` can produce a metadata-free shell. Resolve every stage
        // against the stable content identity, retaining only `v` when that query item
        // is the identity (`/watch/?v=…`).
        let resolutionURL = Self.facebookResolutionURL(for: url)

        // Video plugin embed: the most reliable keyless source. Returns HD `hd_src`
        // even when the logged-out reel/video page is a login wall, and works straight
        // from a `/reel/` URL. Needs the DESKTOP UA (the mobile UA gets a sourceless
        // page).
        if let embed = Self.facebookVideoPluginURL(for: resolutionURL),
           let data = await fetch(facebookVideoPageRequest(embed)),
           let html = String(data: data, encoding: .utf8) {
            let assets = FacebookMediaParser.assets(fromHTML: html)
            if !assets.isEmpty { return assets }
        }

        // Desktop browser page: carries the playable video URL in inline JSON.
        // Facebook's mobile logged-out page often exposes only `og:image`.
        if let data = await fetch(facebookVideoPageRequest(resolutionURL)),
           let html = String(data: data, encoding: .utf8) {
            let assets = FacebookMediaParser.assets(fromHTML: html)
            if !assets.isEmpty { return assets }
        }

        // The desktop UA 400s on some pages (notably `/reel/<id>` links and
        // `fb.watch` short links), but the mobile page loads. Prefer resolving its
        // canonical long-form video URL and refetching that with the desktop UA (its
        // inline JSON carries the HD `browser_native_*_url`); if the canonical can't
        // be resolved or fetched, the mobile page's OWN `og:video` tag carries the
        // real (SD) playable MP4. A reel's canonical is the reel URL itself, so for
        // reels this og:video fallback is the only asset — without it they resolved
        // to "no media" even though the video was right there on the page.
        if let data = await fetch(Self.facebookPageRequest(
            resolutionURL, userAgent: MediaDownloadHTTP.browserUserAgent)),
           let html = String(data: data, encoding: .utf8) {
            if let canonical = FacebookMediaParser.canonicalVideoURL(fromHTML: html),
               canonical.absoluteString != resolutionURL.absoluteString,
               let canonicalData = await fetch(facebookVideoPageRequest(canonical)),
               let canonicalHTML = String(data: canonicalData, encoding: .utf8) {
                let assets = FacebookMediaParser.assets(fromHTML: canonicalHTML)
                if !assets.isEmpty { return assets }
            }
            let assets = FacebookMediaParser.assets(fromHTML: html)
            if !assets.isEmpty { return assets }
        }

        // Final logged-out fallback: `facebookexternalhit` often omits `og:video`
        // entirely but includes `browser_native_hd_url` / `browser_native_sd_url` in
        // its inline JSON. Run the same video-only parser used by every earlier stage;
        // it deliberately ignores poster-only `og:image` metadata.
        guard let data = await fetch(Self.facebookPageRequest(
            resolutionURL, userAgent: MediaDownloadHTTP.facebookCrawlerUserAgent)),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return FacebookMediaParser.assets(fromHTML: html)
    }

    /// Reddit's public, subreddit-agnostic listing endpoint (`/comments/<id>.json`)
    /// works for any recognized permalink shape (`reddit.com/r/.../comments/<id>/...`
    /// or a `redd.it/<id>` short link) since `PlatformRecognizer` already extracts
    /// the same post id from both — simpler and more robust than reconstructing
    /// `.json` from the original URL string (which would need to follow redd.it's
    /// redirect and strip share-tracking query params).
    private func resolveReddit(url: URL, itemID: String?) async -> [MediaAsset] {
        let resolvedID: String?
        if let itemID {
            resolvedID = itemID
        } else {
            resolvedID = await Self.resolveRedditShareLinkPostID(url)
        }
        guard let id = resolvedID,
              let jsonURL = URL(string: "https://www.reddit.com/comments/\(id).json")
        else { return [] }
        guard let data = await fetch(jsonRequest(jsonURL)) else { return [] }
        return RedditMediaParser.asset(fromListingJSON: data).map { [$0] } ?? []
    }

    /// Reddit's own app-native share links (`/r/<sub>/s/<token>`) carry no post id
    /// — the token only resolves via a live HTTP redirect (which `URLSession`
    /// follows automatically) to the canonical permalink. A real network fetch
    /// (not the injectable `fetch`, which exists to make the PARSERS testable
    /// against fixtures — there's no parsing here, just reading off the final URL).
    private static func resolveRedditShareLinkPostID(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let finalURL = response.url
        else { return nil }
        return PlatformRecognizer.recognize(finalURL.absoluteString)?.itemID
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
        request.setValue(MediaDownloadHTTP.facebookCrawlerUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    /// Stable Facebook content URL used by every resolver stage. Path-addressed
    /// permalinks and `fb.watch` short links need no query. `/watch/?v=<id>` retains
    /// only `v`, since it is content identity rather than share tracking.
    static func facebookResolutionURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
        components.queryItems = videoID.map { [URLQueryItem(name: "v", value: $0)] }
        components.fragment = nil
        return components.url ?? url
    }

    /// The `/plugins/video.php?href=<url>` embed URL for a Facebook video/reel.
    /// Returns nil only if the URL can't be recomposed.
    static func facebookVideoPluginURL(for url: URL) -> URL? {
        let href = facebookResolutionURL(for: url).absoluteString
        var plugin = URLComponents(string: "https://www.facebook.com/plugins/video.php")
        plugin?.queryItems = [URLQueryItem(name: "href", value: href)]
        return plugin?.url
    }

    private func facebookVideoPageRequest(_ url: URL) -> URLRequest {
        Self.facebookPageRequest(url, userAgent: MediaDownloadHTTP.desktopBrowserUserAgent)
    }

    /// A cookie-free, cache-bypassing Facebook page request. Media resolution is a
    /// logged-out scrape: carrying state from an earlier Facebook request can turn a
    /// public reel's lightweight Open Graph response into a consent/login wall, and a
    /// cached wall can survive after the reel becomes publicly available. Keep this
    /// factory shared with the durable background resolver so both paths see the same
    /// response shape.
    static func facebookPageRequest(
        _ url: URL, userAgent: String, timeoutInterval: TimeInterval = 15
    ) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    public static let defaultFetch: Fetch = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}

/// Shared HTTP constants for media resolution/download.
public enum MediaDownloadHTTP {
    /// The app's normal mobile Safari UA, shared with article fetching.
    public static let browserUserAgent = WebFetchConstants.safariUserAgent

    /// A desktop Safari UA. Facebook's logged-out mobile page often contains only
    /// poster metadata, while the desktop page includes `browser_native_*_url`.
    public static let desktopBrowserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Facebook's public link-unfurl crawler, used only after browser-page fallbacks.
    public static let facebookCrawlerUserAgent = "facebookexternalhit/1.1"
}

/// Small, dependency-free Open Graph parser for social pages. Attribute order in
/// `<meta>` tags is not stable, so inspect each tag rather than matching one order.
private enum OpenGraphMediaParser {
    public static func content(named name: String, in html: String) -> String? {
        let tags = html.components(separatedBy: "<meta")
        for tag in tags {
            let lowercased = tag.lowercased()
            guard lowercased.contains("property=\"\(name)\"")
                    || lowercased.contains("property='\(name)'")
                    || lowercased.contains("name=\"\(name)\"")
                    || lowercased.contains("name='\(name)'") else { continue }
            for quote in ["\"", "'"] {
                let marker = "content=\(quote)"
                guard let start = tag.range(of: marker, options: [.caseInsensitive])?.upperBound,
                      let end = tag[start...].firstIndex(of: Character(quote)) else { continue }
                return String(tag[start..<end]).replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }
}

// MARK: - Pure parsers (unit-tested against fixtures)

/// Parses fxtwitter's JSON into ordered media assets.
public enum XMediaParser {
    public static func assets(fromFxJSON data: Data) -> [MediaAsset] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = root["tweet"] as? [String: Any],
              let media = tweet["media"] as? [String: Any] else { return [] }

        // `all` preserves display order and types; prefer it.
        if let all = media["all"] as? [[String: Any]] {
            let assets = all.compactMap { item -> MediaAsset? in
                guard let urlString = item["url"] as? String, let url = URL(string: urlString) else { return nil }
                let type = (item["type"] as? String)?.lowercased() ?? "photo"
                let thumbnail = (item["thumbnail_url"] as? String)
                    .flatMap(URL.init(string:))
                // Twitter GIFs and videos are both mp4 files → save as video.
                return MediaAsset(
                    url: url, kind: type == "photo" ? .image : .video,
                    thumbnailURL: thumbnail)
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
public enum TikTokMediaParser {
    public static func assets(fromHTML html: String) -> [MediaAsset] {
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
                let thumbnail = ["cover", "originCover", "dynamicCover"]
                    .compactMap { video[$0] as? String }
                    .compactMap(URL.init(string:))
                    .first
                return [MediaAsset(url: url, kind: .video, thumbnailURL: thumbnail)]
            }
        }
        return []
    }

    private static func videoItemStruct(in html: String) -> [String: Any]? {
        guard let jsonString = rehydrationJSON(in: html),
              let root = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any] else { return nil }

        for key in ["webapp.video-detail", "webapp.reflow.video.detail"] {
            guard let detail = scope[key] as? [String: Any],
                  let info = detail["itemInfo"] as? [String: Any],
                  let item = info["itemStruct"] as? [String: Any] else { continue }
            return item
        }
        return nil
    }

    private static func rehydrationJSON(in html: String) -> String? {
        guard let scriptStart = html.range(of: "<script", options: [.caseInsensitive]) else { return nil }
        var searchStart = scriptStart.lowerBound
        while searchStart < html.endIndex,
              let tagStart = html[searchStart...].range(of: "<script", options: [.caseInsensitive]) {
            guard let tagEnd = html[tagStart.upperBound...].firstIndex(of: ">") else { return nil }
            let tag = String(html[tagStart.lowerBound...tagEnd]).lowercased()
            let contentStart = html.index(after: tagEnd)
            guard let end = html[contentStart...].range(of: "</script>", options: [.caseInsensitive]) else {
                return nil
            }
            if tag.contains("__universal_data_for_rehydration__") {
                return String(html[contentStart..<end.lowerBound])
            }
            searchStart = end.upperBound
        }
        return nil
    }
}

/// Parses Instagram post/embed HTML into a single media asset (video preferred).
public enum InstagramMediaParser {
    /// Parses the embed page's `contextJSON` blob — a JSON-encoded string holding
    /// `gql_data.shortcode_media` — into ordered assets. This is the reliable source
    /// for a reel/video's real `video_url` (carousels and stills too). Empty if the
    /// blob is absent or has no recognizable media.
    public static func assetsFromEmbedContextJSON(_ html: String) -> [MediaAsset] {
        guard let media = shortcodeMedia(fromEmbedHTML: html) else { return [] }
        // Carousel (mixed photos/videos) → one asset per child, in order.
        if let sidecar = media["edge_sidecar_to_children"] as? [String: Any],
           let edges = sidecar["edges"] as? [[String: Any]] {
            let assets = edges.compactMap { ($0["node"] as? [String: Any]).flatMap(asset(fromNode:)) }
            if !assets.isEmpty { return assets }
        }
        return asset(fromNode: media).map { [$0] } ?? []
    }

    /// One asset from a shortcode-media node: its video when it's a video, else the
    /// still. URLs come straight from parsed JSON, so they need no unescaping.
    private static func asset(fromNode node: [String: Any]) -> MediaAsset? {
        let isVideo = (node["is_video"] as? Bool) ?? (node["__typename"] as? String == "GraphVideo")
        if isVideo, let videoURL = node["video_url"] as? String, let url = URL(string: videoURL) {
            return MediaAsset(
                url: url, kind: .video,
                thumbnailURL: (node["display_url"] as? String).flatMap(URL.init(string:)))
        }
        if let displayURL = node["display_url"] as? String, let url = URL(string: displayURL) {
            return MediaAsset(url: url, kind: .image)
        }
        return nil
    }

    /// Extracts and decodes `contextJSON` (a JSON string literal embedded in the
    /// page) and returns its `gql_data.shortcode_media` dictionary.
    private static func shortcodeMedia(fromEmbedHTML html: String) -> [String: Any]? {
        guard let marker = html.range(of: "contextJSON") else { return nil }
        let afterMarker = html[marker.upperBound...]
        // The value is `: "<json-string-literal>"` — find the colon then the literal.
        guard let colon = afterMarker.firstIndex(of: ":") else { return nil }
        let afterColon = afterMarker[afterMarker.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return nil }

        // Walk the string literal, honoring backslash escapes, to its closing quote.
        var literal = "\""
        var index = afterColon.index(after: openQuote)
        while index < afterColon.endIndex {
            let character = afterColon[index]
            literal.append(character)
            if character == "\\" {
                index = afterColon.index(after: index)
                guard index < afterColon.endIndex else { break }
                literal.append(afterColon[index])
            } else if character == "\"" {
                break
            }
            index = afterColon.index(after: index)
        }

        // `literal` is a JSON string literal; decoding it yields the inner JSON text.
        guard let inner = try? JSONSerialization.jsonObject(
                with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String,
              let context = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
              let gqlData = context["gql_data"] as? [String: Any],
              let media = gqlData["shortcode_media"] as? [String: Any] else { return nil }
        return media
    }

    public static func assets(fromHTML html: String) -> [MediaAsset] {
        let poster = OpenGraphMediaParser.content(named: "og:image", in: html)
            .flatMap { URL(string: unescape($0)) }
        // Videos / reels first.
        for pattern in [#""video_url":"(.*?)""#,
                        #"property="og:video" content="(.*?)""#,
                        #"property="og:video:secure_url" content="(.*?)""#] {
            if let raw = firstGroup(in: html, pattern: pattern),
               let url = URL(string: unescape(raw)) {
                return [MediaAsset(url: url, kind: .video, thumbnailURL: poster)]
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
    public static func unescape(_ string: String) -> String {
        LunaMediaDownload.unescape(string)
    }
}

/// Parses a Facebook reel/video/post page into a single media asset (video preferred).
/// Facebook inlines the real playable video URL in JSON blobs on the page; a walled
/// reel's `og:` tags only carry the poster still, so those JSON keys are the reliable
/// keyless source for the actual video (mirrors public FB downloaders).
public enum FacebookMediaParser {
    public static func canonicalVideoURL(fromHTML html: String) -> URL? {
        for pattern in [
            #"<link[^>]+rel="canonical"[^>]+href="(.*?)""#,
            #"<link[^>]+href="(.*?)"[^>]+rel="canonical""#,
            #"property="og:url" content="(.*?)""#,
            #"content="(.*?)" property="og:url""#,
        ] {
            if let raw = firstGroup(in: html, pattern: pattern),
               let url = URL(string: unescape(raw)),
               PlatformRecognizer.recognize(url.absoluteString)?.platform == .facebook {
                return url
            }
        }

        if let raw = firstGroup(in: html, pattern: #"oembed_video\?url=([^"&]+)"#),
           let decoded = raw.removingPercentEncoding,
           let url = URL(string: decoded),
           PlatformRecognizer.recognize(url.absoluteString)?.platform == .facebook {
            return url
        }
        return nil
    }

    public static func assets(fromHTML html: String) -> [MediaAsset] {
        let poster = OpenGraphMediaParser.content(named: "og:image", in: html)
            .flatMap { URL(string: unescape($0)) }
        // Playable video URL, HD first. Facebook uses several key names across its
        // page variants; try them in quality order. Values are JSON string literals
        // with escaped slashes / ampersands.
        for key in ["browser_native_hd_url", "playable_url_quality_hd", "hd_src",
                    "browser_native_sd_url", "playable_url", "sd_src"] {
            if let raw = firstGroup(in: html, pattern: "\"\(key)\":\"(.*?)\""),
               let url = URL(string: unescape(raw)) {
                return [MediaAsset(url: url, kind: .video, thumbnailURL: poster)]
            }
        }
        // Open Graph video as a last resort. Deliberately ignore `og:image`: for
        // Facebook video URLs it is a poster, not downloadable video media.
        for property in ["og:video", "og:video:secure_url", "og:video:url"] {
            if let raw = OpenGraphMediaParser.content(named: property, in: html),
               let url = URL(string: unescape(raw)) {
                return [MediaAsset(url: url, kind: .video, thumbnailURL: poster)]
            }
        }
        return []
    }

}

/// Parses Reddit's public listing JSON (`/comments/<id>.json`) into the
/// post's video asset. Crossposts carry no media of their own — their
/// `crosspost_parent_list[0]` is the actual source. Reddit-hosted videos with
/// sound serve video and audio as two separate DASH files (there's no single
/// muxed URL to download); the audio companion is derived from the video
/// URL's current, well-established naming convention (`DASH_<res>.mp4`
/// alongside `DASH_audio.mp4`) rather than by parsing the DASH/HLS manifest —
/// if a future post doesn't follow it, the download degrades to a silent
/// video instead of failing (see `MediaFileDownloader`/`LiveMediaDownloadManager`).
public enum RedditMediaParser {
    public static func asset(fromListingJSON data: Data) -> MediaAsset? {
        guard let listings = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = listings.first as? [String: Any],
              let listing = first["data"] as? [String: Any],
              let children = listing["children"] as? [[String: Any]],
              var post = children.first?["data"] as? [String: Any]
        else { return nil }

        if let crossposts = post["crosspost_parent_list"] as? [[String: Any]],
           let original = crossposts.first {
            post = original
        }

        guard let redditVideo = (post["secure_media"] as? [String: Any])?["reddit_video"] as? [String: Any]
            ?? (post["media"] as? [String: Any])?["reddit_video"] as? [String: Any],
              let fallback = redditVideo["fallback_url"] as? String,
              let videoURL = URL(string: unescape(fallback))
        else { return nil }

        let hasAudio = redditVideo["has_audio"] as? Bool ?? false
        let thumbnail = (post["thumbnail"] as? String).flatMap(URL.init(string:))
        guard hasAudio else {
            return MediaAsset(url: videoURL, kind: .video, thumbnailURL: thumbnail)
        }
        let dashManifestURL = (redditVideo["dash_url"] as? String).flatMap { URL(string: unescape($0)) }
        return MediaAsset(
            url: videoURL, kind: .video,
            audioURL: audioURL(forVideoURL: videoURL),
            dashManifestURL: dashManifestURL,
            thumbnailURL: thumbnail)
    }

    /// Reddit consistently serves a video's audio track at this sibling path
    /// (confirmed against real `DASHPlaylist.mpd` manifests — its audio
    /// `Representation`'s own `<BaseURL>` is literally the plain string
    /// `audio`, resolved against the same `/{videoID}/` directory every
    /// resolution's video file lives in — not `DASH_audio.mp4`, which was
    /// this code's previous, incorrect guess).
    private static func audioURL(forVideoURL videoURL: URL) -> URL? {
        guard var components = URLComponents(url: videoURL, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        segments[segments.count - 1] = "audio"
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        return components.url
    }

    /// The audio track's URL straight from Reddit's DASH manifest —
    /// authoritative (unlike the fixed-path guess above, which every public
    /// v.redd.it downloader still uses as a fast path, but this is the actual
    /// discovery mechanism), used as a fallback when that guess's actual
    /// download fails. Each `Representation` nests its own `<BaseURL>` (a
    /// relative filename, e.g. `audio`); the audio one is identified by its
    /// `mimeType="audio/mp4"` — reliable enough for a light scrape without
    /// pulling in a full XML parser.
    public static func audioURL(fromDASHManifest xml: String, manifestURL: URL) -> URL? {
        for block in xml.components(separatedBy: "<Representation")
        where block.lowercased().contains("audio/mp4") {
            guard let raw = firstGroup(in: block, pattern: "<BaseURL>(.*?)</BaseURL>") else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = URL(string: trimmed, relativeTo: manifestURL)?.absoluteURL {
                return resolved
            }
        }
        return nil
    }
}

/// Unescapes the JSON/HTML-encoded URLs social pages embed in markup.
private func unescape(_ string: String) -> String {
    let jsonDecoded = try? JSONSerialization.jsonObject(
        with: Data("\"\(string)\"".utf8), options: [.fragmentsAllowed]) as? String
    return (jsonDecoded ?? string)
        .replacingOccurrences(of: "\\u0026", with: "&")
        .replacingOccurrences(of: "\\u0025", with: "%")
        .replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// The first capture group of `pattern` in `html`, or nil when absent/empty.
private func firstGroup(in html: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return nil
    }
    let range = NSRange(html.startIndex..., in: html)
    guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
          let group = Range(match.range(at: 1), in: html) else { return nil }
    let value = String(html[group])
    return value.isEmpty ? nil : value
}
