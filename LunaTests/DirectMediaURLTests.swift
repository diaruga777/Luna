import XCTest
import LunaModels
@testable import LunaHTMLClassification
@testable import LunaMediaDownload
@testable import LunaURLClassification

final class DirectMediaURLTests: XCTestCase {
    func testRecognizesSupportedDirectMediaExtensions() throws {
        let cases: [(String, DirectMediaKind)] = [
            ("https://cdn.example.com/photo.JPG?token=abc", .image),
            ("https://cdn.example.com/animation.gif", .gif),
            ("https://cdn.example.com/movie.mp4#play", .video),
            ("https://cdn.example.com/recording.m4a?download=1", .audio),
            ("https://cdn.example.com/podcast.mp3", .audio),
        ]

        for (urlString, expectedKind) in cases {
            XCTAssertEqual(DirectMediaURL.kind(for: urlString), expectedKind, urlString)
            XCTAssertTrue(MediaDownloadablePlatform.supports(urlString), urlString)
        }
    }

    func testRejectsPagesAndNonWebURLs() {
        XCTAssertNil(DirectMediaURL.kind(for: "https://example.com/watch"))
        XCTAssertNil(DirectMediaURL.kind(for: "https://example.com/article.html"))
        XCTAssertNil(DirectMediaURL.kind(for: "file:///tmp/movie.mp4"))
    }

    func testClassifierRoutesDirectMediaToDownloaderBeforeHTMLFetch() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.com/clip.mov?signature=123"))
        XCTAssertEqual(Classifier.classify(url: url), .video(.web, itemID: nil))
    }

    func testResolverReturnsDirectURLWithoutNetworkResolution() async throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.com/song.mp3"))
        let resolver = SocialMediaResolver(fetch: { _ in
            XCTFail("A direct media URL must not fetch a platform page")
            return nil
        })

        let assets = await resolver.resolveAssets(for: url)
        XCTAssertEqual(assets, [MediaAsset(url: url, kind: .audio)])
    }

    func testDownloaderPreservesDirectFileExtension() throws {
        let mov = try XCTUnwrap(URL(string: "https://media.example.com/clip.mov"))
        let mp3 = try XCTUnwrap(URL(string: "https://media.example.com/song.mp3"))
        XCTAssertEqual(
            MediaFileDownloader.fileExtension(
                for: MediaAsset(url: mov, kind: .video), mimeType: "video/quicktime"),
            "mov")
        XCTAssertEqual(
            MediaFileDownloader.fileExtension(
                for: MediaAsset(url: mp3, kind: .audio), mimeType: "audio/mpeg"),
            "mp3")
        XCTAssertFalse(MediaAsset.Kind.audio.canSaveToPhotos)
        XCTAssertTrue(MediaAsset.Kind.video.canSaveToPhotos)
    }
}
