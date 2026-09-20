//
//  LLMHandoffStoreTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaStorage

final class LLMHandoffStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> LLMHandoffStore {
        LLMHandoffStore(containerURL: directory, now: { [unowned self] in self.clock })
    }

    func testARecoveryHandoffIsFoundByItemAndByURL() {
        let store = makeStore()
        let itemID = UUID()
        store.begin(
            .recovery(itemID: itemID, urlString: "https://example.com/a"),
            provider: .claude, claudeTarget: .chat)

        XCTAssertEqual(store.record(forItemID: itemID)?.provider, .claude)
        XCTAssertEqual(store.record(forURL: "https://example.com/a")?.provider, .claude)
        XCTAssertNil(store.record(forItemID: UUID()))
        XCTAssertNil(store.record(forURL: "https://example.com/b"))
    }

    /// Asking a second provider about the same page replaces the first: the
    /// card shows one answer's worth of waiting, not two.
    func testASecondHandoffForThePageReplacesTheFirst() {
        let store = makeStore()
        let itemID = UUID()
        store.begin(
            .recovery(itemID: itemID, urlString: "https://example.com/a"),
            provider: .chatGPT, claudeTarget: .chat)
        store.begin(
            .recovery(itemID: itemID, urlString: "https://example.com/a"),
            provider: .claude, claudeTarget: .code)

        XCTAssertEqual(store.record(forItemID: itemID)?.provider, .claude)
        XCTAssertEqual(store.record(forItemID: itemID)?.claudeTarget, .code)
    }

    func testThePluginHandoffKeepsTheUsersOwnWords() {
        let store = makeStore()
        store.begin(
            .plugin(description: "a recipe site", host: "example.com"), provider: .chatGPT)

        guard case .plugin(let description, let host) = store.pluginRecord()?.kind else {
            return XCTFail("expected a plugin record")
        }
        XCTAssertEqual(description, "a recipe site")
        XCTAssertEqual(host, "example.com")
    }

    func testApplyingTheFileClearsTheRecord() {
        let store = makeStore()
        let record = store.begin(
            .recovery(itemID: UUID(), urlString: "https://example.com/a"), provider: .claude)
        store.clear(id: record.id)
        XCTAssertNil(store.record(forURL: "https://example.com/a"))
    }

    /// A reply that never came back stops being waited on. The card must not
    /// promise a result forever.
    func testARecordExpiresAfterADay() {
        let store = makeStore()
        store.begin(
            .recovery(itemID: UUID(), urlString: "https://example.com/a"), provider: .claude)

        clock = clock.addingTimeInterval(LLMHandoffStore.lifetime - 1)
        XCTAssertNotNil(store.record(forURL: "https://example.com/a"))
        clock = clock.addingTimeInterval(2)
        XCTAssertNil(store.record(forURL: "https://example.com/a"))
    }

    func testPruneRemovesTheExpiredRowsFromTheFile() {
        let store = makeStore()
        store.begin(
            .recovery(itemID: UUID(), urlString: "https://example.com/a"), provider: .claude)
        clock = clock.addingTimeInterval(LLMHandoffStore.lifetime + 1)
        store.prune()

        let data = try? Data(contentsOf: directory.appendingPathComponent("llmHandoffs.json"))
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "{}")
    }

    /// The extension's card starts a hand-off and the app reads it: two live
    /// stores on one file, as two processes.
    func testEitherLiveStoreSeesTheOthersWrites() {
        let extensionSide = makeStore()
        let app = makeStore()
        extensionSide.begin(
            .recovery(itemID: UUID(), urlString: "https://example.com/a"), provider: .chatGPT)
        XCTAssertEqual(app.record(forURL: "https://example.com/a")?.provider, .chatGPT)
    }
}

final class PendingRecoveryRecipeStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> PendingRecoveryRecipeStore {
        PendingRecoveryRecipeStore(containerURL: directory, now: { [unowned self] in self.clock })
    }

    private func row(page: String = "https://example.com/a") -> PendingRecoveryRecipe {
        PendingRecoveryRecipe(
            pageURL: URL(string: page)!,
            recipe: LunaRecoveryRecipe(
                url: URL(string: "https://example.com/a?output=amp")!,
                headers: ["user-agent": "googlebot"],
                javascript: "return document.body.outerHTML", returns: .html),
            dateWritten: clock)
    }

    /// The row has to rebuild the recipe the app replays, header set and all.
    func testARowRoundTripsTheRecipeThroughTheFile() throws {
        let store = makeStore()
        store.append(row())

        let taken = try XCTUnwrap(makeStore().takeAll().first)
        let recipe = try XCTUnwrap(taken.recipe)
        XCTAssertEqual(recipe.url.absoluteString, "https://example.com/a?output=amp")
        XCTAssertEqual(recipe.headers, ["user-agent": "googlebot"])
        XCTAssertEqual(recipe.javascript, "return document.body.outerHTML")
        XCTAssertEqual(recipe.returns, .html)
        XCTAssertEqual(taken.pageURL?.absoluteString, "https://example.com/a")
    }

    func testTakeAllEmptiesTheQueue() {
        let store = makeStore()
        store.append(row())
        XCTAssertEqual(store.takeAll().count, 1)
        XCTAssertTrue(store.takeAll().isEmpty)
    }

    func testASecondFileForThePageReplacesTheFirst() {
        let store = makeStore()
        store.append(row())
        clock = clock.addingTimeInterval(60)
        store.append(row())
        XCTAssertEqual(store.takeAll().count, 1)
    }

    func testAStaleRecipeIsDropped() {
        let store = makeStore()
        store.append(row())
        clock = clock.addingTimeInterval(PendingRecoveryRecipeStore.lifetime + 1)
        XCTAssertTrue(store.takeAll().isEmpty)
    }
}
