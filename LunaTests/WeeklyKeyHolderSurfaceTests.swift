//
//  WeeklyKeyHolderSurfaceTests.swift
//  LunaTests
//

import CryptoKit
import LunaModels
import LunaWeekly
import UIKit
import XCTest
@testable import Luna

/// The curator-only surfaces. The real private key lives outside this
/// repository, so what is pinned here is everything a device WITHOUT it must
/// do: reject the paste, hide the inbox, and never register a signing action.
@MainActor
final class WeeklyKeyHolderSurfaceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Belt and braces: nothing in the suite should ever leave a key behind.
        WeeklyPromotionKeyStore.removeKey()
    }

    override func tearDown() {
        WeeklyPromotionKeyStore.removeKey()
        super.tearDown()
    }

    func testAWrongKeyIsRejectedAndNothingIsStored() {
        let diagnostics = DiagnosticsViewController()
        diagnostics.loadViewIfNeeded()

        let stranger = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        XCTAssertFalse(diagnostics.storeWeeklyKey(stranger))
        XCTAssertFalse(diagnostics.storeWeeklyKey("obviously not a key"))
        XCTAssertFalse(diagnostics.storeWeeklyKey(""))
        XCTAssertFalse(WeeklyPromotionKeyStore.isKeyHolder)
    }

    func testTheKeyEntryButtonIsPresentButTheInboxCategoryIsNot() {
        let diagnostics = DiagnosticsViewController()
        diagnostics.loadViewIfNeeded()
        XCTAssertNotNil(diagnostics.view.firstDescendant(identifier: "diagnostics.weeklyKey"))
        // The reset button keeps its identifier and its place beside it.
        XCTAssertNotNil(
            diagnostics.view.firstDescendant(identifier: "diagnostics.resetOnboarding"))

        let settings = SettingsViewController(emailIsConfigured: { true })
        settings.loadViewIfNeeded()
        let titles = (0..<settings.tableView.numberOfRows(inSection: 0)).compactMap {
            settings.tableView(
                settings.tableView, cellForRowAt: IndexPath(row: $0, section: 0)
            ).contentConfiguration as? UIListContentConfiguration
        }.compactMap(\.text)
        XCTAssertFalse(
            titles.contains("Save of the Week"),
            "The proposals inbox is for the key-holder only")
    }

    func testTheProposalsScreenListsWhatTheDatabaseHasAndDeletesFromIt() async throws {
        let database = FakeWeeklyCloudDatabase()
        database.proposals = [
            WeeklyProposal(
                kind: .article, urlString: "https://a.example/one", date: Date()),
            WeeklyProposal(
                kind: .media, urlString: "https://b.example/two/three", date: Date()),
        ]
        let screen = WeeklyProposalsScreen(
            refresher: WeeklySaveRefresher(
                database: database, store: scratchStore(), app: .luna))
        screen.loadViewIfNeeded()
        await settle()

        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 2)
        screen.tableView(
            screen.tableView, commit: .delete, forRowAt: IndexPath(row: 0, section: 0))
        await settle()
        XCTAssertEqual(database.deletedProposals.count, 1)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 1)
    }

    /// A container that doesn't exist yet throws on every query; the screen has
    /// to render that as an empty list, not a crash.
    func testTheProposalsScreenSurvivesAFetchError() async {
        let database = FakeWeeklyCloudDatabase()
        database.fetchError = NSError(domain: "CK", code: 9)
        let screen = WeeklyProposalsScreen(
            refresher: WeeklySaveRefresher(
                database: database, store: scratchStore(), app: .luna))
        screen.loadViewIfNeeded()
        await settle()
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 0)
    }

    func testProposalTitlesDropTheSchemeAndKeepThePath() {
        XCTAssertEqual(
            WeeklyProposalsScreen.displayTitle(for: WeeklyProposal(
                kind: .article, urlString: "https://a.example/one/two", date: Date())),
            "a.example/one/two")
        XCTAssertEqual(
            WeeklyProposalsScreen.displayTitle(for: WeeklyProposal(
                kind: .article, urlString: "https://a.example", date: Date())),
            "a.example")
    }

    func testTheBackgroundCheckIdentifierMatchesTheDeclaredPermittedIdentifier() throws {
        let permitted = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
                as? [String])
        XCTAssertTrue(permitted.contains(WeeklyProposalBackgroundCheck.taskID))
    }

    // MARK: - Helpers

    private func scratchStore() -> WeeklySaveStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyKeyHolder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return WeeklySaveStore(containerURL: directory)
    }

    /// The screen loads its rows in a detached `Task`; let it land.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private extension UIView {
    func firstDescendant(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.firstDescendant(identifier: identifier) }.first
    }
}
