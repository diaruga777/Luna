//
//  ShareSurfaceDriverSurfaceTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaIngest
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import LunaShareSurface

/// The per-app content gate inside `ShareSurfaceDriver.present`
/// (`SurfaceSupport`): an
/// unsupported cross-app save deletes the pending row (and any copied document
/// file) and presents `UnsupportedSaveCardViewController`; a same-app outcome and
/// `.failed` are byte-identical to today. Uses a fake host + scratch store —
/// same seams the driver was built around (the real `NSExtensionContext` has
/// none).
@MainActor
final class ShareSurfaceDriverSurfaceTests: XCTestCase {

    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        var presented: [UIViewController] = []
        var confirmedSaved = 0
        var completedSilently = 0
        var autoDownloads: [String] = []
        var failures: [String] = []
        var openedURLs: [URL] = []

        func presentModally(_ viewController: UIViewController) { presented.append(viewController) }
        func confirmSavedThenComplete() { confirmedSaved += 1 }
        func completeSilently() { completedSilently += 1 }
        func autoDownloadThenComplete(urlString: String) { autoDownloads.append(urlString) }
        func failOrComplete(_ message: String) { failures.append(message) }
        func openURL(_ url: URL) { openedURLs.append(url) }
    }

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    private var host: FakeExtensionHost!
    /// Rows this test wrote into the SHARED `SaveFailureStore`, cleaned up in
    /// `tearDown` so the App Group is left as it was found.
    private var touchedFailureIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        // Supported outcomes route through `ShareKindPresenters`; register the
        // production-shaped presenters explicitly (the test bundle may hold its
        // own framework copies, so no entry-class registration is visible here).
        ShareKindPresenterTestSupport.registerAll()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareSurfaceDriverSurfaceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        host = FakeExtensionHost()
        touchedFailureIDs = []
    }

    override func tearDown() {
        for id in touchedFailureIDs { SaveFailureStore.shared.clear(id) }
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// A driver whose gate input (the running app) is pinned — no `Bundle.main` reads.
    private func makeDriver(current: LunaApp) -> ShareSurfaceDriver {
        // `ingest` keeps its default — these tests drive `present` directly, so
        // the pipeline is never reached.
        ShareSurfaceDriver(
            host: host,
            store: store,
            surfaceGate: PinnedAppSurfaceGate(currentApp: current),
            currentApp: current)
    }

    /// A non-downloadable social URL (bluesky), so the share extension's
    /// non-textual flow takes its silent-terminal branch.
    private let socialURL = URL(string: "https://bsky.app/profile/someone/post/123")!

    // MARK: - Unsupported (cross-app, single-content app)

    /// The ONE call-site wiring proof for this surface: `present` asks the gate,
    /// and a dropped save leaves NOTHING — no row, no copied document file, no
    /// "Saved" checkmark — behind the shared drop card. Which (app, kind) pairs
    /// are dropped is `SurfaceSupportTests`' decision matrix, not this file's.
    func testUnsupportedSaveDropsEverythingAndPresentsTheDropCard() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let reader = makeDriver(current: .reader)

        reader.present(.social(.bluesky, itemID: "123"), url: socialURL)

        XCTAssertNil(store.item(forURLString: socialURL.absoluteString),
                     "an unsupported save must leave NOTHING in the store")
        XCTAssertEqual(host.presented.count, 1)
        let card = host.presented.first as? UnsupportedSaveCardViewController
        XCTAssertNotNil(card, "unsupported saves present the unsupported-kind error")
        XCTAssertEqual(host.confirmedSaved, 0, "never a 'Saved' checkmark for an unsupported save")
        XCTAssertEqual(host.autoDownloads, [])
        XCTAssertEqual(host.completedSilently, 0, "waits for the drop card's Done")

        // Done on the card completes quietly.
        card?.onDone?()
        XCTAssertEqual(host.completedSilently, 1)

        // The other half of "nothing remains": a document's copied source file.
        let document = ReadingListItem(
            seed: "doc", urlString: "lunadoc://ABC", title: "Report",
            dateAdded: Date(), state: .pending, documentType: "pdf",
            captureSource: .shareSheet)
        store.seedForTesting(items: [document], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(document.id.uuidString)-source.pdf")
        try? Data("pdf-bytes".utf8).write(to: sourceFile)

        let priceTracker = makeDriver(current: .priceTracker)
        priceTracker.present(.document(type: "pdf"), url: URL(string: "lunadoc://ABC")!)

        XCTAssertNil(store.item(forURLString: "lunadoc://ABC"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path),
                       "the copied document file must be cleaned up with the row")
        XCTAssertEqual(host.presented.count, 2)
        XCTAssertTrue(host.presented.last is UnsupportedSaveCardViewController)
    }

    func testUnsupportedResolvedWrapperDoesNotDeletePreexistingCanonicalItem() async {
        let wrapperURL = URL(string: "https://example.com/redirect?id=123")!
        let canonicalURL = URL(string: "https://bsky.app/profile/someone/post/123")!
        let existing = store.add(urlString: canonicalURL.absoluteString, source: .manual)
        _ = store.add(urlString: wrapperURL.absoluteString, source: .shareSheet)
        let driver = ShareSurfaceDriver(
            host: host,
            store: store,
            ingest: StubShareIngest { _ in
                IngestResult(
                    url: canonicalURL,
                    outcome: .social(.bluesky, itemID: "123"))
            },
            surfaceGate: FixedDecisionSurfaceGate(.unsupported(owner: .downloader)),
            currentApp: .reader)

        await driver.ingestAndPresent(originalURL: wrapperURL)

        XCTAssertNil(store.item(forURLString: wrapperURL.absoluteString),
                     "wrapper placeholder is removed by canonical dedup")
        XCTAssertEqual(store.item(forURLString: canonicalURL.absoluteString)?.id, existing.id,
                       "unsupported cleanup must preserve the older canonical save")
        XCTAssertTrue(host.presented.first is UnsupportedSaveCardViewController)
    }

    // MARK: - The negative control: a passed save is byte-identical to today

    /// The gate's other half at this call site — an admitted outcome reaches the
    /// same terminals it always did, and `.failed` (which belongs to nobody) is
    /// never gated at all.
    func testSupportedAndFailedOutcomesAreUntouchedByTheGate() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let downloader = makeDriver(current: .downloader)
        downloader.present(.social(.bluesky, itemID: "123"), url: socialURL)

        let saved = store.item(forURLString: socialURL.absoluteString)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.platform, .bluesky, "platform metadata persisted as today")
        XCTAssertEqual(host.autoDownloads, [socialURL.absoluteString],
                       "silent terminal exactly as today")
        XCTAssertTrue(host.presented.isEmpty, "no error card for a same-app save")

        let brokenURL = URL(string: "https://example.com/broken")!
        let broken = store.add(urlString: brokenURL.absoluteString, source: .shareSheet)
        let reader = makeDriver(current: .reader)
        reader.present(.failed(nil), url: brokenURL)

        XCTAssertEqual(store.item(withID: broken.id)?.state, .failed, "marked failed as today")
        XCTAssertEqual(host.completedSilently, 1)
        XCTAssertTrue(host.presented.isEmpty, "a genuine failure is nobody's kind — never dropped")
    }

    // MARK: - An unsupported outcome that gets past the gate

    /// The central app's extensions accept every kind, so their gate returns
    /// `.supported` for an `.unsupported` outcome and the switch's last case
    /// becomes reachable. It must mark the row failed: leaving it `.pending` is a
    /// row that spins forever with no card, no reason and nothing a retry can move.
    func testUnsupportedOutcomePastTheGateMarksTheRowFailed() {
        let item = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        touchedFailureIDs.append(item.id)
        let central = ShareSurfaceDriver(
            host: host, store: store, surfaceGate: AlwaysSupportedSurfaceGate(),
            currentApp: .luna)

        central.present(.unsupported(owner: .downloader), url: socialURL)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        XCTAssertEqual(SaveFailureStore.shared.record(for: item.id)?.reason, .unknown,
                       "a failed row needs a reason for the card to explain itself")
        XCTAssertEqual(host.completedSilently, 1)
        XCTAssertTrue(host.presented.isEmpty)
    }
}
