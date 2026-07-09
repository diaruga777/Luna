//
//  SocialMediaResolverTests.swift
//  LunaTests
//

import LunaMediaDownload
import LunaModels
import LunaURLClassification
import XCTest

final class SocialMediaResolverTests: XCTestCase {

    func testFacebookVideoURLDoesNotDownloadPosterImage() async {
        let source = URL(string: "https://www.facebook.com/TheOnion/videos/openai-announces-construction-of-new-data-center-on-top-of-sick-child/3928133123988446/")!
        let resolver = SocialMediaResolver { _ in
            Data(#"<meta property="og:image" content="https://cdn.example.com/poster.jpg">"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertTrue(assets.isEmpty)
    }

    func testFacebookVideoURLResolvesOpenGraphVideoAsVideo() async {
        let source = URL(string: "https://www.facebook.com/watch/?v=3928133123988446")!
        var fetchCount = 0
        let resolver = SocialMediaResolver { _ in
            fetchCount += 1
            if fetchCount == 1 {
                return Data("<html></html>".utf8)
            }
            return Data(#"<meta property="og:video:secure_url" content="https://video.example.com/clip.mp4?x=1&amp;y=2">"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/clip.mp4?x=1&y=2")!, kind: .video),
        ])
    }

    func testFacebookVideoResolutionRequestsDesktopPage() async {
        let source = URL(string: "https://www.facebook.com/TheOnion/videos/openai-announces-construction-of-new-data-center-on-top-of-sick-child/3928133123988446/")!
        var userAgents: [String] = []
        let resolver = SocialMediaResolver { request in
            userAgents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
            return Data(#"{"browser_native_hd_url":"https:\/\/video.example.com\/facebook.mp4?token=one\u00253D"}"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(userAgents.first, MediaDownloadHTTP.desktopBrowserUserAgent)
        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/facebook.mp4?token=one%3D")!, kind: .video),
        ])
    }

    func testFacebookReelResolvesViaVideoPluginEmbed() async {
        // The logged-out reel/video PAGE is frequently a stripped login wall (only
        // og:image, no video), so the `/plugins/video.php` embed — which returns the
        // real `hd_src` MP4 for a public video — is tried FIRST, with the desktop UA.
        // The tracking query (`?fs=…&mibextid=…`) is stripped from the embed's `href`.
        let source = URL(string: "https://www.facebook.com/reel/1661338298308685/?fs=e&mibextid=wwXIfr&fs=e")!
        var firstRequest: (url: String, userAgent: String)?
        let resolver = SocialMediaResolver { request in
            let url = request.url?.absoluteString ?? ""
            if firstRequest == nil {
                firstRequest = (url, request.value(forHTTPHeaderField: "User-Agent") ?? "")
            }
            guard url.contains("plugins/video.php") else { return nil }
            return Data(#"{"hd_src":"https:\/\/video.example.com\/reel-hd.mp4","sd_src":"https:\/\/video.example.com\/reel-sd.mp4"}"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        // HD is preferred over SD.
        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/reel-hd.mp4")!, kind: .video),
        ])
        // The plugin embed is the first request, over the desktop UA.
        XCTAssertEqual(firstRequest?.userAgent, MediaDownloadHTTP.desktopBrowserUserAgent)
        XCTAssertTrue(firstRequest?.url.contains("plugins/video.php") ?? false)
        // Its `href` is the clean permalink — tracking query dropped.
        let href = firstRequest.flatMap { URLComponents(string: $0.url) }?
            .queryItems?.first(where: { $0.name == "href" })?.value
        XCTAssertEqual(href, "https://www.facebook.com/reel/1661338298308685/")
    }

    func testFacebookWatchShortLinkResolvesCanonicalLongPageThenVideo() async {
        // When the plugin embed can't resolve a short link and the desktop page 400s,
        // the fb.watch mobile page still exposes the canonical long-form video URL;
        // that `/videos/` page is then fetched with the desktop UA for its inline JSON.
        let source = URL(string: "https://fb.watch/IerlpQvlv-/?mibextid=wwXIfr")!
        let canonical = "https://www.facebook.com/TheOnion/videos/openai-announces-construction-of-new-data-center-on-top-of-sick-child/3928133123988446/"
        var requests: [(url: String, userAgent: String)] = []
        let resolver = SocialMediaResolver { request in
            let url = request.url?.absoluteString ?? ""
            let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            requests.append((url, ua))
            if url.contains("plugins/video.php") {
                return Data("<html>no embeddable video</html>".utf8) // plugin can't resolve the short link
            }
            if url == canonical {
                return Data(#"{"browser_native_hd_url":"https:\/\/video.example.com\/fbwatch.mp4"}"#.utf8)
            }
            if ua == MediaDownloadHTTP.browserUserAgent {
                return Data(#"<meta property="og:url" content="\#(canonical)">"#.utf8) // mobile page exposes canonical
            }
            return Data("<html><title>Error</title></html>".utf8) // fb.watch desktop page 400-equivalent
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/fbwatch.mp4")!, kind: .video),
        ])
        XCTAssertTrue(requests.first?.url.contains("plugins/video.php") ?? false)
        XCTAssertTrue(requests.contains {
            $0.url == canonical && $0.userAgent == MediaDownloadHTTP.desktopBrowserUserAgent
        })
    }

    func testFacebookReelDesktop400FallsBackToMobilePageOpenGraphVideo() async {
        // `/reel/<id>` links 400 with the desktop UA (fetch → nil), and their
        // canonical is the reel URL itself, so canonical resolution is a no-op. The
        // mobile page's own `og:video` tag is the real playable MP4 — before the
        // fallback these reels resolved to "no media".
        // The canonical (no query) differs from the shared URL (`?fs=e`), so the
        // canonical page IS fetched — but it's another `/reel/` page, which also
        // 400s on the desktop UA. Only the mobile UA gets a body. So: the desktop
        // page 400s (nil), and every mobile fetch returns the reel HTML with og:video.
        let source = URL(string: "https://www.facebook.com/reel/1661338298308685/?fs=e")!
        var userAgents: [String] = []
        let resolver = SocialMediaResolver { request in
            let ua = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            userAgents.append(ua)
            guard ua == MediaDownloadHTTP.browserUserAgent else { return nil } // desktop 400s
            return Data(#"""
            <link rel="canonical" href="https://www.facebook.com/reel/1661338298308685/" />
            <meta property="og:image" content="https://cdn.example.com/poster.jpg">
            <meta property="og:video" content="https://video.example.com/reel.mp4?x=1&amp;y=2">
            """#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/reel.mp4?x=1&y=2")!, kind: .video),
        ])
    }

    func testFacebookInlinePlayableURLResolvesAsVideoBeforePoster() {
        let html = #"""
        <meta property="og:image" content="https://cdn.example.com/poster.jpg">
        {"browser_native_hd_url":"https:\/\/video.example.com\/hd.mp4?token=one\u0026encoded=yes\u00253D\u00253D"}
        """#

        XCTAssertEqual(FacebookMediaParser.assets(fromHTML: html), [
            MediaAsset(url: URL(string: "https://video.example.com/hd.mp4?token=one&encoded=yes%3D%3D")!, kind: .video),
        ])
    }

    func testInstagramReelResolvesEmbedContextVideoBeforePoster() {
        let context = #"{"gql_data":{"shortcode_media":{"is_video":true,"video_url":"https://video.example.com/reel.mp4","display_url":"https://cdn.example.com/reel.jpg"}}}"#
        let literal = String(data: try! JSONSerialization.data(
            withJSONObject: context, options: [.fragmentsAllowed]), encoding: .utf8)!
        let html = #"window.__additionalDataLoaded("/embed/", {"contextJSON": \#(literal)});"#

        XCTAssertEqual(InstagramMediaParser.assetsFromEmbedContextJSON(html), [
            MediaAsset(url: URL(string: "https://video.example.com/reel.mp4")!, kind: .video),
        ])
    }

    func testTikTokVideoResolvesAsVideoAndRedditIsNotAutoDownloadable() {
        let tiktokHTML = #"""
        <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">
        {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":{"video":{"playAddr":"https://video.example.com/tiktok.mp4"}}}}}}
        </script>
        """#

        XCTAssertEqual(TikTokMediaParser.assets(fromHTML: tiktokHTML), [
            MediaAsset(url: URL(string: "https://video.example.com/tiktok.mp4")!, kind: .video),
        ])

        let reddit = "https://www.reddit.com/r/videos/comments/abc123/title/"
        XCTAssertEqual(PlatformRecognizer.recognize(reddit)?.platform, .reddit)
        XCTAssertFalse(MediaDownloadablePlatform.supports(reddit))
    }
}
