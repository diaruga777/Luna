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
/// (`SurfaceSupport`): a foreign-kind save is discarded (nothing remains in the
/// store) for EVERY source, `.email`/`.friendShare` included, and the background
/// sweep discards silently.
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

    /// The ONE call-site wiring proof for this surface: `ingest` asks the gate,
    /// and a dropped save leaves NOTHING — neither the row nor a copied document
    /// file — while the interactive presenter names the owning app. Which
    /// (app, kind) pairs are dropped is `SurfaceSupportTests`' matrix.
    func testUnsupportedSaveIsDiscardedWholeAndPresented() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let pasted = store.add(urlString: "https://bsky.app/profile/a/post/1", source: .paste)

        let decision = await ingestor.ingest(pasted)

        XCTAssertEqual(decision, .unsupported(owner: .downloader))
        XCTAssertNil(store.item(withID: pasted.id), "nothing may remain in the store")
        XCTAssertEqual(presentedOwners, [.downloader])

        // The other half of "nothing remains": a document's copied source file.
        var document = pendingDocumentItem(seed: "gate-doc")
        document.captureSource = .manual
        store.seedForTesting(items: [document], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(document.id.uuidString)-source.pdf")
        try? Data("pdf".utf8).write(to: sourceFile)

        let documentDecision = await ingestor.ingest(document)

        XCTAssertEqual(documentDecision, .unsupported(owner: .reader))
        XCTAssertNil(store.item(withID: document.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    // MARK: - No source exemptions

    /// Not a kind question, so not the matrix's: EVERY capture source is gated,
    /// including the two that used to be exempt.
    func testNoCaptureSourceIsExemptFromTheGate() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)

        for source in [CaptureSource.email, .friendShare, .manual, .shareSheet] {
            var item = pendingDocumentItem(seed: "src-\(source)")
            item.captureSource = source
            store.seedForTesting(items: [item], contents: [:])

            let decision = await ingestor.ingest(item)

            XCTAssertEqual(decision, .unsupported(owner: .reader), "\(source)")
            XCTAssertNil(store.item(withID: item.id), "\(source) saves are not exempt from the gate")
        }
    }

    // MARK: - When the drop is allowed to speak

    /// The presenter is for a save the user is watching: the background sweep and
    /// a `.shareSheet` leftover discard silently.
    func testOnlyInteractiveSavesPresentTheDrop() async {
        let ingestor = makeIngestor(decision: unsupportedDecision)
        let sweptItem = store.add(urlString: "https://bsky.app/profile/a/post/2", source: .shareSheet)

        let decision = await ingestor.ingest(sweptItem, allowsInteractivePrompt: false)

        XCTAssertEqual(decision, .unsupported(owner: .downloader))
        XCTAssertNil(store.item(withID: sweptItem.id))
        XCTAssertTrue(presentedOwners.isEmpty, "the sweep has no UI")

        // A `.shareSheet` item re-ingested in the FOREGROUND (e.g. a retry) still
        // never presents — the presenter fires for `.paste`/`.manual` saves only.
        let leftover = store.add(urlString: "https://bsky.app/profile/a/post/3", source: .shareSheet)

        _ = await ingestor.ingest(leftover)

        XCTAssertNil(store.item(withID: leftover.id))
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
