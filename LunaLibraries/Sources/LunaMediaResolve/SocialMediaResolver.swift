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
        // Every ladder step goes through this one closure — X's fxtwitter call,
        // Instagram's GraphQL/embed/og cascade, YouTube's player JSON — so
        // tracing it here is what makes "which step was tried and what came
        // back" appear in a failed save's trace without touching six parsers.
        self.fetch = Self.traced(fetch)
    }

    /// Reports each resolve request's shape (never its body) into the in-flight
    /// save's trace. A no-op outside a save.
    private static func traced(_ fetch: @escaping Fetch) -> Fetch {
        { request in
            let started = Date()
            let data = await fetch(request)
            SaveDiagnostics.record(
                "resolve \(request.httpMethod ?? "GET") "
                    + "\(request.url.map(SaveDiagnostics.url) ?? "?") → "
                    + (data.map { "\($0.count)B" } ?? "nothing")
                    + " in \(Int(Date().timeIntervalSince(started) * 1000))ms",
                category: "media")
            return data
        }
    }

    public func resolveAssets(for url: URL) async -> [MediaAsset] {
        if let direct = MediaAsset.direct(url: url) {
            SaveDiagnostics.record(
                "media: \(SaveDiagnostics.url(url)) is a direct \(direct.kind) asset",
                category: "media")
            return [direct]
        }
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString) else {
            SaveDiagnostics.record(
                "media: no platform recognized for \(SaveDiagnostics.url(url))",
                category: "media")
            return []
        }
        let assets = await resolveAssets(platform: recognized.platform, url: url,
                                         itemID: recognized.itemID)
        SaveDiagnostics.record(
            "media: \(recognized.platform) ladder resolved \(assets.count) asset(s)"
                + (assets.isEmpty
                    ? "" : " [\(assets.map { "\($0.kind)" }.joined(separator: ", "))]"),
            category: "media")
        return assets
    }

    private func resolveAssets(
        platform: ContentPlatform, url: URL, itemID: String?
    ) async -> [MediaAsset] {
        switch platform {
        case .x:
            return await resolveX(id: itemID)
        case .tiktok:
            return await resolveTikTok(url: url)
        case .instagram:
            return await resolveInstagram(url: url, shortcode: itemID)
        case .facebook:
            return await resolveFacebook(url: url)
        case .reddit:
            return await resolveReddit(url: url, itemID: itemID)
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

    /// Instagram posts/reels. Every stage here is keyless, and the order exists to
    /// keep a VIDEO from resolving to its cover frame: Instagram hands out that still
    /// freely and the playable MP4 only from one endpoint.
    private func resolveInstagram(url: URL, shortcode: String?) async -> [MediaAsset] {
        // The web client's persisted GraphQL query FIRST — today the only keyless
        // source that still carries `video_url`. The embed page below used to, and no
        // longer does for reels: its `contextJSON` now describes the post as a video
        // (`is_video`, `video_duration`, `product_type: clips`) while omitting the
        // playable URL entirely, which is exactly how a saved reel became a static
        // image. Both endpoints return the same `shortcode_media` node shape.
        if let code = shortcode,
           let data = await fetch(Self.instagramGraphQLRequest(shortcode: code)),
           let post = InstagramMediaParser.post(fromGraphQLJSON: data) {
            if !post.assets.isEmpty { return post.assets }
            // A video the query couldn't produce a URL for: the sources below can
            // only offer its poster, so stop rather than pass a still off as the reel.
            if post.declaresVideo { return [] }
        }

        // Embed page. Still the source for stills and carousels, and for any post
        // whose `video_url` it does hand back. `/p/{code}/embed/` serves reels too.
        var embedDeclaredVideo = false
        if let code = shortcode,
           let embed = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/"),
           let data = await fetch(htmlRequest(embed)),
           let html = String(data: data, encoding: .utf8) {
            if let post = InstagramMediaParser.post(fromEmbedHTML: html) {
                if !post.assets.isEmpty { return post.assets }
                embedDeclaredVideo = post.declaresVideo
            }
            // Older embed markup occasionally inlines an unescaped video_url/image.
            let legacy = InstagramMediaParser.assets(fromHTML: html)
            if let first = legacy.first, !embedDeclaredVideo || first.kind == .video {
                return legacy
            }
        }

        // The post page's `og:` tags. Image-only for a walled video post — better than
        // nothing for a still, never right for a reel.
        if embedDeclaredVideo { return [] }
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
        guard LiveNetworkPolicy.allows(
            url, context: "SocialMediaResolver.resolveRedditShareLinkPostID") else { return nil }
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

    /// The Instagram web client's own persisted GraphQL query for one post, as a GET
    /// so the durable background engine (which can only issue plain background
    /// download tasks) can run the identical request. `doc_id` names a query Instagram
    /// has already registered server-side — there is no key and no login — and
    /// `variables` carries just the shortcode. Sent with the public web `X-IG-App-ID`
    /// the site's own JS sends; the endpoint 403s a bare POST but answers this GET.
    ///
    /// Instagram rotates `doc_id`s. When this one is retired the query returns no
    /// media rather than wrong media, and `resolveInstagram` stops instead of falling
    /// through to a still — a reel that can't be fetched stays a link.
    public static func instagramGraphQLRequest(
        shortcode: String, timeoutInterval: TimeInterval = 15
    ) -> URLRequest {
        var components = URLComponents(string: "https://www.instagram.com/graphql/query/")
        components?.queryItems = [
            URLQueryItem(name: "doc_id", value: instagramPostDocumentID),
            URLQueryItem(name: "variables", value: #"{"shortcode":"\#(shortcode)"}"#),
        ]
        let endpoint = components?.url
            ?? URL(string: "https://www.instagram.com/graphql/query/")!
        // Cookie-free for the same reason the Facebook factory is: state carried over
        // from an earlier Instagram request can turn a public post's response into a
        // login wall.
        var request = URLRequest(
            url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval)
        request.httpShouldHandleCookies = false
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaDownloadHTTP.instagramWebAppID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `PolarisPostActionLoadPostQueryQuery` — the query Instagram's own web post page
    /// issues, and the only keyless one that returns `video_url`.
    private static let instagramPostDocumentID = "10015901848480474"

    /// Stable Facebook content URL used by every resolver stage. Path-addressed
    /// permalinks and `fb.watch` short links need no query. `/watch/?v=<id>` retains
    /// only `v`, since it is content identity rather than share tracking.
    public static func facebookResolutionURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
        components.queryItems = videoID.map { [URLQueryItem(name: "v", value: $0)] }
        components.fragment = nil
        return components.url ?? url
    }

    /// The `/plugins/video.php?href=<url>` embed URL for a Facebook video/reel.
    /// Returns nil only if the URL can't be recomposed.
    public static func facebookVideoPluginURL(for url: URL) -> URL? {
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
    public static func facebookPageRequest(
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
        guard LiveNetworkPolicy.allows(request.url, context: "SocialMediaResolver.defaultFetch"),
              let (data, response) = try? await URLSession.shared.data(for: request),
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

    /// The public application id instagram.com's own web JS sends on every API call.
    /// Not a credential — the logged-out GraphQL endpoint just expects the header.
    public static let instagramWebAppID = "936619743392459"
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

    /// TikTok ships the item in one of two scripts depending on which variant of
    /// the page it decides to serve, and BOTH wrap the same `itemStruct` — only the
    /// route in differs, so everything above this is shared.
    ///
    /// - The app shell puts it in `__UNIVERSAL_DATA_FOR_REHYDRATION__` under
    ///   `__DEFAULT_SCOPE__`.
    /// - The logged-out "reflow" page — what a background fetch actually gets —
    ///   puts it in a separate `api-data` script, whose `__DEFAULT_SCOPE__` carries
    ///   only reflow/ui-strategy keys and no video at all. Missing this route is
    ///   why every TikTok save reported "couldn't find media to download".
    private static func videoItemStruct(in html: String) -> [String: Any]? {
        if let item = rehydrationItemStruct(in: html) { return item }
        return apiDataItemStruct(in: html)
    }

    private static func rehydrationItemStruct(in html: String) -> [String: Any]? {
        guard let root = jsonObject(
            inScriptWithID: "__universal_data_for_rehydration__", html: html),
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any]
        else { return nil }

        for key in ["webapp.video-detail", "webapp.reflow.video.detail"] {
            guard let detail = scope[key] as? [String: Any],
                  let info = detail["itemInfo"] as? [String: Any],
                  let item = info["itemStruct"] as? [String: Any] else { continue }
            return item
        }
        return nil
    }

    /// The reflow page's payload: `{"videoDetail": {"itemInfo": {"itemStruct": …}}}`
    /// (alongside `commentList`).
    private static func apiDataItemStruct(in html: String) -> [String: Any]? {
        guard let root = jsonObject(inScriptWithID: "api-data", html: html),
              let detail = root["videoDetail"] as? [String: Any],
              let info = detail["itemInfo"] as? [String: Any],
              let item = info["itemStruct"] as? [String: Any]
        else { return nil }
        return item
    }

    private static func jsonObject(
        inScriptWithID id: String, html: String
    ) -> [String: Any]? {
        guard let body = scriptBody(withID: id, html: html) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }

    /// The body of the `<script>` whose `id` attribute is exactly `id`. Matched on
    /// the quoted attribute rather than a bare substring so a script URL that
    /// happens to contain the same word can't be mistaken for the payload.
    private static func scriptBody(withID id: String, html: String) -> String? {
        let needles = ["id=\"\(id)\"", "id='\(id)'"]
        var searchStart = html.startIndex
        while searchStart < html.endIndex,
              let tagStart = html[searchStart...].range(of: "<script", options: [.caseInsensitive]) {
            guard let tagEnd = html[tagStart.upperBound...].firstIndex(of: ">") else { return nil }
            let tag = String(html[tagStart.lowerBound...tagEnd]).lowercased()
            let contentStart = html.index(after: tagEnd)
            guard let end = html[contentStart...].range(of: "</script>", options: [.caseInsensitive]) else {
                return nil
            }
            if needles.contains(where: tag.contains) {
                return String(html[contentStart..<end.lowerBound])
            }
            searchStart = end.upperBound
        }
        return nil
    }
}

/// What one Instagram post's own metadata says about it: the media that can
/// actually be downloaded, plus whether the post IS a video regardless of whether
/// a playable URL came with it.
///
/// The two are separate answers because Instagram now routinely serves the second
/// without the first: a reel's embed payload carries `is_video: true`,
/// `video_duration` and `product_type: clips` but no `video_url` at all. Collapsing
/// that into "no video found" is what let a reel save its cover frame as if it were
/// the reel — so callers ladder through sources while `declaresVideo` is true rather
/// than accepting the first still any source offers.
public struct InstagramPost: Equatable {
    /// Downloadable media in post order — one entry, or one per carousel child.
    public let assets: [MediaAsset]
    /// True when the post (or any carousel child) is a video, even if no playable
    /// URL was present to build a `.video` asset from.
    public let declaresVideo: Bool

    public init(assets: [MediaAsset], declaresVideo: Bool) {
        self.assets = assets
        self.declaresVideo = declaresVideo
    }

    /// True when the post is a video but nothing playable was found — the case where
    /// falling back to a still would silently substitute a poster for the reel.
    public var isVideoMissingItsPlayableURL: Bool {
        declaresVideo && !assets.contains { $0.kind == .video }
    }
}

/// Parses Instagram post/embed HTML into a single media asset (video preferred).
public enum InstagramMediaParser {
    /// Parses the web client's persisted-GraphQL response (`data.xdt_shortcode_media`).
    /// This is the one keyless source that still carries a reel's real `video_url`;
    /// the node shape is otherwise identical to the embed's `shortcode_media`, down to
    /// `edge_sidecar_to_children`, so both feed the same node parser.
    public static func post(fromGraphQLJSON data: Data) -> InstagramPost? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let media = payload["xdt_shortcode_media"] as? [String: Any]
        else { return nil }
        return post(fromShortcodeMedia: media)
    }

    /// Parses the embed page's `contextJSON` blob — a JSON-encoded string holding
    /// `gql_data.shortcode_media`. Nil if the blob is absent or unparsable.
    public static func post(fromEmbedHTML html: String) -> InstagramPost? {
        shortcodeMedia(fromEmbedHTML: html).flatMap(post(fromShortcodeMedia:))
    }

    /// Parses the embed page's `contextJSON` blob into ordered assets. Empty if the
    /// blob is absent or has no recognizable media. Prefer `post(fromEmbedHTML:)`,
    /// which also reports a video whose playable URL Instagram withheld.
    public static func assetsFromEmbedContextJSON(_ html: String) -> [MediaAsset] {
        post(fromEmbedHTML: html)?.assets ?? []
    }

    /// One post from a `shortcode_media` / `xdt_shortcode_media` node.
    private static func post(fromShortcodeMedia media: [String: Any]) -> InstagramPost {
        // Carousel (mixed photos/videos) → one asset per child, in order.
        if let sidecar = media["edge_sidecar_to_children"] as? [String: Any],
           let edges = sidecar["edges"] as? [[String: Any]] {
            let children = edges.compactMap { $0["node"] as? [String: Any] }
            if !children.isEmpty {
                return InstagramPost(
                    assets: children.compactMap(asset(fromNode:)),
                    declaresVideo: children.contains(where: declaresVideo(node:)))
            }
        }
        return InstagramPost(
            assets: asset(fromNode: media).map { [$0] } ?? [],
            declaresVideo: declaresVideo(node: media))
    }

    /// Whether a shortcode-media node is a video. `__typename` is `GraphVideo` on the
    /// embed payload and `XDTGraphVideo` on the GraphQL one, so match the suffix.
    private static func declaresVideo(node: [String: Any]) -> Bool {
        if let isVideo = node["is_video"] as? Bool { return isVideo }
        return (node["__typename"] as? String)?.hasSuffix("GraphVideo") == true
    }

    /// One asset from a shortcode-media node: its video when it's a video, else the
    /// still. URLs come straight from parsed JSON, so they need no unescaping.
    ///
    /// A video node with no `video_url` yields NOTHING rather than its `display_url`:
    /// that still is the reel's cover frame, and returning it here is what made a
    /// saved reel come back as a static image. The poster is still reachable — it
    /// rides a resolved video as `thumbnailURL`, and the card's own artwork comes
    /// from the platform metadata fetcher either way.
    private static func asset(fromNode node: [String: Any]) -> MediaAsset? {
        let isVideo = declaresVideo(node: node)
        if isVideo, let videoURL = node["video_url"] as? String, let url = URL(string: videoURL) {
            return MediaAsset(
                url: url, kind: .video,
                thumbnailURL: (node["display_url"] as? String).flatMap(URL.init(string:)))
        }
        if isVideo { return nil }
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
