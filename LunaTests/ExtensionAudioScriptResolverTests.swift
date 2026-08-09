//
//  ExtensionAudioScriptResolverTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// Phase 6, product requirement A: `ExtensionAudioScriptResolver` is the
/// Share/Action-extension-safe seam that resolves the best available
/// `AudioScript` for IMMEDIATE playback (cached refined > cached heuristic >
/// freshly-built heuristic — never blocking on the LLM), plus a cancellable
/// opportunistic refinement pass that only ever updates the cache. Exercised
/// against a scratch `articlesDirectory` (real file I/O, temp dir) and
/// `FakeTrimModelSession` (the on-device model is never available in CI).
final class ExtensionAudioScriptResolverTests: XCTestCase {

    private var tempDirectory: URL!
    private var scriptStore: AudioScriptStore!
    private var savedIntelligentTrimming: Bool!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        scriptStore = AudioScriptStore(articlesDirectory: tempDirectory)
        savedIntelligentTrimming = AudioSettings.isIntelligentTrimmingEnabled
    }

    override func tearDown() {
        AudioSettings.isIntelligentTrimmingEnabled = savedIntelligentTrimming
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func readableItem(seed: String) -> ReadingListItem {
        var item = ReadingListItem(
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

    // MARK: - The ladder: refined cache > heuristic cache > fresh heuristic build

    func testRefinedCacheIsReturnedAsIsAndNeverRebuilt() {
        let session = FakeTrimModelSession()
        session.isAvailable = false // isolate: no refinement kick-off in this test
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "refined")
        let content = readableContent()

        // Seed a REFINED cache entry that disagrees with fresh heuristics
        // (drops everything) — proves a refined cache hit wins outright.
        let seededScript = AudioScript(spokenBlocks: [], totalWordCount: 0, builderVersion: AudioScript.heuristicBuilderVersion)
        scriptStore.save(
            AudioScriptCacheEnvelope(script: seededScript, refinementState: .refined),
            forContentFileName: item.contentFileName!)

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        XCTAssertEqual(script, seededScript)
    }

    func testHeuristicCacheIsReturnedAsIsWhenNotYetRefined() {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "heuristic-cached")
        let content = readableContent()

        let seededScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [0])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: seededScript, refinementState: .heuristicOnly),
            forContentFileName: item.contentFileName!)

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        XCTAssertEqual(script, seededScript)
    }

    func testCacheMissBuildsAFreshHeuristicScriptAndPersistsIt() {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "fresh")
        let content = ArticleContent(title: "Title", blocks: [
            .init(kind: .paragraph, text: "By Jane Doe", links: []),
            .init(kind: .paragraph, text: Array(repeating: "word", count: 40).joined(separator: " "), links: []),
        ])

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)

        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [1], "the byline should be heuristically dropped")
        let cached = scriptStore.load(forContentFileName: item.contentFileName!)
        XCTAssertNotNil(cached, "the freshly-built script must be persisted immediately")
        XCTAssertEqual(cached?.script, script)
        XCTAssertEqual(cached?.refinementState, .heuristicOnly)
    }

    func testNoContentFileNameFallsBackToAnUnpersistedHeuristicBuild() {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        var item = readableItem(seed: "no-file")
        item.contentFileName = nil
        let content = readableContent()

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        XCTAssertFalse(script.spokenBlocks.isEmpty)
    }

    // MARK: - Opportunistic refinement (never blocks; cache-only write)

    func testReturnedScriptIsTheHeuristicOneEvenWhenARefinementIsKickedOff() {
        // The call must NEVER block on the LLM: even with an available
        // session queued to succeed, the returned script is the heuristic
        // one built synchronously, not whatever the (async) refinement
        // would eventually produce.
        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([1])]
        AudioSettings.isIntelligentTrimmingEnabled = true
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "opportunistic")
        let content = readableContent()

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [0, 1], "returned immediately, unrefined")
    }

    func testEligibleRefinementEventuallyUpgradesTheCacheInBackground() async throws {
        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])] // succeeds, finds nothing extra
        AudioSettings.isIntelligentTrimmingEnabled = true
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "upgrades")
        let content = readableContent()

        _ = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)

        try await waitFor {
            self.scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState == .refined
        }
    }

    func testIntelligentTrimmingDisabledNeverKicksOffRefinement() async throws {
        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])]
        AudioSettings.isIntelligentTrimmingEnabled = false
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "disabled")
        let content = readableContent()

        _ = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        // Nothing to await when the setting is off — the kick-off decision is
        // synchronous, so no task was ever started, and that IS the assertion.
        await resolver.awaitLastStartedRefinement()

        XCTAssertTrue(session.requestedPrompts.isEmpty)
        XCTAssertEqual(
            scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState, .heuristicOnly)
    }

    func testUnavailableModelDegradesSilentlyWithNoRefinementAttempt() async throws {
        let session = FakeTrimModelSession()
        session.isAvailable = false
        AudioSettings.isIntelligentTrimmingEnabled = true
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "unavailable")
        let content = readableContent()

        let script = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        await resolver.awaitLastStartedRefinement()

        XCTAssertFalse(script.spokenBlocks.isEmpty)
        XCTAssertTrue(session.requestedPrompts.isEmpty, "an unavailable session must never be asked anything")
    }

    func testCancelInFlightRefinementPreventsItsResultFromBeingApplied() async throws {
        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([1])]
        AudioSettings.isIntelligentTrimmingEnabled = true
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })
        let item = readableItem(seed: "cancelled")
        let content = readableContent()

        _ = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        resolver.cancelInFlightRefinement()

        // Let the cancelled task run all the way to where it WOULD have applied
        // its result — the cache must still show the unrefined entry.
        await resolver.awaitLastStartedRefinement()
        XCTAssertEqual(
            scriptStore.load(forContentFileName: item.contentFileName!)?.refinementState, .heuristicOnly,
            "a cancelled refinement must never write its result to the cache")
    }

    func testPermanentlyFailedCacheEntryIsNeverRetried() async throws {
        let item = readableItem(seed: "permafail")
        let content = readableContent()
        let heuristicScript = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: [])
        scriptStore.save(
            AudioScriptCacheEnvelope(script: heuristicScript, refinementState: .permanentlyFailed),
            forContentFileName: item.contentFileName!)

        let session = FakeTrimModelSession()
        session.isAvailable = true
        session.responses = [.indices([])] // would succeed if ever called
        AudioSettings.isIntelligentTrimmingEnabled = true
        let resolver = ExtensionAudioScriptResolver(
            articlesDirectory: tempDirectory, modelSessionFactory: { session })

        _ = resolver.bestAvailableScriptForImmediatePlayback(item: item, content: content)
        await resolver.awaitLastStartedRefinement()

        XCTAssertTrue(session.requestedPrompts.isEmpty, "a permanently-failed article must never be retried")
    }

    // MARK: - Helpers

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
