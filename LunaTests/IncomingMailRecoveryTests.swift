import Foundation
import XCTest
import UIKit
import LunaMailAccount
import LunaModels
import LunaSocial
import LunaStorage
@testable import LunaMailTransport
@testable import LunaSaves
@testable import Luna

final class IncomingMailRecoveryTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: SavesStore!
    private var accounts: EmailAccountStore!
    private var transport: RecoveryMailTransport!
    private var importer: IncomingMailImporter!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "IncomingMailRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        IncomingMailSettings.testDefaultsOverride = MigratingAppGroupDefaults(group: defaults, legacy: defaults)
        store = SavesStore(containerURL: directory)
        accounts = EmailAccountStore(defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        accounts.save(EmailAccount(providerID: .gmail, address: "reader@example.com"),
                      credential: .appPassword("scratch"))
        transport = RecoveryMailTransport()
        importer = IncomingMailImporter(store: store, friends: FriendsStore(containerURL: directory),
                                        accountStore: accounts, makeTransport: { [transport] in transport })
        IncomingMailSettings.cursor = .imap(uid: 100, uidValidity: 7)
        IncomingMailSettings.allowedSenders = ["sender@example.com"]
        IncomingMailSettings.subjectFilters = ["Daily News"]
    }

    override func tearDown() {
        importer = nil
        accounts = nil
        store = nil
        IncomingMailSettings.testDefaultsOverride = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func message(id: String = "90", headers: [String: String] = [:], body: String = "A useful newsletter with enough text to form a readable article.") -> FetchedMessage {
        FetchedMessage(id: id, uid: Int(id), from: "Sender <sender@example.com>",
                       subject: "Daily News", date: "14 Oct 2026", headers: headers,
                       bodyText: body, marker: nil)
    }

    func testRecentScanReappliesFiltersBehindCursorAndDoesNotAdvanceIt() async throws {
        transport.messages = [message()]
        let now = ISO8601DateFormatter().date(from: "2026-10-14T00:30:00Z")!
        let summary = try await importer.importRecentMail(now: now)
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(transport.since, ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z"))
        XCTAssertEqual(transport.senders, ["sender@example.com"])
        XCTAssertEqual(transport.subjects, ["Daily News"])
        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 100, uidValidity: 7))
        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.items().first?.state, .ready)
    }

    func testRepeatedScansAndAutomaticPollSkipProcessedMailEvenAfterDeletionAndReopen() async throws {
        transport.messages = [message(id: "110"), message(id: "110")]
        let first = try await importer.importRecentMail()
        XCTAssertEqual(first, .init(processed: 1, skipped: 1))
        let item = try XCTUnwrap(store.items().first)
        store.delete(item)
        let reopened = SavesStore(containerURL: directory)
        let next = IncomingMailImporter(store: reopened, friends: FriendsStore(containerURL: directory),
                                        accountStore: accounts, makeTransport: { [transport] in transport })
        let repeated = try await next.importRecentMail()
        XCTAssertEqual(repeated, .init(processed: 0, skipped: 2))
        await next.importNewMail()
        XCTAssertTrue(reopened.items().isEmpty)
        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 110, uidValidity: 7))
        XCTAssertEqual(transport.marked, ["110"], "Only the first processing marks mail read")
    }

    func testLegacyImportedEmailIsSkippedWithoutOverwritingOrSendingIt() async throws {
        let existing = store.add(urlString: "lunamail://90", source: .email)
        let content = MailArticleBuilder.article(from: IncomingMessage(uid: 90, from: "sender@example.com", subject: "Daily News", date: "", contentType: "text/plain", transferEncoding: "", body: "An already imported newsletter.", urls: []))!
        store.saveContent(content, for: existing)
        transport.messages = [message()]
        let result = try await importer.importRecentMail()
        XCTAssertEqual(result, .init(processed: 0, skipped: 1))
        XCTAssertEqual(store.items().map(\.id), [existing.id])
        XCTAssertEqual(store.item(withID: existing.id)?.state, .ready)
        XCTAssertTrue(transport.marked.isEmpty)
    }

    func testProcessedMessageWithNoUsableContentIsStillDeduped() async throws {
        transport.messages = [message(body: "")]
        _ = try await importer.importRecentMail()
        let result = try await importer.importRecentMail()
        XCTAssertEqual(result, .init(processed: 0, skipped: 1))
        XCTAssertTrue(store.items().isEmpty)
    }

    func testFailuresAreSurfacedAndLeaveCursorUntouched() async {
        transport.error = URLError(.notConnectedToInternet)
        do {
            _ = try await importer.importRecentMail()
            XCTFail("Must surface the transport error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 100, uidValidity: 7))
    }

    func testOverlappingManualAndAutomaticChecksDoNotProcessTwice() async throws {
        let entered = RecoveryLatch()
        let release = RecoveryLatch()
        transport.messages = [message()]
        transport.beforeFetch = {
            await entered.open()
            await release.wait()
        }
        let first = Task { try await self.importer.importRecentMail() }
        await entered.wait()
        await importer.importNewMail()
        do {
            _ = try await importer.importRecentMail()
            XCTFail("An overlapping manual check must report busy")
        } catch IncomingMailImporter.ImportError.alreadyRunning { }
        await release.open()
        let summary = try await first.value
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(store.items().count, 1)
    }

    func testAccountSwitchDuringFetchDoesNotImportOrAdvanceCursor() async {
        transport.messages = [message()]
        transport.beforeFetch = { self.accounts.clear() }
        do {
            _ = try await importer.importRecentMail()
            XCTFail("Must discard the previous account's response")
        } catch IncomingMailImporter.ImportError.accountChanged { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(store.items().isEmpty)
        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 100, uidValidity: 7))
    }

    func testMessageIdentityIsScopedAndMessageIDSurvivesUIDRenumbering() {
        let account = accounts.account!
        let other = EmailAccount(providerID: .gmail, address: "other@example.com")
        let a = IncomingMailImporter.messageKey(message(), account: account, cursor: .imap(uid: 90, uidValidity: 7))
        XCTAssertNotEqual(a, IncomingMailImporter.messageKey(message(), account: other, cursor: .imap(uid: 90, uidValidity: 7)))
        XCTAssertNotEqual(a, IncomingMailImporter.messageKey(message(), account: account, cursor: .imap(uid: 90, uidValidity: 8)))
        let stable = message(headers: ["message-id": "<news@example.com>"])
        XCTAssertEqual(IncomingMailImporter.messageKey(stable, account: account, cursor: .imap(uid: 90, uidValidity: 7)),
                       IncomingMailImporter.messageKey(stable, account: account, cursor: .imap(uid: 90, uidValidity: 8)))
    }

    @MainActor
    func testSettingsOffersRecentPullAndDisablesItWhenAccountNeedsRecovery() {
        let screen = EmailAndKindleSettingsScreen(accountStore: accounts)
        screen.loadViewIfNeeded()
        let path = IndexPath(row: IncomingMailSettings.allowedSenders.count + 3, section: 1)
        let cell = screen.tableView(screen.tableView, cellForRowAt: path)
        XCTAssertEqual(cell.accessibilityIdentifier, "email.pullRecent")
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.text, "Pull Recent Emails")
        XCTAssertEqual(cell.selectionStyle, .default)
        XCTAssertFalse(screen.tableView(screen.tableView, canEditRowAt: path))
        accounts.markAuthenticationIssue(.credentialsRejected)
        let disabled = screen.tableView(screen.tableView, cellForRowAt: path)
        XCTAssertEqual(disabled.selectionStyle, .none)
        XCTAssertTrue(disabled.accessibilityTraits.contains(.notEnabled))
    }
}

private final class RecoveryMailTransport: EmailTransport, @unchecked Sendable {
    var beforeFetch: (() async -> Void)?
    var messages: [FetchedMessage] = []
    var error: Error?
    var since: Date?
    var senders: [String] = []
    var subjects: [String] = []
    var marked: [String] = []
    func verifyCredentials() async throws {}
    func send(_ email: OutgoingEmail) async throws {}
    func fetchShares(after cursor: MailCursor, extraSenders: [String], extraSubjects: [String]) async throws -> FetchResult {
        await beforeFetch?()
        if let error { throw error }
        return FetchResult(messages: messages, cursor: .imap(uid: 110, uidValidity: 7))
    }
    func fetchRecentShares(since: Date, extraSenders: [String], extraSubjects: [String]) async throws -> FetchResult {
        self.since = since
        senders = extraSenders
        subjects = extraSubjects
        return try await fetchShares(after: .fresh, extraSenders: extraSenders, extraSubjects: extraSubjects)
    }
    func markRead(_ ids: [String]) async throws { marked += ids }
    func createLunaFilter() async throws -> FilterOutcome { .guidedRequired }
}

private actor RecoveryLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
