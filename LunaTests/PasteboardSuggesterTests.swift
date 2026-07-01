//
//  PasteboardSuggesterTests.swift
//  LunaTests
//

import LunaReadingList
import LunaYouTubeAPI
import LunaStorage
import XCTest
@testable import Luna

/// Returns canned YouTube metadata (or throws) without touching the network.
private struct MockYouTubeMetadataFetcher: YouTubeMetadataFetching {
    var metadata: (title: String, channelName: String?)?

    func fetchMetadata(videoID: String) async throws -> (title: String, channelName: String?) {
        guard let metadata else { throw URLError(.badServerResponse) }
        return metadata
    }

    func fetchThumbnail(videoID: String) async throws -> Data {
        throw URLError(.badServerResponse)
    }
}

final class PasteboardSuggesterTests: XCTestCase {

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteboardSuggester-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func suggester(youtubeTitle: String? = nil) -> PasteboardSuggester {
        let mock = MockYouTubeMetadataFetcher(
            metadata: youtubeTitle.map { ($0, "Some Channel") })
        return PasteboardSuggester(store: store, youTubeMetadataFetcher: mock)
    }

    func testNonHTTPURLIsRejected() async {
        let result = await suggester().evaluate(urlString: "ftp://example.com/file")
        XCTAssertNil(result)
    }

    func testGarbageIsRejected() async {
        let result = await suggester().evaluate(urlString: "not a url at all")
        XCTAssertNil(result)
    }

    func testAlreadySavedURLIsRejected() async {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        _ = store.add(urlString: url)
        let result = await suggester(youtubeTitle: "Never Gonna Give You Up").evaluate(urlString: url)
        XCTAssertNil(result, "a URL already in the list shouldn't be suggested again")
    }

    func testYouTubeURLBecomesVideoCandidate() async {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let result = await suggester(youtubeTitle: "Never Gonna Give You Up").evaluate(urlString: url)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isVideo ?? false)
        XCTAssertEqual(result?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(result?.title, "Never Gonna Give You Up")
        XCTAssertNil(result?.content)
    }

    func testYouTubeURLRejectedWhenMetadataUnavailable() async {
        // Mock with no metadata throws → not extractable.
        let result = await suggester(youtubeTitle: nil)
            .evaluate(urlString: "https://youtu.be/dQw4w9WgXcQ")
        XCTAssertNil(result)
    }

    /// Bug 2 regression: a Facebook `fbrpc://` deep link on the pasteboard must be
    /// offline-unwrapped to its real http target BEFORE the http-scheme gate — exactly
    /// as the in-app "+" path does — so it produces a candidate. Before the fix the
    /// non-http `fbrpc` scheme was rejected outright, so a Facebook link auto-detected
    /// on the pasteboard failed while the SAME url via "+" succeeded.
    func testFacebookDeepLinkOnPasteboardIsUnwrappedToCandidate() async {
        // An fbrpc deep link whose target is a YouTube watch URL: unwrapping it offline
        // yields a real http(s) URL that the YouTube branch then recognizes (so the
        // test needs no article fetcher — it exercises the unwrap → scheme-gate path).
        let fbrpc = "fbrpc://nativethirdparty/f?app_id=123"
            + "&target_url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"
        let result = await suggester(youtubeTitle: "Never Gonna Give You Up")
            .evaluate(urlString: fbrpc)
        XCTAssertNotNil(result, "an fbrpc Facebook link should unwrap and become a candidate")
        XCTAssertTrue(result?.isVideo ?? false)
        XCTAssertEqual(result?.videoID, "dQw4w9WgXcQ")
    }
}
