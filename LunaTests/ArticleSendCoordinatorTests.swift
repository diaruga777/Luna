//
//  ArticleSendCoordinatorTests.swift
//  LunaTests
//

@_spi(Testing) import LunaSend
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

    func sendMode(for item: SavedItem) -> ArticleSendMode {
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

final class ArticleSendCoordinatorTests: XCTestCase, ArticleDeliveryTaskObserving {

    private var store: SavesStore!
    private var scratchDirectory: URL!
    private var kindle: MockDestination!
    /// A second mock destination, standing in for whatever the real second
    /// `ArticleDestination` happens to be — the coordinator's fan-out/retry logic
    /// only cares that there are two independently-configured destinations.
    private var second: MockDestination!
    private var coordinator: ArticleSendCoordinator!
    private var currentDate: Date!
    /// Every background delivery task `articleBecameReady`/`retryPendingSends`
    /// starts, collected through the coordinator's `deliveryTaskObserver` seam
    /// so `drainDeliveries()` can await them instead of sleeping.
    private let taskLock = NSLock()
    private var deliveryTasks: [Task<Void, Never>] = []

    func coordinatorDidStartDeliveryTask(_ task: Task<Void, Never>) {
        taskLock.lock()
        defer { taskLock.unlock() }
        deliveryTasks.append(task)
    }

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
        kindle = MockDestination(id: ArticleDestinationID.kindle)
        second = MockDestination(id: "secondEreader")
        currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        coordinator = ArticleSendCoordinator(
            store: store,
            destinations: [kindle, second],
            retryPolicy: .init(maxSoftFailures: 3, initialDelay: 60, maxDelay: 300),
            now: { self.currentDate })
        coordinator.deliveryTaskObserver = self
    }

    override func tearDown() {
        // The observer reference is weak, so nothing holds the test here.
        coordinator?.deliveryTaskObserver = nil
        deliveryTasks.forEach { $0.cancel() }
        deliveryTasks.removeAll()
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    /// Awaits every delivery task started so far (and anything they start in
    /// turn), so the assertions that follow read settled state.
    private func drainDeliveries() async {
        while true {
            let pending = taskLock.withLock {
                let pending = deliveryTasks
                deliveryTasks.removeAll()
                return pending
            }
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    private func makeReadyItem(
        _ url: String = "https://example.com/article", source: CaptureSource = .manual
    ) -> SavedItem {
        let item = store.add(urlString: url, source: source)
        let content = ArticleContent(
            title: "An Article",
            blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])])
        return store.saveContent(content, for: item)
    }

    private func sendState(_ item: SavedItem, _ destinationID: String) -> SavedItem.SendState? {
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
    }

    func testExplicitSendTargetsOnlyOneDestination() async {
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: second.id)
        XCTAssertEqual(second.sentTitles, ["An Article"])
        XCTAssertTrue(kindle.sentTitles.isEmpty)
        XCTAssertEqual(sendState(item, second.id), .sent)
        XCTAssertNil(sendState(item, kindle.id))
    }

    func testArticleBecameReadySendsQueuedItem() async {
        kindle.mode = .off
        let item = makeReadyItem()
        store.setSendState(.queued, for: item.id, destination: kindle.id)
        guard let fresh = store.item(withID: item.id) else { return XCTFail("item gone") }
        coordinator.articleBecameReady(fresh)
        await drainDeliveries()
        XCTAssertEqual(sendState(item, kindle.id), .sent)
    }

    func testArticleBecameReadySendsToAllAllSavesDestinations() async {
        kindle.mode = .allSaves
        second.mode = .allSaves
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        await drainDeliveries()
        XCTAssertEqual(sendState(item, kindle.id), .sent)
        XCTAssertEqual(sendState(item, second.id), .sent)
    }

    func testArticleBecameReadyRespectsPerDestinationMode() async {
        kindle.mode = .allSaves
        second.mode = .off
        let item = makeReadyItem()
        coordinator.articleBecameReady(item)
        await drainDeliveries()
        XCTAssertEqual(sendState(item, kindle.id), .sent)
        XCTAssertNil(sendState(item, second.id))
        XCTAssertTrue(second.sentTitles.isEmpty)
    }

    func testArticleBecameReadyRespectsCaptureSource() async {
        // Email auto-sends; paste does not.
        kindle.modeForSource = { $0 == .email ? .allSaves : .off }
        let emailItem = makeReadyItem("https://example.com/email", source: .email)
        let pasteItem = makeReadyItem("https://example.com/paste", source: .paste)
        coordinator.articleBecameReady(emailItem)
        coordinator.articleBecameReady(pasteItem)
        await drainDeliveries()
        XCTAssertEqual(sendState(emailItem, kindle.id), .sent)
        XCTAssertNil(sendState(pasteItem, kindle.id))
    }

    func testDoubleSaveDestinationIDsReflectsConfiguredDoubleSave() {
        kindle.mode = .doubleSave
        second.mode = .off
        XCTAssertEqual(coordinator.doubleSaveDestinationIDs(), [kindle.id])
        second.mode = .doubleSave
        XCTAssertEqual(Set(coordinator.doubleSaveDestinationIDs()), [kindle.id, second.id])
        kindle.configured = false
        XCTAssertEqual(coordinator.doubleSaveDestinationIDs(), [second.id])
    }

    func testRetryPendingSendsRetriesQueuedWhenBackoffElapsed() async {
        let queued = makeReadyItem("https://example.com/queued")
        store.setSendState(.queued, for: queued.id, destination: kindle.id)
        let waiting = makeReadyItem("https://example.com/waiting")
        store.scheduleSendRetry(
            for: waiting.id, destination: second.id, failureCount: 1,
            nextAttemptDate: currentDate.addingTimeInterval(60),
            errorMessage: "network")

        coordinator.retryPendingSends()
        await drainDeliveries()
        XCTAssertEqual(sendState(queued, kindle.id), .sent)
        XCTAssertEqual(sendState(waiting, second.id), .queued)
        XCTAssertTrue(second.sentTitles.isEmpty)

        currentDate = currentDate.addingTimeInterval(61)
        coordinator.retryPendingSends()
        await drainDeliveries()
        XCTAssertEqual(sendState(waiting, second.id), .sent)
    }

    func testEnoughSoftFailuresGiveUp() async {
        kindle.shouldFail = true
        let item = makeReadyItem()

        await coordinator.send(item, toDestinationID: kindle.id)
        currentDate = currentDate.addingTimeInterval(61)
        coordinator.retryPendingSends()
        await drainDeliveries()
        currentDate = currentDate.addingTimeInterval(121)
        coordinator.retryPendingSends()
        await drainDeliveries()

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .failed)
        XCTAssertEqual(fresh?.sendFailureCounts[kindle.id], 3)
    }
}
