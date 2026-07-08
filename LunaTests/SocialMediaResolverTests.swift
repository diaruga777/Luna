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

    func testFacebookWatchShortLinkResolvesCanonicalLongPageThenVideo() async {
        let source = URL(string: "https://fb.watch/IerlpQvlv-/?mibextid=wwXIfr")!
        var requests: [(url: String, userAgent: String)] = []
        let resolver = SocialMediaResolver { request in
            requests.append((
                request.url?.absoluteString ?? "",
                request.value(forHTTPHeaderField: "User-Agent") ?? ""))
            if requests.count == 1 {
                return Data("<html><title>Error</title></html>".utf8)
            }
            if requests.count == 2 {
                return Data(#"<meta property="og:url" content="https://www.facebook.com/TheOnion/videos/openai-announces-construction-of-new-data-center-on-top-of-sick-child/3928133123988446/">"#.utf8)
            }
            return Data(#"{"browser_native_hd_url":"https:\/\/video.example.com\/fbwatch.mp4"}"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(requests.map(\.userAgent), [
            MediaDownloadHTTP.desktopBrowserUserAgent,
            MediaDownloadHTTP.browserUserAgent,
            MediaDownloadHTTP.desktopBrowserUserAgent,
        ])
        XCTAssertEqual(requests.last?.url, "https://www.facebook.com/TheOnion/videos/openai-announces-construction-of-new-data-center-on-top-of-sick-child/3928133123988446/")
        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/fbwatch.mp4")!, kind: .video),
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
        let literal = String(data: try! JSONSerialization.data(withJSONObject: context), encoding: .utf8)!
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
