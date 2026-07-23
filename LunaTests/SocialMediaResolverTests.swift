//
//  SocialMediaResolverTests.swift
//  LunaTests
//

@testable import LunaMediaDownload
import AVFoundation
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

    func testFacebookResolutionURLDropsShareTrackingButPreservesWatchIdentity() throws {
        let trackedReel = try XCTUnwrap(URL(string:
            "https://www.facebook.com/reel/1816111149377525/?fs=e&mibextid=wwXIfr&fs=e"))
        XCTAssertEqual(
            SocialMediaResolver.facebookResolutionURL(for: trackedReel).absoluteString,
            "https://www.facebook.com/reel/1816111149377525/")

        let trackedWatch = try XCTUnwrap(URL(string:
            "https://www.facebook.com/watch/?v=3928133123988446&mibextid=wwXIfr&fs=e"))
        XCTAssertEqual(
            SocialMediaResolver.facebookResolutionURL(for: trackedWatch).absoluteString,
            "https://www.facebook.com/watch/?v=3928133123988446")

        let shortLink = try XCTUnwrap(URL(string:
            "https://fb.watch/IerlpQvlv-/?mibextid=wwXIfr"))
        XCTAssertEqual(
            SocialMediaResolver.facebookResolutionURL(for: shortLink).absoluteString,
            "https://fb.watch/IerlpQvlv-/")
    }

    func testTrackedFacebookReelsResolveFromCrawlerInlineJSON() async throws {
        let reportedURLs = [
            "https://www.facebook.com/reel/1816111149377525/?fs=e&mibextid=wwXIfr&fs=e",
            "https://www.facebook.com/reel/1351648773689048/?fs=e&mibextid=wwXIfr&fs=e",
        ]

        for rawURL in reportedURLs {
            let source = try XCTUnwrap(URL(string: rawURL))
            var crawlerURL: URL?
            let resolver = SocialMediaResolver { request in
                guard request.value(forHTTPHeaderField: "User-Agent")
                        == MediaDownloadHTTP.facebookCrawlerUserAgent else {
                    return Data("<html>metadata-free Facebook shell</html>".utf8)
                }
                crawlerURL = request.url
                return Data(#"{"browser_native_hd_url":"https:\/\/video.example.com\/reel.mp4?x=1\u0026y=2"}"#.utf8)
            }

            let assets = await resolver.resolveAssets(for: source)

            XCTAssertEqual(assets, [
                MediaAsset(
                    url: URL(string: "https://video.example.com/reel.mp4?x=1&y=2")!,
                    kind: .video),
            ], rawURL)
            XCTAssertEqual(
                crawlerURL?.absoluteString,
                "https://www.facebook.com/reel/\(PlatformRecognizer.recognize(rawURL)!.itemID!)/",
                rawURL)
        }
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
            MediaAsset(
                url: URL(string: "https://video.example.com/reel.mp4?x=1&y=2")!,
                kind: .video,
                thumbnailURL: URL(string: "https://cdn.example.com/poster.jpg")!),
        ])
    }

    func testReportedFacebookReelUsesCookieFreeUncachedMobileFallback() async {
        let source = URL(string: "https://www.facebook.com/reel/2555554881528124/")!
        var mobileRequest: URLRequest?
        let resolver = SocialMediaResolver { request in
            guard request.value(forHTTPHeaderField: "User-Agent")
                    == MediaDownloadHTTP.browserUserAgent else { return nil }
            mobileRequest = request
            // Facebook varies attribute order and sometimes emits `name` instead of
            // `property`; both are valid Open Graph representations seen in the wild.
            return Data(#"<meta content='https://video.example.com/reel.mp4?x=1&amp;y=2' name='og:video:secure_url'>"#.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/reel.mp4?x=1&y=2")!, kind: .video),
        ])
        XCTAssertEqual(mobileRequest?.httpShouldHandleCookies, false)
        XCTAssertEqual(mobileRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(mobileRequest?.value(forHTTPHeaderField: "Accept-Language"), "en-US,en;q=0.9")
    }

    func testFacebookInlinePlayableURLResolvesAsVideoBeforePoster() {
        let html = #"""
        <meta property="og:image" content="https://cdn.example.com/poster.jpg">
        {"browser_native_hd_url":"https:\/\/video.example.com\/hd.mp4?token=one\u0026encoded=yes\u00253D\u00253D"}
        """#

        XCTAssertEqual(FacebookMediaParser.assets(fromHTML: html), [
            MediaAsset(
                url: URL(string: "https://video.example.com/hd.mp4?token=one&encoded=yes%3D%3D")!,
                kind: .video,
                thumbnailURL: URL(string: "https://cdn.example.com/poster.jpg")!),
        ])
    }

    func testInstagramReelResolvesEmbedContextVideoBeforePoster() {
        let context = #"{"gql_data":{"shortcode_media":{"is_video":true,"video_url":"https://video.example.com/reel.mp4","display_url":"https://cdn.example.com/reel.jpg"}}}"#
        let literal = String(data: try! JSONSerialization.data(
            withJSONObject: context, options: [.fragmentsAllowed]), encoding: .utf8)!
        let html = #"window.__additionalDataLoaded("/embed/", {"contextJSON": \#(literal)});"#

        XCTAssertEqual(InstagramMediaParser.assetsFromEmbedContextJSON(html), [
            MediaAsset(
                url: URL(string: "https://video.example.com/reel.mp4")!, kind: .video,
                thumbnailURL: URL(string: "https://cdn.example.com/reel.jpg")!),
        ])
    }

    func testTikTokVideoResolvesAsVideoAndRedditIsAutoDownloadable() {
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
        XCTAssertTrue(MediaDownloadablePlatform.supports(reddit))
    }

    func testTikTokSharedLinkReflowPayloadResolvesAsVideo() async {
        let source = URL(string: "https://www.tiktok.com/t/ZP8Gqx5p5/")!
        let html = #"""
        <script type="application/json" id="__UNIVERSAL_DATA_FOR_REHYDRATION__">
        {"__DEFAULT_SCOPE__":{"webapp.reflow.video.detail":{"itemInfo":{"itemStruct":{"video":{"playAddr":"https://video.example.com/reflow.mp4","downloadAddr":"https://video.example.com/watermarked.mp4"}}}}}}
        </script>
        """#
        var requestedURL: URL?
        let resolver = SocialMediaResolver { request in
            requestedURL = request.url
            return Data(html.utf8)
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(requestedURL, source)
        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://video.example.com/reflow.mp4")!, kind: .video),
        ])
    }

    func testTikTokReflowPayloadFallsBackToDownloadAddress() {
        let html = #"""
        <script data-extra="ignored" id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">
        {"__DEFAULT_SCOPE__":{"webapp.reflow.video.detail":{"itemInfo":{"itemStruct":{"video":{"playAddr":"","downloadAddr":"https://video.example.com/download.mp4"}}}}}}
        </script>
        """#

        XCTAssertEqual(TikTokMediaParser.assets(fromHTML: html), [
            MediaAsset(url: URL(string: "https://video.example.com/download.mp4")!, kind: .video),
        ])
    }

    func testYouTubeURLFamilyNormalizesVideoIDAndTimestampRange() throws {
        let cases: [(String, Double)] = [
            ("https://youtu.be/dQw4w9WgXcQ?t=1m30s", 90),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ&start=45", 45),
            ("https://www.youtube.com/shorts/dQw4w9WgXcQ#t=12s", 12),
            ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", 0),
        ]
        for (raw, expectedStart) in cases {
            let link = try XCTUnwrap(URL(string: raw).flatMap(YouTubeLink.init(url:)))
            XCTAssertEqual(link.videoID, "dQw4w9WgXcQ", raw)
            XCTAssertEqual(link.timeRange?.startSeconds ?? 0, expectedStart, raw)
            XCTAssertEqual(link.canonicalWatchURL?.absoluteString,
                           "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        }
        let ranged = try XCTUnwrap(YouTubeLink(
            url: URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ&t=5&end=15")!))
        XCTAssertEqual(ranged.timeRange, MediaTimeRange(startSeconds: 5, endSeconds: 15))
    }

    func testReportedYouTubeURLsNormalizeToTheirVideoIDs() throws {
        let short = try XCTUnwrap(YouTubeLink(url: URL(string:
            "https://youtube.com/shorts/bcHXFQIZ4lY?si=5yVkolWnfCb8U4N9")!))
        XCTAssertEqual(short.videoID, "bcHXFQIZ4lY")

        let full = try XCTUnwrap(YouTubeLink(url: URL(string:
            "https://youtu.be/JFryZD88SBo?si=mIacqZSqFo_TXiYk")!))
        XCTAssertEqual(full.videoID, "JFryZD88SBo")
    }

    func testYouTubePlaybackBootstrapParsesVisitorAndPlayerJavaScript() throws {
        let page = #"""
        <script>
        ytcfg.set({"VISITOR_DATA":"CgtVisitor%3D%3D","WEB_PLAYER_CONTEXT_CONFIGS":{
          "WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH":{"jsUrl":"\/s\/player\/c80bf7e2\/player_es6.vflset\/en_US\/base.js"}
        }});
        </script>
        """#
        let bootstrap = try XCTUnwrap(
            YouTubePlaybackBootstrapParser.bootstrap(fromWatchData: Data(page.utf8)))

        XCTAssertEqual(bootstrap.visitorData, "CgtVisitor==")
        XCTAssertEqual(
            bootstrap.playerJavaScriptURL.absoluteString,
            "https://www.youtube.com/s/player/c80bf7e2/player_es6.vflset/en_US/base.js")
        XCTAssertEqual(
            YouTubePlaybackBootstrapParser.signatureTimestamp(
                fromPlayerJavaScript: Data("const x={signatureTimestamp:20654};".utf8)),
            20_654)
    }

    func testYouTubeResolverUsesGuestBoundAndroidVRPlayerClient() async throws {
        let source = URL(string:
            "https://youtube.com/shorts/bcHXFQIZ4lY?si=reported")!
        var requests: [URLRequest] = []
        let resolver = SocialMediaResolver { request in
            requests.append(request)
            switch request.url?.path {
            case "/watch":
                return Data(#"""
                <script>
                ytcfg.set({"VISITOR_DATA":"CgtVisitor%3D%3D","WEB_PLAYER_CONTEXT_CONFIGS":{
                  "WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH":{"jsUrl":"\/s\/player\/hash\/player_es6.vflset\/en_US\/base.js"}
                }});
                </script>
                """#.utf8)
            case "/s/player/hash/player_es6.vflset/en_US/base.js":
                return Data("const config={sts:20654};".utf8)
            case "/youtubei/v1/player":
                return Data(#"""
                {"streamingData":{"formats":[{
                  "itag":18,
                  "mimeType":"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                  "url":"https://video.example.com/youtube.mp4",
                  "audioQuality":"AUDIO_QUALITY_LOW",
                  "height":640,
                  "contentLength":"123456"
                }]}}
                """#.utf8)
            default:
                return nil
            }
        }

        let assets = await resolver.resolveAssets(for: source)

        XCTAssertEqual(assets.first?.url.absoluteString,
                       "https://video.example.com/youtube.mp4")
        XCTAssertEqual(requests.count, 3)
        let playerRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(playerRequest.httpMethod, "POST")
        XCTAssertEqual(
            playerRequest.value(forHTTPHeaderField: "User-Agent"),
            YouTubeMediaResolver.androidVRUserAgent)
        XCTAssertEqual(
            playerRequest.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "28")
        XCTAssertEqual(
            playerRequest.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
            "CgtVisitor==")
        let body = try XCTUnwrap(playerRequest.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["videoId"] as? String, "bcHXFQIZ4lY")
        let playback = try XCTUnwrap(object["playbackContext"] as? [String: Any])
        let content = try XCTUnwrap(
            playback["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(content["signatureTimestamp"] as? Int, 20_654)
    }

    func testYouTubePlayerResponseSelectsProgressiveMP4WithAudioAndPoster() throws {
        let response = #"""
        {"streamingData":{"formats":[
          {"mimeType":"video/mp4; codecs=\"avc1, mp4a\"","url":"https://video.example.com/360.mp4","audioQuality":"AUDIO_QUALITY_MEDIUM","height":360,"bitrate":800000,"contentLength":"12000000"},
          {"mimeType":"video/mp4; codecs=\"avc1, mp4a\"","url":"https://video.example.com/720.mp4","audioQuality":"AUDIO_QUALITY_MEDIUM","height":720,"bitrate":2000000,"contentLength":"30000000"},
          {"mimeType":"video/mp4; codecs=\"avc1\"","signatureCipher":"url=https%3A%2F%2Fvideo.example.com%2Fciphered.mp4","height":1080,"bitrate":5000000}
        ]},"videoDetails":{"lengthSeconds":"120","thumbnail":{"thumbnails":[{"url":"https://img.example.com/small.jpg"},{"url":"https://img.example.com/large.jpg"}]}}}
        """#

        let asset = try XCTUnwrap(YouTubePlayerResponseParser.asset(
            from: Data(response.utf8), videoID: "dQw4w9WgXcQ",
            timeRange: MediaTimeRange(startSeconds: 10, endSeconds: 20)))

        XCTAssertEqual(asset.url.absoluteString, "https://video.example.com/720.mp4")
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.thumbnailURL?.absoluteString, "https://img.example.com/large.jpg")
        XCTAssertEqual(asset.estimatedByteCount, 30_000_000)
        XCTAssertEqual(asset.timeRange, MediaTimeRange(startSeconds: 10, endSeconds: 20))
    }

    func testYouTubeHTMLParserSkipsNullPlayerResponseBeforeRealAssignment() throws {
        let html = #"""
        <script>var ytInitialPlayerResponse = null;</script>
        <script>var unrelated = {"formats":"not a player"};</script>
        <script>var ytInitialPlayerResponse = {"streamingData":{"formats":[{"mimeType":"video/mp4; codecs=\"avc1, mp4a\"","url":"https://video.example.com/direct.mp4","audioQuality":"AUDIO_QUALITY_MEDIUM","height":360,"bitrate":800000}]}};</script>
        """#
        let asset = try XCTUnwrap(YouTubePlayerResponseParser.asset(
            from: Data(html.utf8), videoID: "dQw4w9WgXcQ", timeRange: nil))
        XCTAssertEqual(asset.url.absoluteString, "https://video.example.com/direct.mp4")
    }

    func testYouTubeClipParserFindsUnderlyingVideoAndRange() throws {
        let html = #"<script>var clipConfig={\"videoId\":\"dQw4w9WgXcQ\",\"startTimeMs\":\"12500\",\"endTimeMs\":\"28750\"};</script>"#
        let descriptor = try XCTUnwrap(YouTubeClipParser.descriptor(fromHTML: html))
        XCTAssertEqual(descriptor.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(descriptor.timeRange,
                       MediaTimeRange(startSeconds: 12.5, endSeconds: 28.75))
    }

    func testLiveReportedYouTubeDownloads() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_YOUTUBE_TESTS"] == "1"
        else {
            throw XCTSkip("Set RUN_LIVE_YOUTUBE_TESTS=1 for real YouTube transfers")
        }
        let reportedURLs = [
            "https://youtube.com/shorts/bcHXFQIZ4lY?si=5yVkolWnfCb8U4N9",
            "https://youtu.be/JFryZD88SBo?si=mIacqZSqFo_TXiYk",
        ]

        for rawURL in reportedURLs {
            let source = try XCTUnwrap(URL(string: rawURL))
            let resolved = await SocialMediaResolver().resolveAssets(for: source)
            let media = try XCTUnwrap(resolved.first, rawURL)
            let fileURL = try await MediaFileDownloader.download(
                media,
                referer: "https://www.youtube.com/",
                onProgress: { _ in })
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let size = try XCTUnwrap(
                try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertGreaterThan(size, 500_000, rawURL)
            let movie = AVURLAsset(url: fileURL)
            let videoTracks = try await movie.loadTracks(withMediaType: .video)
            let audioTracks = try await movie.loadTracks(withMediaType: .audio)
            XCTAssertFalse(videoTracks.isEmpty, rawURL)
            XCTAssertFalse(audioTracks.isEmpty, rawURL)
        }
    }

    func testLiveBackgroundManagerDownloadsReportedYouTubeShort() async throws {
        guard ProcessInfo.processInfo.environment[
            "RUN_LIVE_YOUTUBE_BACKGROUND_TESTS"] == "1"
        else {
            throw XCTSkip(
                "Set RUN_LIVE_YOUTUBE_BACKGROUND_TESTS=1 for the background transfer")
        }
        let rawURL =
            "https://youtube.com/shorts/bcHXFQIZ4lY?si=5yVkolWnfCb8U4N9"
        guard SavedMediaStore.shared.matchingItem(forURLString: rawURL) == nil
        else {
            throw XCTSkip("The exact live-test video is already in the Downloader library")
        }

        let originalPhotosSetting = AutoDownloadSettings.autoSaveDownloadsToPhotos
        let wasMarkedDownloaded = AutoDownloadSettings.wasDownloaded(rawURL)
        AutoDownloadSettings.autoSaveDownloadsToPhotos = false
        AutoDownloadSettings.unmarkDownloaded(rawURL)
        defer {
            if let created = SavedMediaStore.shared.matchingItem(forURLString: rawURL) {
                SavedMediaStore.shared.delete(created)
            }
            AutoDownloadSettings.autoSaveDownloadsToPhotos = originalPhotosSetting
            if wasMarkedDownloaded {
                AutoDownloadSettings.markDownloaded(rawURL)
            } else {
                AutoDownloadSettings.unmarkDownloaded(rawURL)
            }
        }

        // The app owns exactly one delegate for its named background session.
        // Exercise that singleton here as production does; creating a second
        // delegate with the same identifier causes nsurlsessiond to deliver
        // completion to whichever session registered first.
        let manager = LiveMediaDownloadManager.shared
        let started = await manager.start(
            urlString: rawURL,
            title: "Live YouTube background download",
            ownership: .downloader,
            manual: true)
        XCTAssertTrue(started)

        let result = await withTaskGroup(of: SavedMediaItem?.self) { group in
            group.addTask {
                await manager.waitForDownloaderResult(forSourceURLString: rawURL)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let downloaded = try XCTUnwrap(result)
        let fileURL = try XCTUnwrap(downloaded.fileURL)
        let size = try XCTUnwrap(
            try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 500_000)

        let movie = AVURLAsset(url: fileURL)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
    }
}
