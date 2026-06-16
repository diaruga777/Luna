//
//  PasteboardSuggesterTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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
}
