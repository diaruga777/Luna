//
//  ReadingListIngestorInteropTests.swift
//  LunaTests
//

import LunaIngest
import LunaInterop
import LunaInteropUI
import LunaModels
import LunaStorage
import XCTest
@testable import LunaReadingList

/// The in-app cross-app-interop gate inside `ReadingListIngestor.ingest`
/// (`claudedocs/interop-purchase.md`): blocked cross-surface saves are
/// discarded (nothing remains in the store), `.email`/`.friendShare` sources
/// are exempt, interactive `.paste`/`.manual` saves surface the prompt via the
/// injected presenter, and the background sweep discards silently.
///
/// Outcomes are produced by the REAL pipeline but restricted to offline-
/// deterministic classifications: a bsky.app URL classifies `.social` before
/// any fetch, and a `lunadoc://` item with a `documentType` classifies
/// `.document` — so no test touches the network. The gate decision itself is
/// injected, pinning surface/unlock/install without the App Group.
final class ReadingListIngestorInteropTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    /// Recorded interop-prompt presentations: (kind, hasRetry).
    private var presentedPrompts: [(kind: InteropPromptKind, hasRetry: Bool)] = []

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingListIngestorInteropTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        presentedPrompts = []
        ReadingListIngestor.interopPromptPresenter = { [weak self] kind, retry in
            self?.presentedPrompts.append((kind, retry != nil))
        }
    }

    override func tearDown() {
        ReadingListIngestor.interopPromptPresenter = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeIngestor(
        decision: @escaping (LunaIngest.Outcome) -> InteropGate.Decision
    ) -> ReadingListIngestor {
        ReadingListIngestor(
            recorder: NoopReplayRecorder(), store: store, interopDecision: decision)
    }

    private func blockedDecision(_ outcome: LunaIngest.Outcome) -> InteropGate.Decision {
        guard let owner = outcome.interopOwner else { return .allowed }
        return .blocked(owner: owner, ownerInstalled: false)
    }

    /// A pending document item (deterministic `.document` outcome, no network).
    private func pendingDocumentItem(seed: String) -> ReadingListItem {
        let item = ReadingListItem(
            seed: seed, urlString: "lunadoc://\(seed)", title: "Doc \(seed)",
            dateAdded: Date(), state: .pending, documentType: "pdf",
            captureSource: nil)
        return item
    }

    // MARK: - Blocked cross-surface saves are discarded

    func testBlockedInteractiveSaveIsDiscardedAndPrompted() async {
        let ingestor = makeIngestor(decision: blockedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/1", source: .paste)

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .blocked(owner: .downloader, ownerInstalled: false))
        XCTAssertNil(store.item(withID: item.id), "nothing may remain in the store")
        XCTAssertEqual(presentedPrompts.count, 1)
        if case .blocked(owner: .downloader, ownerInstalled: false) = presentedPrompts[0].kind {
        } else {
            XCTFail("expected a blocked prompt, got \(presentedPrompts[0].kind)")
        }
        XCTAssertTrue(presentedPrompts[0].hasRetry, "blocked prompts carry a retry for post-unlock")
    }

    func testBlockedDocumentSaveDeletesCopiedSourceFile() async {
        let ingestor = makeIngestor(decision: blockedDecision)
        var item = pendingDocumentItem(seed: "gate-doc")
        item.captureSource = .manual
        store.seedForTesting(items: [item], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.pdf")
        try? Data("pdf".utf8).write(to: sourceFile)

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .blocked(owner: .reader, ownerInstalled: false))
        XCTAssertNil(store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    // MARK: - Source exemptions

    func testEmailSourceIsExemptAndNeverConsultsTheGate() async {
        let ingestor = makeIngestor(decision: { _ in
            XCTFail("the gate must not be consulted for an exempt source")
            return .allowed
        })
        var item = pendingDocumentItem(seed: "email-doc")
        item.captureSource = .email
        store.seedForTesting(items: [item], contents: [:])

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .allowed)
        XCTAssertNotNil(store.item(withID: item.id), "exempt sources keep writing cross-surface")
        XCTAssertTrue(presentedPrompts.isEmpty)
    }

    func testFriendShareSourceIsExemptAndNeverConsultsTheGate() async {
        let ingestor = makeIngestor(decision: { _ in
            XCTFail("the gate must not be consulted for an exempt source")
            return .allowed
        })
        var item = pendingDocumentItem(seed: "friend-doc")
        item.captureSource = .friendShare
        store.seedForTesting(items: [item], contents: [:])

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .allowed)
        XCTAssertNotNil(store.item(withID: item.id))
        XCTAssertTrue(presentedPrompts.isEmpty)
    }

    // MARK: - Background sweep: silent discard

    func testBackgroundSweepDiscardsBlockedLeftoversWithoutPrompting() async {
        let ingestor = makeIngestor(decision: blockedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/2", source: .shareSheet)

        let decision = await ingestor.ingest(item, allowsInteractivePrompt: false)

        XCTAssertEqual(decision, .blocked(owner: .downloader, ownerInstalled: false))
        XCTAssertNil(store.item(withID: item.id))
        XCTAssertTrue(presentedPrompts.isEmpty, "the sweep has no UI")
    }

    func testShareSheetLeftoverNeverPromptsEvenInteractively() async {
        // A `.shareSheet` item re-ingested in the foreground (e.g. retry) still
        // never prompts — the prompt is for `.paste`/`.manual` saves only.
        let ingestor = makeIngestor(decision: blockedDecision)
        let item = store.add(urlString: "https://bsky.app/profile/a/post/3", source: .shareSheet)

        _ = await ingestor.ingest(item)

        XCTAssertNil(store.item(withID: item.id))
        XCTAssertTrue(presentedPrompts.isEmpty)
    }

    // MARK: - Paid, owner uninstalled: save proceeds + install note

    func testNeedsInstallSavesAndShowsInstallNote() async {
        let ingestor = makeIngestor(decision: { outcome in
            outcome.interopOwner.map { .allowedNeedsInstall(owner: $0) } ?? .allowed
        })
        var item = pendingDocumentItem(seed: "install-doc")
        item.captureSource = .manual
        store.seedForTesting(items: [item], contents: [:])

        let decision = await ingestor.ingest(item)

        XCTAssertEqual(decision, .allowedNeedsInstall(owner: .reader))
        XCTAssertNotNil(store.item(withID: item.id), "a paid cross-surface save always persists")
        XCTAssertEqual(presentedPrompts.count, 1)
        if case .needsInstall(owner: .reader) = presentedPrompts[0].kind {
        } else {
            XCTFail("expected an install note, got \(presentedPrompts[0].kind)")
        }
        XCTAssertFalse(presentedPrompts[0].hasRetry, "install notes carry no retry")
    }

    // MARK: - handleSavePress surfaces the gate result

    func testHandleSavePressReturnsBlockedByInterop() async {
        let ingestor = makeIngestor(decision: blockedDecision)

        let result = await ingestor.handleSavePress(
            urlString: "https://bsky.app/profile/a/post/4", source: .manual)

        guard case let .blockedByInterop(owner, ownerInstalled) = result else {
            return XCTFail("expected .blockedByInterop, got \(result)")
        }
        XCTAssertEqual(owner, .downloader)
        XCTAssertFalse(ownerInstalled)
        XCTAssertNil(store.item(forURLString: "https://bsky.app/profile/a/post/4"))
    }

    // MARK: - saveNewWithContent (pasteboard fast path)

    func testSaveNewWithContentBlockedIsRefusedBeforeAdding() async {
        let ingestor = makeIngestor(decision: blockedDecision)
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body.", links: []),
        ])

        let saved = await ingestor.saveNewWithContent(
            urlString: "https://example.com/article", content: content, source: .paste)

        XCTAssertNil(saved)
        XCTAssertNil(store.item(forURLString: "https://example.com/article"))
        XCTAssertEqual(presentedPrompts.count, 1)
        XCTAssertTrue(presentedPrompts[0].hasRetry)
    }
}
