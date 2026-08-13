//
//  AudioScriptPipelineTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// An in-memory `SavesScriptSource` fake backed by a real scratch
/// `articlesDirectory` (so `AudioScriptStore`'s file I/O is exercised for
/// real, just against a temp directory instead of the App Group).
final class FakeScriptSource: SavesScriptSource {
    var itemsList: [SavedItem] = []
    var contentByID: [UUID: ArticleContent] = [:]
    let articlesDirectory: URL

    init(articlesDirectory: URL) { self.articlesDirectory = articlesDirectory }

    func items() -> [SavedItem] { itemsList }
    func content(for item: SavedItem) -> ArticleContent? { contentByID[item.id] }
}

final class AudioScriptPipelineTests: XCTestCase {

    private var tempDirectory: URL!
    private var source: FakeScriptSource!
    private var scriptStore: AudioScriptStore!
    private var savedIntelligentTrimming: Bool!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        source = FakeScriptSource(articlesDirectory: tempDirectory)
        scriptStore = AudioScriptStore(articlesDirectory: tempDirectory)
        savedIntelligentTrimming = AudioSettings.isIntelligentTrimmingEnabled
    }

    override func tearDown() {
        AudioSettings.isIntelligentTrimmingEnabled = savedIntelligentTrimming
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func readableItem(seed: String) -> SavedItem {
        var item = SavedItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: "Article \(seed)",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000), state: .ready)
        item.contentFileName = "\(item.id.uuidString).json"
        return item
    }

    private func readableContent(wordsPerBlock: Int = 20, blockCount: Int = 2) -> ArticleContent {
        let blocks = (0..<blockCount).map { index in
            ArticleContent.Block(
                kind: .paragraph,
                text: (0..<wordsPerBlock).map { "block\(index)word\($0)" }.joined(separator: " "),
                links: [])
        }
        return ArticleContent(title: "Title", blocks: blocks)
    }

    // MARK: - script(for:content:) — playback-time seam

    func testScriptForCacheMissBuildsHeuristicScriptAndPersistsIt() {
        let session = FakeTrimModelSession()
        session.isAvailable = false // isolate: no LLM involvement in this test
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session))
        let item = readableItem(seed: "a")
        let content = ArticleContent(title: "Title", blocks: [
            .init(kind: .paragraph, text: "By Jane Doe", links: []),
            .init(kind: .paragraph, text: Array(repeating: "word", count: 40).joined(separator: " "), links: []),
        ])

        let script = pipeline.script(for: item, content: content)

        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [1], "the byline should be heuristically dropped")
        let cached = scriptStore.load(forContentFileName: item.contentFileName!)
        XCTAssertNotNil(cached, "the built script must be persisted for next time")
        XCTAssertEqual(cached?.script, script)
        XCTAssertEqual(cached?.refinementState, .heuristicOnly)
    }

    func testScriptForCacheHitReturnsTheStoredScriptWithoutRebuilding() {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session))
        let item = readableItem(seed: "b")
        let content = readableContent()

        // Seed a cache entry that DISAGREES with what heuristics would
        // freshly compute (drops everything) — proves a cache hit is
        // returned as-is, never rebuilt.
        let seededScript = AudioScript(spokenBlocks: [], totalWordCount: 0, builderVersion: AudioScript.heuristicBuilderVersion)
        scriptStore.save(
            AudioScriptCacheEnvelope(script: seededScript, refinementState: .refined),
            forContentFileName: item.contentFileName!)

        let script = pipeline.script(for: item, content: content)
        XCTAssertEqual(script, seededScript)
    }

    // MARK: - Sweep: .savesChanged builds a missing script

    func testSavesChangedBuildsAScriptForANewlyDiscoveredReadableItem() async throws {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)
        pipeline.install()

        let item = readableItem(seed: "c")
        source.itemsList = [item]
        source.contentByID[item.id] = readableContent()

        NotificationCenter.default.post(name: .savesChanged, object: nil)
        try await waitFor { self.scriptStore.load(forContentFileName: item.contentFileName!) != nil }

        XCTAssertNotNil(scriptStore.load(forContentFileName: item.contentFileName!))
    }

    func testUnreadableOrNotReadyItemsAreNeverBuilt() async throws {
        let session = FakeTrimModelSession()
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)

        var pendingItem = readableItem(seed: "pending")
        pendingItem.state = .pending
        let emptyItem = readableItem(seed: "empty")
        source.itemsList = [pendingItem, emptyItem]
        source.contentByID[emptyItem.id] = ArticleContent(title: "Title", blocks: [.init(kind: .image, text: "", links: [])])

        let swept = expectation(description: "launch sweep ran")
        // `.savesChanged` is process-global, so a sibling test's store
        // write can debounce a second sweep in behind ours.
        swept.assertForOverFulfill = false
        pipeline.didFinishSweepForTesting = { swept.fulfill() }
        pipeline.install()
        await fulfillment(of: [swept], timeout: 2)

        XCTAssertNil(scriptStore.load(forContentFileName: pendingItem.contentFileName!))
        XCTAssertNil(scriptStore.load(forContentFileName: emptyItem.contentFileName!))
    }

    // MARK: - Refined upgrade path

    func testHeuristicsOnlyScriptIsUpgradedToRefinedWhenEligible() async throws {
        let item = readableItem(seed: "d")
        let content = readableContent()
        let heuristicScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: heuristicScript, refinementState: .heuristicOnly),
            forContentFileName: item.contentFileName!)

        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])] // succeeds, finds nothing extra to remove
        AudioSettings.isIntelligentTrimmingEnabled = true
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)

        source.itemsList = [item]
        source.contentByID[item.id] = content
        pipeline.install()

        try await waitFor {
            self.scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState == .refined
        }
        XCTAssertEqual(
            scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState, .refined)
    }

    func testUpgradeNeverAttemptedWhenIntelligentTrimmingDisabled() async throws {
        let item = readableItem(seed: "e")
        let content = readableContent()
        let heuristicScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: heuristicScript, refinementState: .heuristicOnly),
            forContentFileName: item.contentFileName!)

        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])]
        AudioSettings.isIntelligentTrimmingEnabled = false
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)

        source.itemsList = [item]
        source.contentByID[item.id] = content
        // The sweep decides eligibility synchronously, so a sweep that has RUN
        // and started nothing is the whole assertion — no sleeping required.
        let swept = expectation(description: "launch sweep ran")
        // `.savesChanged` is process-global, so a sibling test's store
        // write can debounce a second sweep in behind ours.
        swept.assertForOverFulfill = false
        pipeline.didFinishSweepForTesting = { swept.fulfill() }
        pipeline.install()
        await fulfillment(of: [swept], timeout: 2)

        XCTAssertEqual(
            scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState, .heuristicOnly)
        XCTAssertTrue(session.requestedPrompts.isEmpty, "the model must never be asked when the setting is off")
    }

    func testPermanentlyFailedItemsAreNeverRetried() async throws {
        let item = readableItem(seed: "f")
        let content = readableContent()
        let heuristicScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: heuristicScript, refinementState: .permanentlyFailed),
            forContentFileName: item.contentFileName!)

        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])] // would succeed if ever called
        AudioSettings.isIntelligentTrimmingEnabled = true
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)

        source.itemsList = [item]
        source.contentByID[item.id] = content
        let swept = expectation(description: "launch sweep ran")
        // `.savesChanged` is process-global, so a sibling test's store
        // write can debounce a second sweep in behind ours.
        swept.assertForOverFulfill = false
        pipeline.didFinishSweepForTesting = { swept.fulfill() }
        pipeline.install()
        await fulfillment(of: [swept], timeout: 2)

        XCTAssertTrue(session.requestedPrompts.isEmpty, "a permanently-failed article must never be retried")
        XCTAssertEqual(
            scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState, .permanentlyFailed)
    }

    func testGuardrailViolationDuringUpgradeMarksPermanentlyFailed() async throws {
        let item = readableItem(seed: "g")
        let content = readableContent()
        let heuristicScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: heuristicScript, refinementState: .heuristicOnly),
            forContentFileName: item.contentFileName!)

        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.failure(.guardrailViolation)]
        AudioSettings.isIntelligentTrimmingEnabled = true
        let pipeline = AudioScriptPipeline(store: source, modelSessions: FixedTrimModelSessionMaker(session), debounceInterval: 0.05)

        source.itemsList = [item]
        source.contentByID[item.id] = content
        pipeline.install()

        try await waitFor {
            self.scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState == .permanentlyFailed
        }
        let cached = scriptStore.load(forContentFileName: item.contentFileName!)
        // `.permanentlyFailed` makes "failed but still refined" unrepresentable.
        XCTAssertEqual(cached?.refinementState, .permanentlyFailed)
    }

    // MARK: - Helpers

    /// Polls `condition` until it's true or `timeout` elapses — the sweep
    /// runs on a background queue after a debounce, so tests can't just
    /// assert immediately after posting the notification.
    private func waitFor(
        timeout: TimeInterval = 3, condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
