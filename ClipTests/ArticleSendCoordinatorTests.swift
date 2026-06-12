//
//  ArticleSendCoordinatorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Records sends and optionally fails them.
private final class MockEmailSender: ArticleEmailSending {
    struct SendFailure: Error {}
    var shouldFail = false
    private(set) var sentTitles: [String] = []

    func sendArticle(epubData: Data, fileName: String, title: String) async throws {
        if shouldFail { throw SendFailure() }
        sentTitles.append(title)
        XCTAssertFalse(epubData.isEmpty)
        XCTAssertTrue(fileName.hasSuffix(".epub"))
    }
}

final class ArticleSendCoordinatorTests: XCTestCase {

    private var store: ReadingListStore!
    private var scratchDirectory: URL!
    private var credentials: InMemorySendCredentialsStore!
    private var sender: MockEmailSender!
    private var coordinator: ArticleSendCoordinator!
    private var savedDefaults: [String: Any?] = [:]

    /// Settings keys the coordinator reads; snapshotted so tests don't leak
    /// into each other (or the test host's real defaults).
    private let settingsKeys = [
        "kindleSendMode", "kindleAddress", "kindleSMTPProvider",
        "kindleSMTPHost", "kindleSMTPUsername",
    ]

    override func setUp() {
        super.setUp()
        for key in settingsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratchDirectory)
        credentials = InMemorySendCredentialsStore()
        sender = MockEmailSender()
        coordinator = ArticleSendCoordinator(
            store: store, credentials: credentials, sender: sender)
    }

    override func tearDown() {
        for key in settingsKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func configureKindle() {
        KindleSendSettings.kindleAddress = "me@kindle.com"
        KindleSendSettings.provider = .gmail
        KindleSendSettings.smtpUsername = "me@gmail.com"
        credentials.setSMTPPassword("app-password")
    }

    private func makeReadyItem() -> ReadingListItem {
        let item = store.add(urlString: "https://example.com/article")
        let content = ArticleContent(
            title: "An Article",
            blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])])
        return store.saveContent(content, for: item)
    }

    func testSendIsNoOpWhenNotConfigured() async {
        let item = makeReadyItem()
        await coordinator.send(item)
        XCTAssertTrue(sender.sentTitles.isEmpty)
        XCTAssertNil(store.item(withID: item.id)?.sendState)
    }

    func testSendQueuesWhileArticleIsStillPending() async {
        configureKindle()
        let item = store.add(urlString: "https://example.com/pending")
        await coordinator.send(item)
        XCTAssertTrue(sender.sentTitles.isEmpty)
        XCTAssertEqual(store.item(withID: item.id)?.sendState, .queued)
    }

    func testSuccessfulSendMarksSentWithDate() async {
        configureKindle()
        let item = makeReadyItem()
        await coordinator.send(item)
        XCTAssertEqual(sender.sentTitles, ["An Article"])
        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState, .sent)
        XCTAssertNotNil(fresh?.dateSent)
    }

    func testFailedSendMarksFailed() async {
        configureKindle()
        sender.shouldFail = true
        let item = makeReadyItem()
        await coordinator.send(item)
        XCTAssertEqual(store.item(withID: item.id)?.sendState, .failed)
        XCTAssertNil(store.item(withID: item.id)?.dateSent)
    }

    func testArticleBecameReadySendsQueuedItem() async {
        configureKindle()
        KindleSendSettings.sendMode = .off
        let item = makeReadyItem()
        store.setSendState(.queued, for: item.id)

        guard let fresh = store.item(withID: item.id) else {
            return XCTFail("item disappeared")
        }
        coordinator.articleBecameReady(fresh)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.item(withID: item.id)?.sendState, .sent)
    }

    func testArticleBecameReadySendsEverythingInAllSavesMode() async {
        configureKindle()
        KindleSendSettings.sendMode = .allSaves
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.item(withID: item.id)?.sendState, .sent)
    }

    func testArticleBecameReadyDoesNothingWhenModeOff() async {
        configureKindle()
        KindleSendSettings.sendMode = .off
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(store.item(withID: item.id)?.sendState)
        XCTAssertTrue(sender.sentTitles.isEmpty)
    }

    func testRetryPendingSendsRetriesQueuedAndFailed() async {
        configureKindle()
        let queued = makeReadyItem()
        store.setSendState(.queued, for: queued.id)
        let failed = store.add(urlString: "https://example.com/failed")
        let content = ArticleContent(
            title: "Second",
            blocks: [ArticleContent.Block(kind: .paragraph, text: "More.", links: [])])
        _ = store.saveContent(content, for: failed)
        store.setSendState(.failed, for: failed.id)

        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.item(withID: queued.id)?.sendState, .sent)
        XCTAssertEqual(store.item(withID: failed.id)?.sendState, .sent)
    }
}
