//
//  AudioScriptSupportTests.swift
//  LunaTests
//
//  Merged from AudioScriptTests, AudioScriptStoreTests, and
//  ExtensionAudioScriptWriterTests.
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

final class AudioScriptSupportTests: XCTestCase {

    // MARK: - Shared temp-directory fixture (AudioScriptStoreTests + ExtensionAudioScriptWriterTests)

    private var tempDirectory: URL!
    private var store: AudioScriptStore!
    private var scriptStore: AudioScriptStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = AudioScriptStore(articlesDirectory: tempDirectory)
        scriptStore = AudioScriptStore(articlesDirectory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - AudioScriptTests helpers
    //
    // `AudioScript(passthrough:)` is the Phase-1 stub script builder: every
    // non-empty text block, verbatim, in document order. Later phases
    // replace it with real heuristic/LLM trimming — these tests only pin
    // today's contract.

    private func block(_ kind: ArticleContent.Block.Kind, _ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: [])
    }

    // MARK: - AudioScriptStoreTests helpers

    private func makeScript() -> AudioScript {
        AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.heuristicBuilderVersion)
    }

    // MARK: - ExtensionAudioScriptWriterTests helpers
    //
    // Phase 6, product requirement B: `ExtensionAudioScriptWriter` is what
    // `ShareSurfaceDriver.persistArticle` calls right after an
    // extension-context article save, so the article is audio-ready
    // (heuristically trimmed) before the main app's `AudioScriptPipeline`
    // sweep ever runs. Exercised against a scratch `articlesDirectory` (real
    // file I/O, temp dir) — the same pattern `AudioScriptStoreTests`/
    // `AudioScriptPipelineTests` use.

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

    // MARK: - AudioScriptTests tests

    func testPassthroughKeepsEveryNonEmptyBlockInOrder() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.heading, "A Headline"),
            block(.paragraph, "First paragraph of the article body."),
            block(.image, ""),
            block(.paragraph, "Second paragraph, right after the image."),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [0, 1, 3])
        XCTAssertEqual(script.spokenBlocks.map(\.text), [
            "A Headline",
            "First paragraph of the article body.",
            "Second paragraph, right after the image.",
        ])
    }

    func testPassthroughDropsEmptyTextBlocks() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.image, ""),
            block(.paragraph, ""),
            block(.paragraph, "Only real text."),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.spokenBlocks.count, 1)
        XCTAssertEqual(script.spokenBlocks.first?.blockIndex, 2)
        XCTAssertEqual(script.spokenBlocks.first?.text, "Only real text.")
    }

    func testPassthroughTotalWordCountSumsWhitespaceDelimitedWords() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.paragraph, "Four little words here"),
            block(.paragraph, "Three more words"),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.totalWordCount, 7)
    }

    func testPassthroughSetsTheStubBuilderVersion() {
        let content = ArticleContent(title: "Title", blocks: [block(.paragraph, "Text.")])
        let script = AudioScript(passthrough: content)
        XCTAssertEqual(script.builderVersion, AudioScript.passthroughBuilderVersion)
    }

    func testEmptyArticleProducesEmptyScript() {
        let content = ArticleContent(title: "Title", blocks: [block(.image, "")])
        let script = AudioScript(passthrough: content)
        XCTAssertTrue(script.spokenBlocks.isEmpty)
        XCTAssertEqual(script.totalWordCount, 0)
    }

    // MARK: - AudioScriptStoreTests tests

    func testMissingCacheReturnsNil() {
        XCTAssertNil(store.load(forContentFileName: "missing.json"))
    }

    func testSaveThenLoadRoundTrips() {
        let envelope = AudioScriptCacheEnvelope(script: makeScript(), refinementState: .heuristicOnly)
        store.save(envelope, forContentFileName: "ABCD.json")

        let loaded = store.load(forContentFileName: "ABCD.json")
        XCTAssertEqual(loaded, envelope)
    }

    func testSavedFileLivesAlongsideTheContentFileInTheArticlesDirectory() {
        let envelope = AudioScriptCacheEnvelope(script: makeScript(), refinementState: .heuristicOnly)
        store.save(envelope, forContentFileName: "ABCD.json")

        let expectedURL = tempDirectory.appendingPathComponent("ABCD.audioScript.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    func testRefinedAndPermanentlyFailedStatesRoundTrip() {
        let refinedEnvelope = AudioScriptCacheEnvelope(script: makeScript(), refinementState: .refined)
        store.save(refinedEnvelope, forContentFileName: "refined.json")
        XCTAssertEqual(store.load(forContentFileName: "refined.json")?.refinementState, .refined)

        let failedEnvelope = AudioScriptCacheEnvelope(script: makeScript(), refinementState: .permanentlyFailed)
        store.save(failedEnvelope, forContentFileName: "failed.json")
        XCTAssertEqual(store.load(forContentFileName: "failed.json")?.refinementState, .permanentlyFailed)
    }

    func testVersionMismatchIsTreatedAsAbsent() {
        let staleScript = AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.heuristicBuilderVersion + 1)
        let envelope = AudioScriptCacheEnvelope(script: staleScript, refinementState: .refined)
        store.save(envelope, forContentFileName: "ABCD.json")

        XCTAssertNil(store.load(forContentFileName: "ABCD.json"), "a builder-version mismatch must rebuild, not use stale content")
    }

    func testOldPassthroughVersionIsAlsoTreatedAsAbsent() {
        let passthroughScript = AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.passthroughBuilderVersion)
        let envelope = AudioScriptCacheEnvelope(script: passthroughScript, refinementState: .heuristicOnly)
        store.save(envelope, forContentFileName: "ABCD.json")

        XCTAssertNil(store.load(forContentFileName: "ABCD.json"))
    }

    func testCorruptFileIsTreatedAsAbsent() throws {
        let url = tempDirectory.appendingPathComponent("ABCD.audioScript.json")
        try Data("not valid json".utf8).write(to: url)
        XCTAssertNil(store.load(forContentFileName: "ABCD.json"))
    }

    // MARK: - ExtensionAudioScriptWriterTests tests

    func testWritesAHeuristicOnlyScriptImmediately() {
        let item = readableItem(seed: "a")
        let content = ArticleContent(title: "Title", blocks: [
            .init(kind: .paragraph, text: "By Jane Doe", links: []),
            .init(kind: .paragraph, text: Array(repeating: "word", count: 40).joined(separator: " "), links: []),
        ])

        let wrote = ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: item, content: content, articlesDirectory: tempDirectory)

        XCTAssertTrue(wrote)
        let cached = scriptStore.load(forContentFileName: item.contentFileName!)
        XCTAssertNotNil(cached)
        // `refined == false` and `llmPermanentlyFailed == false` used to be
        // asserted separately; they were the same fact (a fresh save-time
        // write is always heuristics-only), so this is now one assertion.
        XCTAssertEqual(cached?.refinementState, .heuristicOnly, "save-time writes are heuristics-only")
        XCTAssertEqual(cached?.script.spokenBlocks.map(\.blockIndex), [1], "the byline should be dropped")
    }

    /// Same heuristics, same `builderVersion` as the main pipeline — reused,
    /// not forked — so a script written here is indistinguishable from one
    /// `AudioScriptPipeline` would have built for the same content.
    func testWrittenScriptMatchesWhatTheMainPipelineWouldHaveBuilt() {
        let item = readableItem(seed: "b")
        let content = ArticleContent(title: "Title", blocks: [
            .init(kind: .image, text: "", links: []),
            .init(kind: .paragraph, text: Array(repeating: "word", count: 30).joined(separator: " "), links: []),
        ])

        ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: item, content: content, articlesDirectory: tempDirectory)
        let written = scriptStore.load(forContentFileName: item.contentFileName!)?.script

        let heuristicResult = AudioTrimHeuristics.classify(content)
        let expected = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: heuristicResult.droppedBlockIndices)
        XCTAssertEqual(written, expected)
        XCTAssertEqual(written?.builderVersion, AudioScriptStore.currentBuilderVersion)
    }

    func testNeverOverwritesAnExistingCachedScript() {
        let item = readableItem(seed: "c")
        let content = readableContent()
        let existing = AudioScript(spokenBlocks: [], totalWordCount: 0, builderVersion: AudioScript.heuristicBuilderVersion)
        scriptStore.save(
            AudioScriptCacheEnvelope(script: existing, refinementState: .refined),
            forContentFileName: item.contentFileName!)

        let wrote = ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: item, content: content, articlesDirectory: tempDirectory)

        XCTAssertFalse(wrote, "must never clobber an already-cached (even already-refined) script")
        XCTAssertEqual(scriptStore.load(forContentFileName: item.contentFileName!)?.script, existing)
    }

    func testNoContentFileNameIsANoOp() {
        var item = readableItem(seed: "d")
        item.contentFileName = nil
        let content = readableContent()

        let wrote = ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: item, content: content, articlesDirectory: tempDirectory)

        XCTAssertFalse(wrote)
    }
}
