//
//  ReadingListStoreTests.swift
//  ClipTests
//

import ClipStorage
import ClipModels
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

    func testRecordSaveAttemptReturnsPreviousPressTime() {
        let item = store.add(urlString: "https://example.com/press")

        // First repeat press: the "previous press" is the original save.
        let first = store.recordSaveAttempt(for: item.id)
        XCTAssertEqual(first, item.dateAdded)

        // Second repeat press: the previous press is the first one, just now.
        let second = store.recordSaveAttempt(for: item.id)
        XCTAssertNotNil(second)
        if let second {
            XCTAssertGreaterThanOrEqual(second, item.dateAdded)
            XCTAssertLessThan(Date().timeIntervalSince(second), 5)
        }
    }

    func testSetSendStateStampsDateSentOnlyWhenSent() {
        let item = store.add(urlString: "https://example.com/send")
        let kindle = ArticleDestinationID.kindle

        store.setSendState(.queued, for: item.id, destination: kindle)
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: kindle), .queued)
        XCTAssertNil(store.item(withID: item.id)?.dateSent(for: kindle))

        store.setSendState(.sent, for: item.id, destination: kindle)
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: kindle), .sent)
        XCTAssertNotNil(store.item(withID: item.id)?.dateSent(for: kindle))
    }

    func testSendStatesAreIndependentPerDestination() {
        let item = store.add(urlString: "https://example.com/multi")
        store.setSendState(.sent, for: item.id, destination: ArticleDestinationID.kindle)
        store.setSendState(.failed, for: item.id, destination: ArticleDestinationID.boox)

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: ArticleDestinationID.kindle), .sent)
        XCTAssertEqual(fresh?.sendState(for: ArticleDestinationID.boox), .failed)
    }

    func testTargetedSendMutationsDoNotClobberOtherFields() {
        let item = store.add(urlString: "https://example.com/fields")
        store.setLastWordIndex(42, for: item.id)
        store.setSendState(.sent, for: item.id, destination: ArticleDestinationID.kindle)
        store.recordSaveAttempt(for: item.id)

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.lastWordIndex, 42)
        XCTAssertEqual(fresh?.sendState(for: ArticleDestinationID.kindle), .sent)
        XCTAssertNotNil(fresh?.lastSaveAttemptDate)
    }

    func testItemsSavedWithoutSendFieldsStillDecode() throws {
        // An item persisted before the send feature existed.
        let legacyJSON = """
            [{"id":"\(UUID().uuidString)","urlString":"https://example.com/old",\
            "dateAdded":700000000,"state":"ready","readState":"opened"}]
            """
        try Data(legacyJSON.utf8).write(
            to: scratchDirectory.appendingPathComponent("readingList.json"))

        let items = store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.sendStates.isEmpty ?? false)
        XCTAssertTrue(items.first?.datesSent.isEmpty ?? false)
        XCTAssertNil(items.first?.lastSaveAttemptDate)
    }

    func testLegacySingleSendStateMigratesToKindle() throws {
        // Pre-multi-destination JSON used a single `sendState`/`dateSent`.
        let legacyJSON = """
            [{"id":"\(UUID().uuidString)","urlString":"https://example.com/legacy",\
            "dateAdded":700000000,"state":"ready","readState":"read",\
            "sendState":"sent","dateSent":700000500}]
            """
        try Data(legacyJSON.utf8).write(
            to: scratchDirectory.appendingPathComponent("readingList.json"))

        let item = store.items().first
        XCTAssertEqual(item?.sendState(for: ArticleDestinationID.kindle), .sent)
        XCTAssertEqual(
            item?.dateSent(for: ArticleDestinationID.kindle),
            Date(timeIntervalSinceReferenceDate: 700000500))
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

    func testWebArchivePersistsLocallyAndIsRemovedWithItem() throws {
        let item = store.add(urlString: "https://example.com/original")
        let archive = Data("web archive bytes".utf8)

        store.saveWebArchive(archive, for: item)
        let saved = try XCTUnwrap(store.item(withID: item.id))
        let archiveURL = try XCTUnwrap(store.webArchiveURL(for: saved))
        XCTAssertEqual(try Data(contentsOf: archiveURL), archive)
        XCTAssertTrue(store.hasOriginalSource(for: saved))

        store.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testOriginalDocumentUsesSourceFileAndCleansItUp() throws {
        var item = store.add(urlString: "clipdoc://document")
        item.documentType = "pdf"
        store.restore([item])
        let sourceURL = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.pdf")
        try Data("%PDF-original".utf8).write(to: sourceURL)

        XCTAssertEqual(store.originalDocumentURL(for: item), sourceURL)
        XCTAssertTrue(store.hasOriginalSource(for: item))

        store.delete(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }
}
