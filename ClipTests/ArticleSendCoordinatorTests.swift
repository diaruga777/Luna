//
//  ArticleSendCoordinatorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// A configurable in-memory destination that records sends.
private final class MockDestination: ArticleDestination {
    struct SendFailure: Error {}

    let id: String
    let displayName = "Mock"
    var configured = true
    var mode: ArticleSendMode = .off
    var shouldFail = false
    private(set) var sentTitles: [String] = []

    init(id: String) { self.id = id }

    var isConfigured: Bool { configured }
    var sendMode: ArticleSendMode { mode }

    func send(epubData: Data, fileName: String, title: String) async throws {
        if shouldFail { throw SendFailure() }
        XCTAssertFalse(epubData.isEmpty)
        XCTAssertTrue(fileName.hasSuffix(".epub"))
        sentTitles.append(title)
    }
}

final class ArticleSendCoordinatorTests: XCTestCase {

    private var store: ReadingListStore!
    private var scratchDirectory: URL!
    private var kindle: MockDestination!
    private var boox: MockDestination!
    private var coordinator: ArticleSendCoordinator!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratchDirectory)
        kindle = MockDestination(id: ArticleDestinationID.kindle)
        boox = MockDestination(id: ArticleDestinationID.boox)
        coordinator = ArticleSendCoordinator(store: store, destinations: [kindle, boox])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func makeReadyItem(_ url: String = "https://example.com/article") -> ReadingListItem {
        let item = store.add(urlString: url)
        let content = ArticleContent(
            title: "An Article",
            blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])])
        return store.saveContent(content, for: item)
    }

    private func sendState(_ item: ReadingListItem, _ destinationID: String) -> ReadingListItem.SendState? {
        store.item(withID: item.id)?.sendState(for: destinationID)
    }

    func testSendIsNoOpWhenDestinationNotConfigured() async {
        kindle.configured = false
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)
        XCTAssertTrue(kindle.sentTitles.isEmpty)
        XCTAssertNil(sendState(item, kindle.id))
    }

    func testSendQueuesWhileArticleIsStillPending() async {
        let item = store.add(urlString: "https://example.com/pending")
        await coordinator.send(item, toDestinationID: kindle.id)
        XCTAssertTrue(kindle.sentTitles.isEmpty)
        XCTAssertEqual(sendState(item, kindle.id), .queued)
    }

    func testSuccessfulSendMarksSentWithDate() async {
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)
        XCTAssertEqual(kindle.sentTitles, ["An Article"])
        XCTAssertEqual(sendState(item, kindle.id), .sent)
        XCTAssertNotNil(store.item(withID: item.id)?.dateSent(for: kindle.id))
    }

    func testFailedSendMarksFailed() async {
        kindle.shouldFail = true
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)
        XCTAssertEqual(sendState(item, kindle.id), .failed)
        XCTAssertNil(store.item(withID: item.id)?.dateSent(for: kindle.id))
    }

    func testExplicitSendTargetsOnlyOneDestination() async {
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: boox.id)
        XCTAssertEqual(boox.sentTitles, ["An Article"])
        XCTAssertTrue(kindle.sentTitles.isEmpty)
        XCTAssertEqual(sendState(item, boox.id), .sent)
        XCTAssertNil(sendState(item, kindle.id))
    }

    func testArticleBecameReadySendsQueuedItem() async {
        kindle.mode = .off
        let item = makeReadyItem()
        store.setSendState(.queued, for: item.id, destination: kindle.id)
        guard let fresh = store.item(withID: item.id) else { return XCTFail("item gone") }
        coordinator.articleBecameReady(fresh)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sendState(item, kindle.id), .sent)
    }

    func testArticleBecameReadySendsToAllAllSavesDestinations() async {
        kindle.mode = .allSaves
        boox.mode = .allSaves
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(sendState(item, kindle.id), .sent)
        XCTAssertEqual(sendState(item, boox.id), .sent)
    }

    func testArticleBecameReadyRespectsPerDestinationMode() async {
        kindle.mode = .allSaves
        boox.mode = .off
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(sendState(item, kindle.id), .sent)
        XCTAssertNil(sendState(item, boox.id))
        XCTAssertTrue(boox.sentTitles.isEmpty)
    }

    func testDoubleSaveDestinationIDsReflectsConfiguredDoubleSave() {
        kindle.mode = .doubleSave
        boox.mode = .off
        XCTAssertEqual(coordinator.doubleSaveDestinationIDs(), [kindle.id])
        boox.mode = .doubleSave
        XCTAssertEqual(Set(coordinator.doubleSaveDestinationIDs()), [kindle.id, boox.id])
        kindle.configured = false
        XCTAssertEqual(coordinator.doubleSaveDestinationIDs(), [boox.id])
    }

    func testRetryPendingSendsRetriesQueuedAndFailedPerDestination() async {
        let queued = makeReadyItem("https://example.com/queued")
        store.setSendState(.queued, for: queued.id, destination: kindle.id)
        let failed = makeReadyItem("https://example.com/failed")
        store.setSendState(.failed, for: failed.id, destination: boox.id)

        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sendState(queued, kindle.id), .sent)
        XCTAssertEqual(sendState(failed, boox.id), .sent)
    }
}
