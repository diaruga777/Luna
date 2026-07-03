//
//  ArticleSendCoordinatorTests.swift
//  LunaTests
//

import LunaSend
import LunaStorage
import LunaModels
import XCTest
@testable import Luna

/// A configurable in-memory destination that records sends.
private final class MockDestination: ArticleDestination {
    struct SendFailure: Error {}
    struct AuthFailure: Error, CustomStringConvertible {
        var description: String { "AUTH failed" }
    }

    let id: String
    let displayName = "Mock"
    var configured = true
    var mode: ArticleSendMode = .off
    /// Optional per-source override; when nil, `mode` applies to every source.
    var modeForSource: ((CaptureSource) -> ArticleSendMode)?
    var shouldFail = false
    var shouldHardFail = false
    private(set) var sentTitles: [String] = []

    init(id: String) { self.id = id }

    var isConfigured: Bool { configured }

    func sendMode(for item: ReadingListItem) -> ArticleSendMode {
        modeForSource?(item.effectiveCaptureSource) ?? mode
    }

    var appIntentsSendMode: ArticleSendMode { mode }

    func send(epubData: Data, fileName: String, title: String) async throws {
        if shouldHardFail { throw AuthFailure() }
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
    private var currentDate: Date!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratchDirectory)
        kindle = MockDestination(id: ArticleDestinationID.kindle)
        boox = MockDestination(id: ArticleDestinationID.boox)
        currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        coordinator = ArticleSendCoordinator(
            store: store,
            destinations: [kindle, boox],
            retryPolicy: .init(maxSoftFailures: 3, initialDelay: 60, maxDelay: 300),
            now: { self.currentDate })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func makeReadyItem(
        _ url: String = "https://example.com/article", source: CaptureSource = .manual
    ) -> ReadingListItem {
        let item = store.add(urlString: url, source: source)
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

    func testSoftFailureQueuesRetryWithBackoff() async {
        kindle.shouldFail = true
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)
        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .queued)
        XCTAssertEqual(fresh?.sendFailureCounts[kindle.id], 1)
        XCTAssertEqual(
            fresh?.sendNextAttemptDates[kindle.id],
            currentDate.addingTimeInterval(60))
        XCTAssertNil(store.item(withID: item.id)?.dateSent(for: kindle.id))
    }

    func testHardFailureMarksFailedAndQueuesNotice() async {
        kindle.shouldHardFail = true
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)
        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .failed)
        XCTAssertEqual(fresh?.pendingSendFailureNotices[kindle.id], true)
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

    func testArticleBecameReadyRespectsCaptureSource() async {
        // Email auto-sends; paste does not.
        kindle.modeForSource = { $0 == .email ? .allSaves : .off }
        let emailItem = makeReadyItem("https://example.com/email", source: .email)
        let pasteItem = makeReadyItem("https://example.com/paste", source: .paste)
        coordinator.articleBecameReady(emailItem)
        coordinator.articleBecameReady(pasteItem)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(sendState(emailItem, kindle.id), .sent)
        XCTAssertNil(sendState(pasteItem, kindle.id))
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

    func testRetryPendingSendsRetriesQueuedWhenBackoffElapsed() async {
        let queued = makeReadyItem("https://example.com/queued")
        store.setSendState(.queued, for: queued.id, destination: kindle.id)
        let waiting = makeReadyItem("https://example.com/waiting")
        store.scheduleSendRetry(
            for: waiting.id, destination: boox.id, failureCount: 1,
            nextAttemptDate: currentDate.addingTimeInterval(60),
            errorMessage: "network")

        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sendState(queued, kindle.id), .sent)
        XCTAssertEqual(sendState(waiting, boox.id), .queued)
        XCTAssertTrue(boox.sentTitles.isEmpty)

        currentDate = currentDate.addingTimeInterval(61)
        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sendState(waiting, boox.id), .sent)
    }

    func testEnoughSoftFailuresGiveUp() async {
        kindle.shouldFail = true
        let item = makeReadyItem()

        await coordinator.send(item, toDestinationID: kindle.id)
        currentDate = currentDate.addingTimeInterval(61)
        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)
        currentDate = currentDate.addingTimeInterval(121)
        coordinator.retryPendingSends()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .failed)
        XCTAssertEqual(fresh?.sendFailureCounts[kindle.id], 3)
        XCTAssertEqual(fresh?.pendingSendFailureNotices[kindle.id], true)
    }
}
