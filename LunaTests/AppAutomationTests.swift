import XCTest
import LunaAppConfig
import LunaModels
import LunaStorage

final class AppAutomationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUpWithError() throws {
        suite = "AppAutomationTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func journal(_ app: AutomationApp = .reader) -> AppAutomation { AppAutomation(app: app, directory: directory, defaults: defaults) }
    func testDefaultOffAndStableNotificationVocabulary() throws {
        let reader = journal()
        XCTAssertFalse(reader.notificationsEnabled)
        let event = try reader.record(kind: "article", itemID: "item-1", operation: "created")
        XCTAssertEqual(event.notificationTitle, "Luna.reader.article.created")
        XCTAssertEqual(event.itemID, "item-1")
        XCTAssertEqual(try reader.changes().changes, [event])
    }
    func testPagingPreservesConcurrentAppendsAndReplayingToken() throws {
        let reader = journal()
        let first = try reader.record(kind: "article", itemID: "first", operation: "created")
        let second = try reader.record(kind: "article", itemID: "second", operation: "created")
        let page = try reader.changes(limit: 1)
        XCTAssertEqual(page.changes, [first]); XCTAssertTrue(page.hasMore)
        let third = try journal().record(kind: "article", itemID: "third", operation: "created")
        let next = try reader.changes(after: page.nextToken)
        XCTAssertEqual(next.changes, [second, third]); XCTAssertFalse(next.hasMore)
        XCTAssertEqual(try reader.changes(after: page.nextToken).changes, next.changes)
        XCTAssertTrue(try reader.changes(after: next.nextToken).changes.isEmpty)
    }
    func testEmptyHistoryTokenSurvivesFirstMutation() throws {
        let token = try journal().changes().nextToken
        let event = try journal().record(kind: "article", itemID: "first", operation: "created")
        XCTAssertEqual(try journal().changes(after: token).changes, [event])
    }
    func testTokensAreScopedToAppAndGeneration() throws {
        let token = try journal().changes().nextToken
        XCTAssertThrowsError(try journal(.music).changes(after: token))
        XCTAssertThrowsError(try journal().changes(after: "invalid"))
        let file = directory.appendingPathComponent("Automation/reader.json")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try journal().changes(after: token)) { error in
            guard case AutomationError.expiredToken = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
    func testConcurrentJournalInstancesDoNotLoseEdits() throws {
        let lock = NSLock()
        var errors: [Error] = []
        let root = directory!, preferences = defaults!
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do { try AppAutomation(app: .reader, directory: root, defaults: preferences).record(kind: "article", itemID: String(index), operation: "created") }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty)
        let changes = try journal().changes().changes
        XCTAssertEqual(changes.count, 40)
        XCTAssertEqual(Set(changes.map(\.itemID)).count, 40)
        XCTAssertEqual(changes.map(\.sequence), Array(1...40).map(Int64.init))
    }
    func testDismissDoesNotConsumeChangeHistory() async throws {
        let reader = journal()
        let event = try reader.record(kind: "article", itemID: "first", operation: "created")
        await reader.dismissNotifications(eventIDs: [event.id])
        XCTAssertEqual(try reader.changes().changes, [event])
    }
    func testSeparateAppsKeepSeparateEvents() throws {
        try journal().record(kind: "article", itemID: "reader", operation: "created")
        try journal(.music).record(kind: "episode", itemID: "music", operation: "created")
        XCTAssertEqual(try journal().changes().changes.map(\.itemID), ["reader"])
        XCTAssertEqual(try journal(.music).changes().changes.map(\.itemID), ["music"])
    }
    func testReaderPublishesArticleOnlyAfterExtractionIncludingPlainLinkUpgrade() throws {
        let changes = journal()
        let store = SavesStore(containerURL: directory.appendingPathComponent("Saves"), automationJournal: changes)
        let item = store.add(urlString: "https://example.com/article")
        XCTAssertTrue(try changes.changes().changes.isEmpty)
        store.markPlainLink(item.id)
        XCTAssertEqual(try changes.changes().changes.map(\.notificationTitle), ["Luna.reader.link.created"])
        let content = ArticleContent(title: "Article", blocks: [.init(kind: .paragraph, text: "Readable text", links: [])])
        let ready = store.saveContent(content, for: item)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(try changes.changes().changes.map(\.notificationTitle), ["Luna.reader.link.created", "Luna.reader.article.created"])
        store.delete(ready)
        XCTAssertEqual(try changes.changes().changes.last?.notificationTitle, "Luna.reader.article.deleted")
    }
    func testReaderContentEditsAreEventsButPositionTicksAndNoOpsAreNot() throws {
        let changes = journal()
        let store = SavesStore(containerURL: directory.appendingPathComponent("Saves"), automationJournal: changes)
        let item = store.add(urlString: "https://example.com/article")
        let ready = store.saveContent(ArticleContent(title: "Article", blocks: [.init(kind: .paragraph, text: "First text", links: [])]), for: item)
        let baseline = try changes.changes()
        store.saveReaderExitPosition(readingProgress: 0.2, lastWordIndex: 10, for: ready.id)
        store.flushPendingUpdates()
        store.setArchived(false, for: ready.id)
        XCTAssertTrue(try changes.changes(after: baseline.nextToken).changes.isEmpty)
        _ = store.saveContent(ArticleContent(title: "Article", blocks: [.init(kind: .paragraph, text: "Changed text", links: [])]), for: ready)
        XCTAssertEqual(try changes.changes(after: baseline.nextToken).changes.map(\.notificationTitle), ["Luna.reader.article.updated"])
    }

}
