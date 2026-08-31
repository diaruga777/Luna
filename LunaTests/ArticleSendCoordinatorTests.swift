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
    struct DeferralFailure: Error, SendDeferralError {}

    let id: String
    let displayName = "Mock"
    var configured = true
    var mode: ArticleSendMode = .off
    /// Optional per-source override; when nil, `mode` applies to every source.
    var modeForSource: ((CaptureSource) -> ArticleSendMode)?
    var shouldFail = false
    var shouldHardFail = false
    /// Simulates a receiver that is simply not reachable right now (an asleep
    /// Xteink): the send throws a `SendDeferralError`.
    var shouldDefer = false
    /// Thrown verbatim when set — for errors with meaning of their own, like
    /// the Xteink reader's `low_memory` refusal.
    var errorToThrow: Error?
    var attemptCount = 0
    private(set) var sentTitles: [String] = []
    private(set) var sentEPUBs: [Data] = []

    init(id: String) { self.id = id }

    var isConfigured: Bool { configured }

    func sendMode(for item: SavedItem) -> ArticleSendMode {
        modeForSource?(item.effectiveCaptureSource) ?? mode
    }

    var appIntentsSendMode: ArticleSendMode { mode }

    func send(epubData: Data, fileName: String, title: String) async throws {
        attemptCount += 1
        if let errorToThrow { throw errorToThrow }
        if shouldHardFail { throw AuthFailure() }
        if shouldDefer { throw DeferralFailure() }
        if shouldFail { throw SendFailure() }
        XCTAssertFalse(epubData.isEmpty)
        XCTAssertTrue(fileName.hasSuffix(".epub"))
        sentTitles.append(title)
        sentEPUBs.append(epubData)
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

    func testXteinkBuildIsTextOnlyEvenWithAnArticleImage() async throws {
        let xteink = MockDestination(id: ArticleDestinationID.xteink)
        coordinator = ArticleSendCoordinator(
            store: store, destinations: [xteink],
            retryPolicy: .init(maxSoftFailures: 3, initialDelay: 60, maxDelay: 300),
            now: { self.currentDate })
        coordinator.deliveryTaskObserver = self

        let item = store.add(urlString: "https://example.com/image")
        let imageName = "reader-image.png"
        let image = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL7PgAAAABJRU5ErkJggg==")!
        try image.write(to: store.articlesDirectory.appendingPathComponent(imageName))
        let content = ArticleContent(title: "An Image", blocks: [
            .init(
                kind: .image, text: "Image alt", links: [],
                imageURLString: "https://example.com/image.png", imageFileName: imageName),
            .init(kind: .caption, text: "Caption remains", links: []),
        ])
        let ready = store.saveContent(content, for: item)

        await coordinator.send(ready, toDestinationID: xteink.id)
        XCTAssertEqual(xteink.sentEPUBs.count, 1)
        let epub = try XCTUnwrap(xteink.sentEPUBs.first)
        let archive = try XCTUnwrap(ZipArchiveReader(data: epub))
        XCTAssertTrue(archive.paths.filter { $0.hasPrefix("OEBPS/images/") }.isEmpty)
        let chapter = try XCTUnwrap(archive.text(at: "OEBPS/chapter.xhtml"))
        XCTAssertFalse(chapter.contains("<img"))
        XCTAssertTrue(chapter.contains("Caption remains"))
    }

    /// The rendezvous sweep's entry point must deliver a queued send even
    /// when an earlier soft failure scheduled a future backoff date — the
    /// receiving device holds a live window open RIGHT NOW, and skipping it
    /// silently was what left the reader hanging with nothing sent.
    func testDeliverQueuedSendsIgnoresBackoffAndDrainsEverything() async {
        second.shouldFail = true
        let first = makeReadyItem("https://example.com/one")
        let another = makeReadyItem("https://example.com/two")
        await coordinator.send(first, toDestinationID: second.id)
        await coordinator.send(another, toDestinationID: second.id)
        XCTAssertEqual(sendState(first, second.id), .queued)
        XCTAssertNotNil(store.item(withID: first.id)?.sendNextAttemptDates[second.id])

        // A plain backoff-respecting retry attempts nothing.
        coordinator.retryPendingSends()
        await drainDeliveries()
        XCTAssertTrue(second.sentTitles.isEmpty)

        second.shouldFail = false
        await coordinator.deliverQueuedSends(toDestinationID: second.id)
        XCTAssertEqual(second.sentTitles.count, 2)
        XCTAssertEqual(sendState(first, second.id), .sent)
        XCTAssertEqual(sendState(another, second.id), .sent)
    }

    /// A reader that refuses `start_put` with `low_memory` is reporting a
    /// device-wide condition: every remaining book this window would be
    /// refused the same way. The sweep must stop after the first refusal and
    /// leave the rest queued for the next window.
    func testDeliverQueuedSendsStopsAfterReaderLowMemoryRefusal() async {
        let items = [
            makeReadyItem("https://example.com/one"),
            makeReadyItem("https://example.com/two"),
            makeReadyItem("https://example.com/three"),
        ]
        for item in items { store.setSendState(.queued, for: item.id, destination: second.id) }
        second.errorToThrow = XteinkSyncError.protocolError("low_memory")

        await coordinator.deliverQueuedSends(toDestinationID: second.id)

        XCTAssertEqual(second.attemptCount, 1)
        XCTAssertTrue(second.sentTitles.isEmpty)
        for item in items { XCTAssertEqual(sendState(item, second.id), .queued) }
    }

    /// An ordinary per-book failure must NOT stop the sweep — only the
    /// device-wide low-memory refusal does.
    func testDeliverQueuedSendsContinuesPastOrdinaryFailures() async {
        let items = [
            makeReadyItem("https://example.com/one"),
            makeReadyItem("https://example.com/two"),
        ]
        for item in items { store.setSendState(.queued, for: item.id, destination: second.id) }
        second.shouldFail = true

        await coordinator.deliverQueuedSends(toDestinationID: second.id)

        XCTAssertEqual(second.attemptCount, 2)
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

    /// Share/action extensions persist articles directly to `.ready`, so the
    /// app's lifecycle retry must reconstruct the automatic send queue for an
    /// enabled capture source before the Xteink rendezvous sweep runs.
    func testRetryPendingSendsQueuesReadyAutoSendItemFromExtension() async {
        second.modeForSource = { $0 == .shareSheet ? .allSaves : .off }
        let automatic = makeReadyItem("https://example.com/shared", source: .shareSheet)
        let optedOut = makeReadyItem("https://example.com/pasted", source: .paste)

        XCTAssertNil(sendState(automatic, second.id))
        coordinator.retryPendingSends()
        XCTAssertEqual(sendState(automatic, second.id), .queued)
        XCTAssertNil(sendState(optedOut, second.id))

        await drainDeliveries()
        XCTAssertEqual(sendState(automatic, second.id), .sent)
        XCTAssertTrue(second.sentTitles.contains("An Article"))
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

    func testDeferralKeepsItemQueuedWithoutSpendingRetries() async {
        kindle.shouldDefer = true
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .queued)
        XCTAssertNil(fresh?.sendFailureCounts[kindle.id])
        XCTAssertNil(fresh?.sendNextAttemptDates[kindle.id])
    }

    func testDeferralNeverBecomesTerminalAndSendsWhenReachable() async {
        kindle.shouldDefer = true
        let item = makeReadyItem()
        await coordinator.send(item, toDestinationID: kindle.id)

        // Many sweeps against an asleep receiver: still queued, still no
        // failure bookkeeping, no backoff gating the next sweep.
        for _ in 0..<5 {
            coordinator.retryPendingSends()
            await drainDeliveries()
        }
        var fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .queued)
        XCTAssertNil(fresh?.sendFailureCounts[kindle.id])
        XCTAssertTrue(kindle.sentTitles.isEmpty)

        // The receiver wakes: the very next sweep delivers, with no clock
        // advance needed.
        kindle.shouldDefer = false
        coordinator.retryPendingSends()
        await drainDeliveries()
        fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: kindle.id), .sent)
        XCTAssertEqual(kindle.sentTitles, ["An Article"])
    }
}
