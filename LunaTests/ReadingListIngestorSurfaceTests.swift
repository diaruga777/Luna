//
//  ReadingListIngestorSurfaceTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaStorage
import XCTest
@testable import LunaReadingList

/// The per-app content gate inside `ReadingListIngestor.ingest`
/// (`SurfaceSupport`, replacing the old cross-app-purchase `InteropGate`):
/// a foreign-kind save is discarded (nothing remains in the store) for EVERY
/// source — including `.email`/`.friendShare`, which were exempt under the old
/// interop gate but are not anymore — and the background sweep discards
/// silently.
///
/// Outcomes are produced by the REAL pipeline but restricted to offline-
/// deterministic classifications: a bsky.app URL classifies `.social` before
/// any fetch, and a `lunadoc://` item with a `documentType` classifies
/// `.document` — so no test touches the network. The gate decision itself is
/// injected, pinning the running app without the App Group.
final class ReadingListIngestorSurfaceTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    /// Recorded unsupported-save presentations.
    private var presentedOwners: [LunaApp] = []

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingListIngestorSurfaceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        presentedOwners = []
        ReadingListIngestor.unsupportedSavePresenter = { [weak self] owner in
            self?.presentedOwners.append(owner)
        }
    }

    override func tearDown() {
        ReadingListIngestor.unsupportedSavePresenter = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeIngestor(
        decision: @escaping (LunaIngest.Outcome) -> SurfaceSupport.Decision
    ) -> ReadingListIngestor {
        ReadingListIngestor(store: store, surfaceDecision: decision)
    }

    private func unsupportedDecision(_ outcome: LunaIngest.Outcome) -> SurfaceSupport.Decision {
        guard let owner = outcome.owningApp else { return .supported }
        return .unsupported(owner: owner)
    }

    /// A pending document item (deterministic `.document` outcome, no network).
    private func pendingDocumentItem(seed: String) -> ReadingListItem {
        let item = ReadingListItem(
            seed: seed, urlString: "lunadoc://\(seed)", title: "Doc \(seed)",
            dateAdded: Date(), state: .pending, documentType: "pdf",
            captureSource: nil)
        return item
    }

    // MARK: - Unsupported cross-app saves are discarded

    func testUnsupportedInteractiveSaveIsDiscardedAndPresented() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/1", source: .paste)

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .unsupported(owner: .downloader))
        XCTAssertNil(store.item(withID: item.id), "nothing may remain in the store")
        XCTAssertEqual(presentedOwners, [.downloader])
    }

    func testUnsupportedDocumentSaveDeletesCopiedSourceFile() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        var item = pendingDocumentItem(seed: "gate-doc")
        item.captureSource = .manual
        store.seedForTesting(items: [item], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.pdf")
        try? Data("pdf".utf8).write(to: sourceFile)

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .unsupported(owner: .reader))
        XCTAssertNil(store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    // MARK: - No more source exemptions: .email / .friendShare are gated too

    func testEmailSourceIsAlsoDroppedWhenOutcomeIsUnsupported() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        var item = pendingDocumentItem(seed: "email-doc")
        item.captureSource = .email
        store.seedForTesting(items: [item], contents: [:])

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .unsupported(owner: .reader))
        XCTAssertNil(store.item(withID: item.id), "email saves are no longer exempt from the gate")
    }

    func testFriendShareSourceIsAlsoDroppedWhenOutcomeIsUnsupported() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        var item = pendingDocumentItem(seed: "friend-doc")
        item.captureSource = .friendShare
        store.seedForTesting(items: [item], contents: [:])

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .unsupported(owner: .reader))
        XCTAssertNil(store.item(withID: item.id), "friend-share saves are no longer exempt from the gate")
    }

    // MARK: - Background sweep: silent discard

    func testBackgroundSweepDiscardsUnsupportedLeftoversWithoutPresenting() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/2", source: .shareSheet)

        let decision = await ingestor.ingest(item, allowsInteractivePrompt: false)

        XCTAssertEqual(decision, .unsupported(owner: .downloader))
        XCTAssertNil(store.item(withID: item.id))
        XCTAssertTrue(presentedOwners.isEmpty, "the sweep has no UI")
    }

    func testShareSheetLeftoverNeverPresentsEvenInteractively() async {
        // A `.shareSheet` item re-ingested in the foreground (e.g. retry) still
        // never presents — the presenter fires for `.paste`/`.manual` saves only.
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/3", source: .shareSheet)

        _ = await ingestor.ingest(item)

        XCTAssertNil(store.item(withID: item.id))
        XCTAssertTrue(presentedOwners.isEmpty)
    }

    // MARK: - handleSavePress surfaces the gate result

    func testHandleSavePressReturnsUnsupportedKind() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)

        let result = await ingestor.handleSavePress(
            urlString: "https://bsky.app/profile/a/post/4", source: .manual)

        guard case let .unsupportedKind(owner) = result else {
            return XCTFail("expected .unsupportedKind, got \(result)")
        }
        XCTAssertEqual(owner, .downloader)
        XCTAssertNil(store.item(forURLString: "https://bsky.app/profile/a/post/4"))
    }

    // MARK: - saveNewWithContent (pasteboard fast path)

    func testSaveNewWithContentUnsupportedIsRefusedBeforeAdding() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body.", links: []),
        ])

        let saved = await ingestor.saveNewWithContent(
            urlString: "https://example.com/article", content: content, source: .paste)

        XCTAssertNil(saved)
        XCTAssertNil(store.item(forURLString: "https://example.com/article"))
        XCTAssertEqual(presentedOwners, [.reader])
    }
}
