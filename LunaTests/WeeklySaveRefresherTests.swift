//
//  WeeklySaveRefresherTests.swift
//  LunaTests
//

import CryptoKit
import Foundation
import LunaModels
import LunaWeekly
import XCTest

/// A stand-in for the public database. CloudKit is NEVER exercised by tests —
/// no container exists yet, and every call site is required to survive its
/// absence.
final class FakeWeeklyCloudDatabase: WeeklyCloudDatabase, @unchecked Sendable {
    var saves: [WeeklySave] = []
    var proposals: [WeeklyProposal] = []
    var fetchError: Error?
    var writeError: Error?
    var accountAvailable = true

    private(set) var requestedKinds: [[WeeklySaveKind]] = []
    private(set) var writtenSaves: [WeeklySave] = []
    private(set) var createdProposals: [WeeklyProposal] = []
    private(set) var deletedProposals: [String] = []
    private(set) var proposalFetches = 0

    func fetchWeeklySaves(for kinds: [WeeklySaveKind]) async throws -> [WeeklySave] {
        requestedKinds.append(kinds)
        if let fetchError { throw fetchError }
        return saves.filter { kinds.contains($0.kind) }
    }

    func saveWeekly(_ save: WeeklySave) async throws {
        if let writeError { throw writeError }
        writtenSaves.append(save)
        saves.removeAll { $0.kind == save.kind }
        saves.append(save)
    }

    func fetchProposals() async throws -> [WeeklyProposal] {
        proposalFetches += 1
        if let fetchError { throw fetchError }
        return proposals
    }

    func createProposal(_ proposal: WeeklyProposal) async throws {
        if let writeError { throw writeError }
        createdProposals.append(proposal)
        proposals.removeAll { $0.recordName == proposal.recordName }
        proposals.append(proposal)
    }

    func deleteProposal(recordName: String) async throws {
        if let writeError { throw writeError }
        deletedProposals.append(recordName)
        proposals.removeAll { $0.recordName == recordName }
    }

    func accountStatus() async throws -> Bool {
        if let fetchError { throw fetchError }
        return accountAvailable
    }
}

@MainActor
final class WeeklySaveRefresherTests: XCTestCase {
    private var container: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var database: FakeWeeklyCloudDatabase!
    private var store: WeeklySaveStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyRefresherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        database = FakeWeeklyCloudDatabase()
        store = WeeklySaveStore(containerURL: container, now: { self.clock })
        let recorder = MetadataRecorder()
        WeeklySaveRefresher.metadataFetcher = { url in
            await recorder.record(url)
            return (title: "Fetched \(url)", host: "example.com", imageData: nil)
        }
        self.recorder = recorder
    }

    override func tearDownWithError() throws {
        WeeklySaveRefresher.metadataFetcher = nil
        recorder = nil
        try? FileManager.default.removeItem(at: container)
        container = nil
        try super.tearDownWithError()
    }

    private var recorder: MetadataRecorder!

    /// The shell's metadata closure is `@Sendable` and called off the main
    /// actor, so the recording has to be actor-isolated.
    private actor MetadataRecorder {
        private(set) var urls: [String] = []
        func record(_ url: String) { urls.append(url) }
    }

    func testANewValueFetchesMetadataAndUpdatesTheStore() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]

        await makeRefresher(app: .reader, publicKey: key.publicKey).refreshWeeklySaves()

        XCTAssertEqual(store.display(for: .article)?.title, "Fetched https://example.com/a")
        XCTAssertEqual(store.display(for: .article)?.subtitleHost, "example.com")
        let urls = await recorder.urls
        XCTAssertEqual(urls, ["https://example.com/a"])
    }

    func testTheSameValueTwiceWritesNothingAndFetchesNoMetadataAgain() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)

        await refresher.refreshWeeklySaves()
        // `force` bypasses the 60s debounce, not the value comparison.
        await refresher.refreshWeeklySaves(force: true)

        let urls = await recorder.urls
        XCTAssertEqual(urls.count, 1, "The unchanged entry must not be re-resolved")
    }

    func testAnInvalidSignatureIsTreatedAsAbsence() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let genuine = try sign(.article, "https://example.com/a", key: key)
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)
        database.saves = [genuine]
        await refresher.refreshWeeklySaves()
        XCTAssertNotNil(store.display(for: .article))

        database.saves = [WeeklySave(
            kind: .article, urlString: "https://evil.example/x",
            date: genuine.date, signature: genuine.signature)]
        await refresher.refreshWeeklySaves(force: true)
        XCTAssertNil(store.display(for: .article), "A forged record clears the row")
    }

    func testAnExpiredRecordClearsTheRow() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)
        await refresher.refreshWeeklySaves()
        XCTAssertNotNil(store.display(for: .article))

        clock = clock.addingTimeInterval(31 * 86_400)
        await refresher.refreshWeeklySaves(force: true)
        XCTAssertNil(store.display(for: .article))
    }

    func testAFetchErrorLeavesTheStoreUntouched() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)
        await refresher.refreshWeeklySaves()
        XCTAssertNotNil(store.display(for: .article))

        database.fetchError = NSError(domain: "CK", code: 9)
        await refresher.refreshWeeklySaves(force: true)
        XCTAssertNotNil(
            store.display(for: .article),
            "A container that isn't provisioned yet must not blank the row")
    }

    func testEachAppAsksOnlyForItsOwnKinds() async {
        await makeRefresher(app: .downloader).refreshWeeklySaves()
        XCTAssertEqual(database.requestedKinds, [[.media]])

        database = FakeWeeklyCloudDatabase()
        await makeRefresher(app: .luna).refreshWeeklySaves()
        XCTAssertEqual(database.requestedKinds, [[.article, .media, .product]])
    }

    func testTheSixtySecondDebounceSkipsARepeatRefresh() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)
        await refresher.refreshWeeklySaves()
        await refresher.refreshWeeklySaves()
        XCTAssertEqual(database.requestedKinds.count, 1)

        clock = clock.addingTimeInterval(61)
        await refresher.refreshWeeklySaves()
        XCTAssertEqual(database.requestedKinds.count, 2)
    }

    // MARK: - Proposals

    func testProposalCheckNotifiesOnceForNewNamesOnly() async {
        database.proposals = [
            WeeklyProposal(kind: .article, urlString: "https://a.example/1", date: clock),
            WeeklyProposal(kind: .media, urlString: "https://b.example/2", date: clock),
        ]
        var notifications: [(Int, String?)] = []
        let refresher = makeRefresher(
            app: .luna, isKeyHolder: true,
            notify: { count, host in notifications.append((count, host)) })

        var found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 2)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.0, 2)

        found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 0)
        XCTAssertEqual(notifications.count, 1, "Already-seen proposals never notify again")

        database.proposals.append(
            WeeklyProposal(kind: .product, urlString: "https://c.example/3", date: clock))
        found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 1)
        XCTAssertEqual(notifications.count, 2)
    }

    func testANonKeyHolderNeverFetchesProposals() async {
        database.proposals = [
            WeeklyProposal(kind: .article, urlString: "https://a.example/1", date: clock),
        ]
        let refresher = makeRefresher(app: .luna, isKeyHolder: false)
        let found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 0)
        XCTAssertEqual(database.proposalFetches, 0)
    }

    func testProposalCheckSurvivesAFetchError() async {
        database.fetchError = NSError(domain: "CK", code: 9)
        let refresher = makeRefresher(app: .luna, isKeyHolder: true)
        let found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 0)
    }

    func testCreatingAProposalTrimsAndDedupesByURL() async throws {
        let refresher = makeRefresher(app: .luna)
        try await refresher.createProposal(kind: .article, urlString: " https://x.example/1 ")
        try await refresher.createProposal(kind: .article, urlString: "https://x.example/1")
        XCTAssertEqual(database.proposals.count, 1)
        XCTAssertEqual(database.proposals.first?.urlString, "https://x.example/1")
    }

    func testPromotingWithoutTheKeyThrowsAndWritesNothing() async {
        let refresher = makeRefresher(app: .luna)
        do {
            try await refresher.promote(kind: .article, urlString: "https://x.example/1")
            XCTFail("A device without the key must not be able to promote")
        } catch {
            XCTAssertTrue(error is WeeklyPromotionError)
        }
        XCTAssertTrue(database.writtenSaves.isEmpty)
    }

    // MARK: - Helpers

    private func sign(
        _ kind: WeeklySaveKind, _ url: String, key: Curve25519.Signing.PrivateKey
    ) throws -> WeeklySave {
        try WeeklySigning.sign(kind: kind, urlString: url, date: clock, privateKey: key)
    }

    /// The shipped verifier uses the bundled public key, whose private half is
    /// not in this repository — so a refresher under test is handed the public
    /// key of whichever pair the test minted.
    private func makeRefresher(
        app: LunaApp,
        publicKey: Curve25519.Signing.PublicKey? = nil,
        isKeyHolder: Bool = false,
        notify: @escaping (Int, String?) -> Void = { _, _ in }
    ) -> WeeklySaveRefresher {
        WeeklySaveRefresher(
            database: database,
            store: store,
            app: app,
            now: { self.clock },
            verify: { save in
                guard let publicKey else { return false }
                return WeeklySigning.verify(save, publicKey: publicKey)
            },
            isKeyHolder: { isKeyHolder },
            notifyProposals: notify)
    }
}
