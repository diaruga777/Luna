//
//  SaveDiagnosticsCaptureTests.swift
//  LunaTests
//
//  Capture end-to-end: which saves flush a trace, which shed one, what the
//  flushed trace actually says about the attempt, and when the failed card
//  offers to share it. `claudedocs/save-diagnostics.md`.
//
//  These drive the SHARED stores (`SaveDiagnosticsStore.shared` /
//  `SaveFailureStore.shared`) because production code names them directly.
//  Every item id is fresh and every test cleans up after itself, so nothing
//  here can see another test's rows.
//

import LunaIngest
import LunaModels
import LunaShareSurface
@testable import LunaMediaDownload
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaSaves
@testable import LunaSavesUI

@MainActor
final class SaveDiagnosticsCaptureTests: XCTestCase {

    private var scratch: URL!
    private var store: SavesStore!
    /// Everything this test wrote into the shared sidecars, cleaned up in
    /// `tearDown` so the App Group is left as it was found.
    private var touchedIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveDiagnosticsCapture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratch)
        touchedIDs = []
    }

    override func tearDown() {
        for id in touchedIDs {
            SaveDiagnosticsStore.shared.delete(for: id)
            SaveFailureStore.shared.clear(id)
        }
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func track(_ id: UUID) -> UUID {
        touchedIDs.append(id)
        return id
    }

    // MARK: - The main app's ingest

    /// The load-bearing behaviour: a save that fails leaves the WHOLE story of
    /// the attempt on disk, under a separator naming the attempt, the source and
    /// the reason. A search-results URL is vetoed before any fetch, so the trace
    /// is produced entirely offline.
    func testAFailedSaveFlushesItsTraceWithTheDecisionsThatProducedIt() async {
        let ingestor = SavesIngestor(store: store, surfaceGate: ScriptedIngestGate.supported)
        let item = store.add(
            urlString: "https://www.google.com/search?q=luna+reader", source: .manual)
        _ = track(item.id)

        await ingestor.ingest(item)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        let trace = try? XCTUnwrap(SaveDiagnosticsStore.shared.contents(for: item.id))
        let text = trace ?? ""
        XCTAssertTrue(text.contains("— attempt 1 via manual, notContent —"), text)
        // The tokens a reader of this file needs: what was asked for, how it was
        // classified, and which decision ended it. Asserting on their presence
        // rather than on exact sentences.
        XCTAssertTrue(text.contains("ingest: begin"), text)
        XCTAssertTrue(text.contains("google.com/search"), text)
        XCTAssertTrue(text.contains("pipeline: classified"), text)
        XCTAssertTrue(text.contains("multi-item listing"), text)
    }

    /// A retry appends; it does not replace and it does not re-emit the first
    /// attempt's lines. Both are what make a shared export show whether the
    /// failure is stable.
    func testARetryAppendsASecondAttemptRatherThanRewritingTheFirst() async {
        let ingestor = SavesIngestor(store: store, surfaceGate: ScriptedIngestGate.supported)
        let item = store.add(urlString: "https://duckduckgo.com/?q=luna", source: .manual)
        _ = track(item.id)

        await ingestor.ingest(item)
        let afterFirst = SaveDiagnosticsStore.shared.contents(for: item.id) ?? ""
        await ingestor.ingest(store.item(withID: item.id) ?? item)
        let afterSecond = SaveDiagnosticsStore.shared.contents(for: item.id) ?? ""

        XCTAssertTrue(afterFirst.contains("attempt 1 via manual"), afterFirst)
        XCTAssertTrue(afterSecond.hasPrefix(afterFirst), "the first attempt is kept verbatim")
        XCTAssertTrue(afterSecond.contains("attempt 2 via manual"), afterSecond)
        XCTAssertEqual(
            afterSecond.components(separatedBy: "ingest: begin").count - 1, 2,
            "each attempt contributes exactly its own lines")
    }

    /// A save this app does not own is not this app's failure, and its item is
    /// deleted outright — so the buffer is dropped and any earlier file goes
    /// with it, rather than orphaning a trace nothing can ever export.
    func testASurfaceDroppedSaveLeavesNoTraceBehind() async {
        let ingestor = SavesIngestor(store: store, surfaceGate: ScriptedIngestGate.foreign)
        let item = store.add(
            urlString: "https://bsky.app/profile/a.bsky.social/post/1", source: .paste)
        _ = track(item.id)
        SaveDiagnosticsStore.shared.appendLine("a stale story", for: item.id)

        await ingestor.ingest(item, allowsInteractivePrompt: false)

        XCTAssertNil(store.item(withID: item.id))
        XCTAssertFalse(SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id))
    }

    // The launch sweep's `SaveDiagnosticsStore.shared.prune(keeping:)` is
    // deliberately NOT exercised here: the production call is against the App
    // Group singleton, so a test driving it with a scratch saves list would
    // delete every OTHER trace on the machine — including this suite's own
    // seeded rows and a developer's real ones. The prune's behaviour is
    // asserted against an isolated store in `SaveDiagnosticsStoreTests`.

    /// Deleting the item takes its trace with it — a failed card's Delete is
    /// the user saying "stop keeping this", and a file left behind would only
    /// be found by a later prune.
    func testDeletingAnItemDropsItsTrace() {
        let item = store.add(urlString: "https://example.com/gone", source: .manual)
        _ = track(item.id)
        SaveDiagnosticsStore.shared.appendLine("a story", for: item.id)

        store.delete(item)

        XCTAssertFalse(SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id))
    }

    // MARK: - The share / action extensions

    /// Two things at once, because they were one bug: an extension failure
    /// calls `markFailed` and flushes its trace together, so it always
    /// carries a reason and a count rather than being the one path with
    /// neither.
    func testAFailedExtensionSaveRecordsAReasonAndFlushesItsTrace() async {
        let host = FakeExtensionHost()
        let item = store.add(urlString: "https://example.com/broken", source: .shareSheet)
        _ = track(item.id)
        let driver = ShareSurfaceDriver(
            host: host, store: store,
            ingest: StubShareIngest { input in
                SaveDiagnostics.record("a leg inside the pipeline", category: "fetch")
                return IngestResult(url: input.url, outcome: .failed(.httpStatus(403)))
            },
            surfaceGate: AlwaysSupportedSurfaceGate())

        await driver.ingestAndPresent(originalURL: URL(string: "https://example.com/broken")!)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        let record = SaveFailureStore.shared.record(for: item.id)
        XCTAssertEqual(record?.reason, .httpStatus(403))
        XCTAssertEqual(record?.failureCount, 1)

        let text = SaveDiagnosticsStore.shared.contents(for: item.id) ?? ""
        XCTAssertTrue(text.contains("— attempt 1 via shareSheet, httpStatus(403) —"), text)
        XCTAssertTrue(text.contains("source=shareSheet"), text)
        XCTAssertTrue(
            text.contains("a leg inside the pipeline"),
            "the binding reaches into the pipeline call: \(text)")
    }

    /// A save that works sheds whatever an earlier failed attempt left, so the
    /// card can never offer to share a story about a save that has since
    /// succeeded.
    func testASucceedingExtensionSaveShedsAnEarlierTrace() async {
        let host = FakeExtensionHost()
        let item = store.add(urlString: "https://example.com/doc.pdf", source: .shareSheet)
        _ = track(item.id)
        SaveDiagnosticsStore.shared.appendLine("last week's failure", for: item.id)
        let driver = ShareSurfaceDriver(
            host: host, store: store,
            ingest: StubShareIngest { input in
                IngestResult(url: input.url, outcome: .document(type: "pdf"))
            },
            surfaceGate: AlwaysSupportedSurfaceGate())

        await driver.ingestAndPresent(originalURL: URL(string: "https://example.com/doc.pdf")!)

        XCTAssertFalse(SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id))
    }

    /// The zero-UI share extension has no chance to present anything, so the
    /// flush is the only thing carrying the failure forward.
    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        func presentModally(_ viewController: UIViewController) {}
        func confirmSavedThenComplete() {}
        func completeSilently() {}
        func autoDownloadThenComplete(urlString: String) {}
        func failOrComplete(_ message: String) {}
        func openURL(_ url: URL) {}
    }
}

/// `SaveFailureReason.noMediaFound`'s only writer. It has to reach the SHARED
/// saves list because that is what the production callers (a background
/// transfer's delegate callback, the awaited auto-download) can see — so these
/// seed and remove their own row there.
final class MediaSaveFailureRecordingTests: XCTestCase {

    private var saved: SavedItem?

    override func tearDown() {
        if let saved {
            SaveDiagnosticsStore.shared.delete(for: saved.id)
            SaveFailureStore.shared.clear(saved.id)
            SavesStore.shared.delete(saved)
        }
        super.tearDown()
    }

    private func seedItem() -> SavedItem {
        let item = SavesStore.shared.add(
            urlString: "https://www.instagram.com/reel/\(UUID().uuidString)/", source: .manual)
        saved = item
        return item
    }

    /// A media link that resolved no asset files `.noMediaFound` against its
    /// item, so the rescue asks the model about media rather than about a
    /// failed article. This is the one branch `URLRescueWiring` reads that
    /// nothing else writes.
    func testAResolveWithNoAssetFilesTheReasonAgainstTheItem() {
        let item = seedItem()

        MediaSaveFailureRecording.recordNoMedia(
            sourceURLString: item.urlString, detail: "resolve ladder exhausted")

        XCTAssertEqual(SaveFailureStore.shared.record(for: item.id)?.reason, .noMediaFound)
    }

    /// A background transfer fails minutes after the save's task tree is gone,
    /// so there is no recorder to buffer into — the line has to reach the file
    /// directly, in the same format the recorder writes.
    func testWithoutABoundRecorderTheLineGoesStraightToTheTraceFile() {
        let item = seedItem()

        MediaSaveFailureRecording.recordNoMedia(
            sourceURLString: item.urlString, detail: "resolve ladder exhausted")

        let text = SaveDiagnosticsStore.shared.contents(for: item.id) ?? ""
        XCTAssertTrue(text.contains("[media] media: no downloadable asset"), text)
        XCTAssertTrue(text.contains("resolve ladder exhausted"), text)
    }

    /// Inside a save's task tree it marks the recorder terminal instead, which
    /// is what stops the ingestor dropping the buffer as the success the
    /// `Outcome` claims — a classified post IS a successful outcome.
    func testInsideASaveItMarksTheRecorderTerminalRatherThanWritingEarly() {
        let item = seedItem()
        let recorder = SaveDiagnosticsRecorder(itemID: item.id)

        SaveDiagnostics.$recorder.withValue(recorder) {
            MediaSaveFailureRecording.recordNoMedia(
                sourceURLString: item.urlString, detail: "no playable asset")
        }

        XCTAssertEqual(recorder.terminalFailure, .noMediaFound)
        XCTAssertFalse(recorder.isEmpty, "the reason is in the buffer, not on disk yet")
        XCTAssertFalse(SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id))
    }
}

/// The card and the deck menu only offer to share a trace that exists.
@MainActor
final class SaveDiagnosticsShareUITests: XCTestCase {

    private var touchedIDs: [UUID] = []
    private var previousRecoveryPresenter: ((UUID, URL, UIViewController) -> Void)?

    override func setUp() {
        super.setUp()
        previousRecoveryPresenter = FailedSavePluginRecovery.present
        FailedSavePluginRecovery.present = nil
    }

    override func tearDown() {
        for id in touchedIDs { SaveDiagnosticsStore.shared.delete(for: id) }
        FailedSavePluginRecovery.present = previousRecoveryPresenter
        super.tearDown()
    }

    private func makeCard(withDiagnostics: Bool) -> FailedSaveCardViewController {
        let model = FailedSaveCardModel(
            itemID: UUID(), url: URL(string: "https://example.com/broken"),
            urlText: "example.com/broken")
        let actions = FailedSaveCardActions(
            share: { _ in },
            shareDiagnostics: withDiagnostics ? { _ in } : nil,
            delete: {})
        return FailedSaveCardViewController(model: model, actions: actions)
    }

    /// With nothing to share but the link there is only one verb, and a
    /// one-item menu over a button that already did that one thing is pure
    /// ceremony — so the share control stays a plain button.
    func testTheShareControlStaysAPlainButtonWithoutATrace() {
        XCTAssertNil(makeCard(withDiagnostics: false).shareMenu())
    }

    func testTheShareControlOffersBothVerbsWhenATraceExists() {
        let menu = makeCard(withDiagnostics: true).shareMenu()
        let titles = (menu?.children as? [UIAction])?.map(\.title) ?? []
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles.first, L10n.string("Common_shareLinkEllipsis"))
        XCTAssertEqual(titles.last, L10n.string("CardDeck_failedSave_shareDiagnostics"))
    }

    func testTheShareControlOffersPluginRecoveryWithoutARawTrace() {
        let model = FailedSaveCardModel(
            itemID: UUID(), url: URL(string: "https://example.com/broken"),
            urlText: "example.com/broken")
        let card = FailedSaveCardViewController(
            model: model,
            actions: FailedSaveCardActions(
                share: { _ in }, createPlugin: {}, delete: {}))

        let titles = (card.shareMenu()?.children as? [UIAction])?.map(\.title) ?? []
        XCTAssertEqual(titles, [
            L10n.string("Common_shareLinkEllipsis"),
            L10n.string("Plugins_recoveryCreatePlugin"),
        ])
    }

    /// The deck's long-press menu tracks the same condition, so the card and
    /// the deck can't disagree about whether there is anything to share.
    func testTheDeckMenuGainsTheVerbOnlyWhenATraceExists() {
        let host = UIViewController()
        let delete = UIAction(title: "Delete") { _ in }
        let item = SavedItem(urlString: "https://example.com/broken")
        touchedIDs.append(item.id)

        let without = FailedSaveCardFactory.makeMenu(
            for: item, host: host, shareLink: {}, delete: delete)
        XCTAssertEqual(without.children.count, 2)

        SaveDiagnosticsStore.shared.appendLine("a story", for: item.id)
        let with = FailedSaveCardFactory.makeMenu(
            for: item, host: host, shareLink: {}, delete: delete)
        XCTAssertEqual(with.children.count, 3)
        XCTAssertEqual(
            (with.children[1] as? UIAction)?.title,
            L10n.string("CardDeck_failedSave_shareDiagnostics"))
    }

    /// The header is the context the trace itself can't carry: which link, and
    /// what the failure sidecar concluded about it.
    func testTheExportHeaderNamesTheLinkAndWhatTheSidecarConcluded() {
        let item = SavedItem(urlString: "https://example.com/broken")
        let record = SaveFailureRecord(
            reason: .httpStatus(403),
            lastFailureDate: Date(timeIntervalSince1970: 1_700_000_000),
            failureCount: 3)

        let header = FailedSaveCardFactory.diagnosticsHeader(for: item, record: record)

        XCTAssertTrue(header.contains("https://example.com/broken"), header)
        XCTAssertTrue(header.contains(item.id.uuidString), header)
        XCTAssertTrue(header.contains(SaveFailureReason.httpStatus(403).headline), header)
        XCTAssertTrue(header.contains("Attempts: 3"), header)
        XCTAssertTrue(header.hasSuffix("\n\n"), "the trace starts on its own line")
    }
}
