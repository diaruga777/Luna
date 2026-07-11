//
//  ExtensionAudioScriptWriterTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// Phase 6, product requirement B: `ExtensionAudioScriptWriter` is what
/// `ShareSurfaceDriver.persistArticle` calls right after an extension-context
/// article save, so the article is audio-ready (heuristically trimmed)
/// before the main app's `AudioScriptPipeline` sweep ever runs. Exercised
/// against a scratch `articlesDirectory` (real file I/O, temp dir) — the same
/// pattern `AudioScriptStoreTests`/`AudioScriptPipelineTests` use.
final class ExtensionAudioScriptWriterTests: XCTestCase {

    private var tempDirectory: URL!
    private var scriptStore: AudioScriptStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        scriptStore = AudioScriptStore(articlesDirectory: tempDirectory)
    }

    override func tearDown() {
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
        XCTAssertEqual(cached?.refined, false, "save-time writes are heuristics-only, never refined")
        XCTAssertEqual(cached?.llmPermanentlyFailed, false)
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
            AudioScriptCacheEnvelope(script: existing, refined: true, llmPermanentlyFailed: false),
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

    private func readableContent(wordsPerBlock: Int = 20, blockCount: Int = 2) -> ArticleContent {
        let blocks = (0..<blockCount).map { index in
            ArticleContent.Block(
                kind: .paragraph,
                text: (0..<wordsPerBlock).map { "block\(index)word\($0)" }.joined(separator: " "),
                links: [])
        }
        return ArticleContent(title: "Title", blocks: blocks)
    }
}
