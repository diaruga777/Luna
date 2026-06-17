//
//  MediaDownloadTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class MediaDownloadTests: XCTestCase {

    // MARK: - Platform support

    func testSupportedPlatforms() {
        XCTAssertTrue(MediaDownloadablePlatform.supports("https://x.com/jack/status/20"))
        XCTAssertTrue(MediaDownloadablePlatform.supports("https://www.instagram.com/p/ABC123/"))
        XCTAssertTrue(MediaDownloadablePlatform.supports("https://www.tiktok.com/@user/video/123"))
        XCTAssertFalse(MediaDownloadablePlatform.supports("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertFalse(MediaDownloadablePlatform.supports("https://example.com/article"))
        XCTAssertFalse(MediaDownloadablePlatform.supports("https://reddit.com/r/swift/comments/1/x"))
    }

    // MARK: - X (fxtwitter) parsing

    func testXParserUsesOrderedAllMedia() {
        let json = """
        {"tweet":{"media":{"all":[
          {"type":"photo","url":"https://pbs.twimg.com/a.jpg"},
          {"type":"video","url":"https://video.twimg.com/b.mp4"},
          {"type":"gif","url":"https://video.twimg.com/c.mp4"}
        ]}}}
        """
        let assets = XMediaParser.assets(fromFxJSON: Data(json.utf8))
        XCTAssertEqual(assets, [
            MediaAsset(url: URL(string: "https://pbs.twimg.com/a.jpg")!, kind: .image),
            MediaAsset(url: URL(string: "https://video.twimg.com/b.mp4")!, kind: .video),
            MediaAsset(url: URL(string: "https://video.twimg.com/c.mp4")!, kind: .video),
        ])
    }

    func testXParserFallsBackToPhotosVideos() {
        let json = """
        {"tweet":{"media":{"videos":[{"url":"https://video.twimg.com/b.mp4"}],
                           "photos":[{"url":"https://pbs.twimg.com/a.jpg"}]}}}
        """
        let assets = XMediaParser.assets(fromFxJSON: Data(json.utf8))
        XCTAssertEqual(assets.first, MediaAsset(url: URL(string: "https://video.twimg.com/b.mp4")!, kind: .video))
        XCTAssertEqual(assets.count, 2)
    }

    func testXParserEmptyWhenNoMedia() {
        XCTAssertTrue(XMediaParser.assets(fromFxJSON: Data("{\"tweet\":{}}".utf8)).isEmpty)
    }

    // MARK: - TikTok parsing

    func testTikTokParserVideoPrefersPlayAddr() {
        let html = """
        <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">\
        {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":\
        {"video":{"playAddr":"https://v.tiktok.com/play.mp4","downloadAddr":"https://v.tiktok.com/wm.mp4"}}}}}}\
        </script>
        """
        XCTAssertEqual(
            TikTokMediaParser.assets(fromHTML: html),
            [MediaAsset(url: URL(string: "https://v.tiktok.com/play.mp4")!, kind: .video)])
    }

    func testTikTokParserImageCarousel() {
        let html = """
        <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">\
        {"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":\
        {"imagePost":{"images":[\
        {"imageURL":{"urlList":["https://p.tiktok.com/1.jpg","https://p.tiktok.com/1b.jpg"]}},\
        {"imageURL":{"urlList":["https://p.tiktok.com/2.jpg"]}}]}}}}}}\
        </script>
        """
        XCTAssertEqual(TikTokMediaParser.assets(fromHTML: html), [
            MediaAsset(url: URL(string: "https://p.tiktok.com/1.jpg")!, kind: .image),
            MediaAsset(url: URL(string: "https://p.tiktok.com/2.jpg")!, kind: .image),
        ])
    }

    func testTikTokParserEmptyWithoutRehydration() {
        XCTAssertTrue(TikTokMediaParser.assets(fromHTML: "<html>no json</html>").isEmpty)
    }

    // MARK: - Instagram parsing

    func testInstagramParserVideoURL() {
        let html = #"<div>...{"video_url":"https:\/\/scontent.cdninstagram.com\/v.mp4?a&b"}...</div>"#
        XCTAssertEqual(
            InstagramMediaParser.assets(fromHTML: html),
            [MediaAsset(url: URL(string: "https://scontent.cdninstagram.com/v.mp4?a&b")!, kind: .video)])
    }

    func testInstagramParserImageFallback() {
        let html = #"<meta property="og:image" content="https://scontent/i.jpg" />"#
        XCTAssertEqual(
            InstagramMediaParser.assets(fromHTML: html),
            [MediaAsset(url: URL(string: "https://scontent/i.jpg")!, kind: .image)])
    }

    func testInstagramUnescape() {
        XCTAssertEqual(
            InstagramMediaParser.unescape(#"https:\/\/x\/a&b&amp;c"#),
            "https://x/a&b&c")
    }

    // MARK: - File extension selection

    func testFileExtensionByKindAndMime() {
        let video = MediaAsset(url: URL(string: "https://x/v")!, kind: .video)
        XCTAssertEqual(MediaFileDownloader.fileExtension(for: video, mimeType: "video/mp4"), "mp4")

        let gif = MediaAsset(url: URL(string: "https://x/g")!, kind: .gif)
        XCTAssertEqual(MediaFileDownloader.fileExtension(for: gif, mimeType: nil), "gif")

        let png = MediaAsset(url: URL(string: "https://x/a.png")!, kind: .image)
        XCTAssertEqual(MediaFileDownloader.fileExtension(for: png, mimeType: "image/png"), "png")

        let jpgByExt = MediaAsset(url: URL(string: "https://x/a.jpg")!, kind: .image)
        XCTAssertEqual(MediaFileDownloader.fileExtension(for: jpgByExt, mimeType: nil), "jpg")

        let unknownImage = MediaAsset(url: URL(string: "https://x/a")!, kind: .image)
        XCTAssertEqual(MediaFileDownloader.fileExtension(for: unknownImage, mimeType: nil), "jpg")
    }

    // MARK: - Resolver dispatch (parser wiring, injected fetch)

    func testResolverDispatchesXToParser() async {
        let json = Data("""
        {"tweet":{"media":{"all":[{"type":"video","url":"https://video.twimg.com/b.mp4"}]}}}
        """.utf8)
        let resolver = SocialMediaResolver(fetch: { _ in json })
        let assets = await resolver.resolveAssets(for: URL(string: "https://x.com/jack/status/20")!)
        XCTAssertEqual(assets, [MediaAsset(url: URL(string: "https://video.twimg.com/b.mp4")!, kind: .video)])
    }

    func testResolverReturnsEmptyForUnsupported() async {
        let resolver = SocialMediaResolver(fetch: { _ in Data() })
        let assets = await resolver.resolveAssets(for: URL(string: "https://example.com/x")!)
        XCTAssertTrue(assets.isEmpty)
    }
}
