//
//  ReadingListStoreTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ReadingListStoreTests: XCTestCase {

    // A scratch-directory store — never the shared one, which holds real data.
    private var store: ReadingListStore!
    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingListStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    func testAddListAndDelete() {
        let item = store.add(urlString: "https://example.com/a")
        XCTAssertEqual(store.items().first?.id, item.id)
        XCTAssertEqual(store.items().first?.state, .pending)

        store.delete(item)
        XCTAssertFalse(store.items().contains { $0.id == item.id })
    }

    func testAddIsIdempotentPerURL() {
        let first = store.add(urlString: "https://example.com/same")
        let second = store.add(urlString: "https://example.com/same")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.items().filter { $0.urlString == "https://example.com/same" }.count, 1)
    }

    func testSaveAndLoadContentRoundTrip() {
        let item = store.add(urlString: "https://example.com/content")
        let content = ArticleContent(
            title: "Title",
            blocks: [ArticleContent.Block(
                kind: .paragraph, text: "Hello world",
                links: [ArticleContent.Link(start: 0, length: 5, urlString: "https://x.com")])])

        let updated = store.saveContent(content, for: item)
        XCTAssertEqual(updated.state, .ready)
        XCTAssertEqual(updated.title, "Title")

        let loaded = store.content(for: updated)
        XCTAssertEqual(loaded?.blocks.first?.text, "Hello world")
        XCTAssertEqual(loaded?.blocks.first?.links.first?.length, 5)
    }
}
