//
//  SavesIngestorSurfaceTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaStorage
import XCTest
@testable import LunaSaves

/// A gate that answers from a scripted rule, so a test can pin the running app
/// without touching the App Group. Shared with the other ingestor suites.
struct ScriptedIngestGate: IngestSurfaceGating {
    /// Every kind is this app's.
    static let supported = ScriptedIngestGate { _ in .supported }
    /// Nothing with an owner is this app's — the single-content-app drop.
    static let foreign = ScriptedIngestGate { outcome in
        guard let owner = outcome.owningApp else { return .supported }
        return .unsupported(owner: owner)
    }

    private let rule: (Outcome) -> SurfaceSupport.Decision

    init(rule: @escaping (Outcome) -> SurfaceSupport.Decision) { self.rule = rule }

    func decision(for outcome: Outcome) -> SurfaceSupport.Decision { rule(outcome) }
}

/// The per-app content gate inside `SavesIngestor.ingest`
/// (`SurfaceSupport`): a foreign-kind save is discarded (nothing remains in the
/// store) for EVERY source, `.email`/`.friendShare` included, and the background
/// sweep discards silently.
///
/// Outcomes are produced by the REAL pipeline but restricted to offline-
/// deterministic classifications: a bsky.app URL classifies `.social` before
/// any fetch, and a `lunadoc://` item with a `documentType` classifies
/// `.document` — so no test touches the network. The gate decision itself is
/// injected, pinning the running app without the App Group.
final class SavesIngestorSurfaceTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: SavesStore!
    /// Recorded unsupported-save presentations.
    private var presentedOwners: [LunaApp] = []
    /// Rows this test wrote into the SHARED `SaveFailureStore`, cleaned up in
    /// `tearDown` so the App Group is left as it was found.
    private var touchedFailureIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesIngestorSurfaceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDirectory)
        presentedOwners = []
        touchedFailureIDs = []
        SavesIngestor.unsupportedSavePresenter = RecordingUnsupportedSavePresenter { [weak self] owner in
            self?.presentedOwners.append(owner)
        }
    }

    override func tearDown() {
        SavesIngestor.unsupportedSavePresenter = nil
        for id in touchedFailureIDs { SaveFailureStore.shared.clear(id) }
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeIngestor(gate: ScriptedIngestGate) -> SavesIngestor {
        SavesIngestor(store: store, surfaceGate: gate)
    }

    /// A pending document item (deterministic `.document` outcome, no network).
    private func pendingDocumentItem(seed: String) -> SavedItem {
        let item = SavedItem(
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
        let ingestor = makeIngestor(gate: .foreign)
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

    /// Not a kind question, so not the matrix's: EVERY capture source is
    /// gated, with no exemptions.
    func testNoCaptureSourceIsExemptFromTheGate() async {
        let ingestor = makeIngestor(gate: .foreign)

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
        let ingestor = makeIngestor(gate: .foreign)
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
        let ingestor = makeIngestor(gate: .foreign)

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
        let ingestor = makeIngestor(gate: .foreign)
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body.", links: []),
        ])

        let saved = await ingestor.saveNewWithContent(
            urlString: "https://example.com/article", content: content, source: .paste)

        XCTAssertNil(saved)
        XCTAssertNil(store.item(forURLString: "https://example.com/article"))
        XCTAssertEqual(presentedOwners, [.reader])
    }

    /// A stand-in presenter recording which sibling app each drop named.
    private struct RecordingUnsupportedSavePresenter: UnsupportedSavePresenting {
        let record: @MainActor (LunaApp) -> Void

        init(_ record: @escaping @MainActor (LunaApp) -> Void) {
            self.record = record
        }

        @MainActor
        func presentUnsupportedSave(owner: LunaApp) {
            record(owner)
        }
    }

    // MARK: - An unsupported outcome that gets past the gate

    /// The central app accepts every kind, so its gate returns `.supported` for an
    /// `.unsupported` outcome and the presenter's last case becomes reachable. It
    /// must mark the row failed: leaving it `.pending` is a row that spins forever
    /// with no card, no reason and nothing a retry can move.
    func testUnsupportedOutcomeReachingThePresenterMarksTheRowFailed() async {
        let urlString = "https://bsky.app/profile/a/post/7"
        let ingestor = makeIngestor(gate: .supported)
        let item = store.add(urlString: urlString, source: .paste)
        touchedFailureIDs.append(item.id)
        let presenter = IngestorOutcomePresenter(
            ingestor: ingestor, url: URL(string: urlString)!)

        await presenter.present(.unsupported(owner: .downloader), for: item)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        XCTAssertEqual(SaveFailureStore.shared.record(for: item.id)?.reason, .unknown,
                       "a failed row needs a reason for the card to explain itself")
    }
}
