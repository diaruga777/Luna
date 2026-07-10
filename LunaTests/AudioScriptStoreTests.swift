//
//  AudioScriptStoreTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

final class AudioScriptStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: AudioScriptStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = AudioScriptStore(articlesDirectory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeScript() -> AudioScript {
        AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.heuristicBuilderVersion)
    }

    func testScriptFileNameDerivesFromContentFileName() {
        XCTAssertEqual(
            AudioScriptStore.scriptFileName(forContentFileName: "ABCD.json"), "ABCD.audioScript.json")
    }

    func testMissingCacheReturnsNil() {
        XCTAssertNil(store.load(forContentFileName: "missing.json"))
    }

    func testSaveThenLoadRoundTrips() {
        let envelope = AudioScriptCacheEnvelope(script: makeScript(), refined: false, llmPermanentlyFailed: false)
        store.save(envelope, forContentFileName: "ABCD.json")

        let loaded = store.load(forContentFileName: "ABCD.json")
        XCTAssertEqual(loaded, envelope)
    }

    func testSavedFileLivesAlongsideTheContentFileInTheArticlesDirectory() {
        let envelope = AudioScriptCacheEnvelope(script: makeScript(), refined: false, llmPermanentlyFailed: false)
        store.save(envelope, forContentFileName: "ABCD.json")

        let expectedURL = tempDirectory.appendingPathComponent("ABCD.audioScript.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    func testRefinedAndPermanentlyFailedFlagsRoundTrip() {
        let refinedEnvelope = AudioScriptCacheEnvelope(script: makeScript(), refined: true, llmPermanentlyFailed: false)
        store.save(refinedEnvelope, forContentFileName: "refined.json")
        XCTAssertEqual(store.load(forContentFileName: "refined.json")?.refined, true)

        let failedEnvelope = AudioScriptCacheEnvelope(script: makeScript(), refined: false, llmPermanentlyFailed: true)
        store.save(failedEnvelope, forContentFileName: "failed.json")
        XCTAssertEqual(store.load(forContentFileName: "failed.json")?.llmPermanentlyFailed, true)
    }

    func testVersionMismatchIsTreatedAsAbsent() {
        let staleScript = AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.heuristicBuilderVersion + 1)
        let envelope = AudioScriptCacheEnvelope(script: staleScript, refined: true, llmPermanentlyFailed: false)
        store.save(envelope, forContentFileName: "ABCD.json")

        XCTAssertNil(store.load(forContentFileName: "ABCD.json"), "a builder-version mismatch must rebuild, not use stale content")
    }

    func testOldPassthroughVersionIsAlsoTreatedAsAbsent() {
        let passthroughScript = AudioScript(
            spokenBlocks: [.init(blockIndex: 0, text: "Hello world")],
            totalWordCount: 2, builderVersion: AudioScript.passthroughBuilderVersion)
        let envelope = AudioScriptCacheEnvelope(script: passthroughScript, refined: false, llmPermanentlyFailed: false)
        store.save(envelope, forContentFileName: "ABCD.json")

        XCTAssertNil(store.load(forContentFileName: "ABCD.json"))
    }

    func testRemoveDeletesTheCacheFile() {
        let envelope = AudioScriptCacheEnvelope(script: makeScript(), refined: false, llmPermanentlyFailed: false)
        store.save(envelope, forContentFileName: "ABCD.json")
        XCTAssertNotNil(store.load(forContentFileName: "ABCD.json"))

        store.remove(forContentFileName: "ABCD.json")
        XCTAssertNil(store.load(forContentFileName: "ABCD.json"))
    }

    func testCorruptFileIsTreatedAsAbsent() throws {
        let url = tempDirectory.appendingPathComponent("ABCD.audioScript.json")
        try Data("not valid json".utf8).write(to: url)
        XCTAssertNil(store.load(forContentFileName: "ABCD.json"))
    }
}
