//
//  WeeklySaveTests.swift
//  LunaTests
//
//  Merges WeeklyKeyHolderSurfaceTests, WeeklyPromotionMenuTests,
//  WeeklyRowHostTests, WeeklySaveRefresherTests, WeeklySaveStoreTests, and
//  WeeklySigningTests: the whole Save-of-the-Week feature (signing, storage,
//  refresh, the curator-only surfaces, the promotion menu, and the card-deck
//  row host).
//

import CryptoKit
import Foundation
import LunaDesignSystem
import LunaModels
import LunaWeekly
import UIKit
import XCTest
@testable import Luna

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
final class WeeklySaveTests: XCTestCase {

    // MARK: - Shared fixtures
    //
    // Union of every merged file's setUp/tearDown. Individual sections below
    // use only the pieces they need; the rest is harmless idle state for them.

    private var container: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var store: WeeklySaveStore!
    private var database: FakeWeeklyCloudDatabase!
    private var recorder: MetadataRecorder!
    private var hostWindow: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()

        // WeeklyKeyHolderSurfaceTests: belt and braces — nothing in the suite
        // should ever leave a key behind.
        WeeklyPromotionKeyStore.removeKey()

        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklySaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        store = WeeklySaveStore(containerURL: container, now: { self.clock })

        // WeeklySaveRefresherTests: the shell's metadata fetcher is `Sendable`
        // and called off the main actor, so the recording has to be
        // actor-isolated.
        database = FakeWeeklyCloudDatabase()
        let recorder = MetadataRecorder()
        WeeklySaveRefresher.metadataFetcher = FakeMetadataFetcher { url in
            await recorder.record(url)
            return (title: "Fetched \(url)", host: "example.com", imageData: nil)
        }
        self.recorder = recorder

        // WeeklyRowHostTests
        UIView.setAnimationsEnabled(false)
    }

    override func tearDownWithError() throws {
        WeeklyPromotionKeyStore.removeKey()

        WeeklySaveRefresher.metadataFetcher = nil
        recorder = nil

        hostWindow?.isHidden = true
        hostWindow = nil

        store = nil
        database = nil
        try? FileManager.default.removeItem(at: container)
        container = nil

        UIView.setAnimationsEnabled(true)
        try super.tearDownWithError()
    }

    /// The shell's metadata closure is `@Sendable` and called off the main
    /// actor, so the recording has to be actor-isolated.
    private actor MetadataRecorder {
        private(set) var urls: [String] = []
        func record(_ url: String) { urls.append(url) }

        /// Records the attempt and reports whether it was the first, so a test
        /// can fail one read and satisfy the next.
        func recordAndIsFirst(_ url: String) -> Bool {
            urls.append(url)
            return urls.count == 1
        }
    }

    // MARK: - WeeklyKeyHolderSurfaceTests
    //
    // The curator-only surfaces. The real private key lives outside this
    // repository, so what is pinned here is everything a device WITHOUT it
    // must do: reject the paste, hide the inbox, and never register a signing
    // action.

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
        // The erase button keeps its place beside it.
        XCTAssertNotNil(
            diagnostics.view.firstDescendant(identifier: "diagnostics.eraseAllData"))

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

    // MARK: WeeklyKeyHolderSurfaceTests helpers

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

    // MARK: - WeeklyPromotionMenuTests

    func testANonKeyHolderIsOfferedTheProposeVerbAlone() {
        let actions = WeeklyPromotionMenu.actions(
            for: readySave(), presenter: UIViewController(), isKeyHolder: false)
        XCTAssertEqual(actions.map(\.title), ["Propose Save of the Week"])
    }

    /// Holding the key ADDS the promote verb; it never takes the propose one
    /// away. A curator who wants to queue a link rather than publish it today
    /// would otherwise have to remove their own key to do it.
    func testAKeyHolderIsOfferedPromoteAndStillPropose() {
        XCTAssertEqual(
            WeeklyPromotionMenu.actions(
                for: readySave(), presenter: UIViewController(),
                isKeyHolder: true, app: .reader
            ).map(\.title),
            ["Promote to Read of the Week", "Propose Save of the Week"])

        XCTAssertEqual(
            WeeklyPromotionMenu.actions(
                for: readySave(), presenter: UIViewController(),
                isKeyHolder: true, app: .luna
            ).map(\.title),
            ["Promote to Save of the Week", "Propose Save of the Week"])
    }

    /// A failed save has nothing behind it to recommend, so no verb at all
    /// appears — for a key-holder or anyone else.
    func testAFailedSaveIsNeverACandidate() {
        var failed = ReadingListItem(
            seed: "weekly-failed", urlString: "https://example.com/failed",
            title: nil, dateAdded: Date(), state: .failed)
        failed.platform = nil
        XCTAssertNil(WeeklyPromotionMenu.weeklyKind(for: failed))
        XCTAssertTrue(WeeklyPromotionMenu.actions(
            for: failed, presenter: UIViewController(), isKeyHolder: false).isEmpty)
        XCTAssertTrue(WeeklyPromotionMenu.actions(
            for: failed, presenter: UIViewController(), isKeyHolder: true).isEmpty)
    }

    func testTheItemsOwnKindDecidesTheWeeklyKind() {
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: readySave()), .article)

        var media = readySave()
        media.platform = .youtube
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: media), .media)

        var product = readySave()
        product.priceTracker = PriceTracker(
            productName: "A Thing", firstStoreURL: "https://shop.example/p",
            price: 9, currency: "USD", brand: nil, productID: nil)
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: product), .product)
    }

    // MARK: WeeklyPromotionMenuTests helpers

    private func readySave() -> ReadingListItem {
        ReadingListItem(
            seed: "weekly-menu", urlString: "https://example.com/weekly-menu",
            title: "A Save", dateAdded: Date(), state: .ready, wordCount: 400)
    }

    // MARK: - WeeklyRowHostTests

    func testAnEmptyStoreProducesNoRows() {
        let host = makeHost(app: .reader)
        XCTAssertTrue(host.isEmpty)
        XCTAssertTrue(host.rows.isEmpty)
    }

    func testASeededStoreProducesOneRowPerLiveKindExceptCentralKeepsNilSlots() {
        seed(.article, "https://a.example/1")
        seed(.media, "https://b.example/2")
        XCTAssertEqual(makeHost(app: .reader).rows.count, 1)
        XCTAssertEqual(makeHost(app: .luna).rows.count, 3)
        XCTAssertEqual(makeHost(app: .priceTracker).rows.count, 0)
    }

    /// The replacement eclipse: the corona is real, it lives OUTSIDE the
    /// clipping child (its overhang is the whole effect), and the old row is
    /// gone by the time it finishes.
    func testReplacingTheVisibleRowRunsTheEclipse() throws {
        // Animations must be live here: with them off the keyframe run
        // completes immediately and the dressing is torn down before it can be
        // inspected.
        UIView.setAnimationsEnabled(true)
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        host.layoutIfNeeded()
        let original = try XCTUnwrap(host.rows.first)

        seed(.article, "https://a.example/2")
        host.reload(animated: true)

        XCTAssertTrue(host.isReplacing)
        let corona = try XCTUnwrap(
            host.subviews.compactMap { $0 as? EclipseCoronaView }.first,
            "The corona must be a direct child of the non-clipping host")
        XCTAssertFalse(host.clipsToBounds)
        XCTAssertEqual(corona.frame.size, host.bounds.size)
        XCTAssertEqual(host.rows.count, 1)
        XCTAssertFalse(host.rows[0] === original)

        XCTAssertTrue(try XCTUnwrap(host.rows[0].superview).clipsToBounds)
    }

    func testAnAppearingRowIsNotAnEclipse() {
        UIView.setAnimationsEnabled(true)
        let host = makeHost(app: .reader)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        host.layoutIfNeeded()
        seed(.article, "https://a.example/1")
        host.reload(animated: true)
        XCTAssertFalse(host.isReplacing)
        XCTAssertTrue(host.subviews.compactMap { $0 as? EclipseCoronaView }.isEmpty)
    }

    func testAVanishedEntryEmptiesTheHostAndReportsThePresenceChange() {
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        var presenceChanges = 0
        host.onPresenceChange = { presenceChanges += 1 }
        store.clear(kind: .article)
        host.reload(animated: true)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(presenceChanges, 1)
    }

    func testTappingARowReportsItsStoredURL() throws {
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        var saved: String?
        host.onSave = { url, _ in saved = url }
        try XCTUnwrap(host.rows.first).sendActions(for: .touchUpInside)
        XCTAssertEqual(saved, "https://a.example/1")
    }

    // MARK: WeeklyRowHostTests: Central-app cycling

    func testTheCentralCycleKeepsNilKindsInItsCadenceAndTheCardInFront() {
        seed(.article, "https://a.example/1")
        let clock = FakeCycleClock()
        let host = makeHost(app: .luna, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()
        XCTAssertTrue(clock.pacer.isRunning, "A nil sibling kind still gets a turn")

        seed(.media, "https://b.example/2")
        host.reload(animated: false)
        XCTAssertTrue(clock.pacer.isRunning)

        host.cardDidLeaveCenter()
        XCTAssertFalse(clock.pacer.isRunning, "A card off centre stops cycling")
    }

    func testATickAdvancesToTheNextKind() {
        seed(.article, "https://a.example/1")
        seed(.media, "https://b.example/2")
        let clock = FakeCycleClock()
        let host = makeHost(app: .luna, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()

        XCTAssertEqual(clock.interval, WeeklyCyclePacer.interval)
        XCTAssertFalse(host.rows[1].isHidden == false)
        clock.tick()
        XCTAssertFalse(host.rows[1].isHidden, "The neighbour is on screen after a tick")
    }

    func testANilCentralTurnLeavesNoVisibleCardBehind() {
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .luna)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)

        host.advance(forward: true, velocity: 0)

        XCTAssertFalse(host.rows[1].isHidden)
        XCTAssertEqual(host.rows[1].alpha, 0, "A missing kind must not draw a blank row shell")
    }

    func testCentralRowsUseTheTintOfTheAppThatOwnsEachKind() throws {
        seed(.article, "https://a.example/1")
        seed(.media, "https://b.example/2")
        seed(.product, "https://c.example/3")
        let host = makeHost(app: .luna)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)

        let mediaArtwork = try XCTUnwrap(
            host.rows[1].makeUtilCardSaveTransitionArtwork(in: host))
        let productArtwork = try XCTUnwrap(
            host.rows[2].makeUtilCardSaveTransitionArtwork(in: host))
        let media = try XCTUnwrap(mediaArtwork.rimTint)
        let product = try XCTUnwrap(productArtwork.rimTint)
        let softOrange = LunaSurfacePalette.blended(
            LunaSurfacePalette.baseColor(for: .downloader), toward: .white, amount: 0.18)
            .withAlphaComponent(UtilURLRow.weeklyRimAlpha)
        let softGreen = LunaSurfacePalette.blended(
            LunaSurfacePalette.baseColor(for: .priceTracker), toward: .white, amount: 0.18)
            .withAlphaComponent(UtilURLRow.weeklyRimAlpha)

        XCTAssertEqual(media, softOrange)
        XCTAssertEqual(product, softGreen)
    }

    func testAManualGestureLatchesAutoAdvanceOffUntilTheCardLeavesOrTheAppReturns() {
        let pacer = WeeklyCyclePacer(scheduler: { _, _ in {} })
        pacer.liveKindCount = 2
        pacer.isInWindow = true
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        pacer.userDidTakeControl()
        XCTAssertFalse(pacer.canRun)
        XCTAssertTrue(pacer.userTookControl)

        // Leaving centre drops the latch (and stops for the other reason).
        pacer.cardDidLeaveCenter()
        XCTAssertFalse(pacer.userTookControl)
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        // So does a background → foreground round trip.
        pacer.userDidTakeControl()
        pacer.appDidEnterBackground()
        XCTAssertFalse(pacer.canRun)
        pacer.appWillEnterForeground()
        XCTAssertTrue(pacer.canRun)
    }

    func testReduceMotionAndAReplacementBothSuppressTheCycle() {
        let pacer = WeeklyCyclePacer(scheduler: { _, _ in {} })
        pacer.liveKindCount = 3
        pacer.isInWindow = true
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        pacer.reduceMotion = true
        XCTAssertFalse(pacer.canRun)
        pacer.reduceMotion = false

        pacer.isReplacing = true
        XCTAssertFalse(pacer.canRun)
        pacer.isReplacing = false

        pacer.isUserTouching = true
        XCTAssertFalse(pacer.canRun)
    }

    func testADeferredWeeklyRevealSuppressesThePacerUntilItIsVisible() {
        let pacer = WeeklyCyclePacer(scheduler: { _, _ in {} })
        pacer.liveKindCount = 3
        pacer.isInWindow = true
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        pacer.isCycleVisible = false
        XCTAssertFalse(pacer.canRun)
        pacer.isCycleVisible = true
        XCTAssertTrue(pacer.canRun)
    }

    /// A single-kind app never cycles, so a faceted app's host is inert.
    func testAFacetedAppNeverStartsThePacer() {
        seed(.article, "https://a.example/1")
        let clock = FakeCycleClock()
        let host = makeHost(app: .reader, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()
        XCTAssertFalse(clock.pacer.isRunning)
    }

    // MARK: WeeklyRowHostTests helpers

    /// A pacer whose cadence the test drives by hand.
    private final class FakeCycleClock {
        private(set) var interval: TimeInterval = 0
        private var tickBlock: (() -> Void)?
        lazy var pacer = WeeklyCyclePacer(scheduler: { [weak self] interval, tick in
            self?.interval = interval
            self?.tickBlock = tick
            return { [weak self] in self?.tickBlock = nil }
        })
        func tick() { tickBlock?() }
    }

    private func window(_ host: WeeklySaveRowHost) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        hostWindow = window
        host.layoutIfNeeded()
    }

    private func makeHost(
        app: LunaApp, pacer: WeeklyCyclePacer = WeeklyCyclePacer()
    ) -> WeeklySaveRowHost {
        WeeklySaveRowHost(store: store, app: app, now: { self.clock }, pacer: pacer)
    }

    private func seed(_ kind: WeeklySaveKind, _ url: String) {
        let key = Curve25519.Signing.PrivateKey()
        let save = try! WeeklySigning.sign(
            kind: kind, urlString: url,
            date: clock.addingTimeInterval(-86_400), privateKey: key)
        store.setDisplay(
            WeeklySaveDisplay(
                save: save, title: url, subtitleHost: "example.com", imageData: nil),
            for: kind)
    }

    // MARK: - WeeklySaveRefresherTests

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

    /// The value comparison above must not swallow an entry whose METADATA
    /// never arrived. One failed read (offline at launch, a timeout) otherwise
    /// left the row showing the bare host and the generic glyph for the whole
    /// 30-day life of the entry, because every later launch saw the same
    /// URL/date and skipped it.
    func testAFailedMetadataReadIsRetriedUntilItSucceeds() async throws {
        let key = Curve25519.Signing.PrivateKey()
        database.saves = [try sign(.article, "https://example.com/a", key: key)]
        let refresher = makeRefresher(app: .reader, publicKey: key.publicKey)
        let attempts = MetadataRecorder()
        WeeklySaveRefresher.metadataFetcher = FakeMetadataFetcher { url in
            let isFirst = await attempts.recordAndIsFirst(url)
            return isFirst ? nil : (title: "The Inner Ring", host: "example.com", imageData: nil)
        }

        await refresher.refreshWeeklySaves()
        XCTAssertEqual(
            store.display(for: .article)?.title, "example.com",
            "A failed read still shows the row, on the host")
        XCTAssertEqual(store.display(for: .article)?.hasResolvedMetadata, false)

        await refresher.refreshWeeklySaves(force: true)

        XCTAssertEqual(store.display(for: .article)?.title, "The Inner Ring")
        XCTAssertEqual(store.display(for: .article)?.hasResolvedMetadata, true)
        let urls = await attempts.urls
        XCTAssertEqual(urls.count, 2, "The unresolved entry must be asked again")

        await refresher.refreshWeeklySaves(force: true)
        let settled = await attempts.urls
        XCTAssertEqual(settled.count, 2, "…and left alone once it resolves")
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

    // MARK: WeeklySaveRefresherTests: Proposals

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

    /// The curator can propose as well as promote, so the inbox check must not
    /// hand them a notification about their own submission.
    func testACuratorsOwnProposalNeverNotifiesThem() async throws {
        var notifications: [(Int, String?)] = []
        let refresher = makeRefresher(
            app: .luna, isKeyHolder: true,
            notify: { count, host in notifications.append((count, host)) })
        try await refresher.createProposal(kind: .article, urlString: "https://mine.example/1")
        database.proposals.append(
            WeeklyProposal(kind: .media, urlString: "https://theirs.example/2", date: clock))

        let found = await refresher.checkProposalsIfKeyHolder()
        XCTAssertEqual(found, 1, "Only the proposal this device didn't write is new")
        XCTAssertEqual(notifications.map(\.0), [1])
        XCTAssertEqual(notifications.first?.1, "theirs.example")
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

    // MARK: WeeklySaveRefresherTests helpers

    private func sign(
        _ kind: WeeklySaveKind, _ url: String, key: Curve25519.Signing.PrivateKey
    ) throws -> WeeklySave {
        try WeeklySigning.sign(kind: kind, urlString: url, date: clock, privateKey: key)
    }

    /// A stand-in metadata fetcher running whatever the test wrote.
    private struct FakeMetadataFetcher: WeeklyMetadataFetching {
        let fetch: @Sendable (String) async -> (title: String, host: String, imageData: Data?)?

        init(_ fetch: @escaping @Sendable (String) async -> (title: String, host: String, imageData: Data?)?) {
            self.fetch = fetch
        }

        func fetchMetadata(
            forURLString urlString: String
        ) async -> (title: String, host: String, imageData: Data?)? {
            await fetch(urlString)
        }
    }

    /// Verifies against the public half of whichever pair the test minted; no
    /// key at all means nothing verifies.
    private struct FakeSignatureVerifier: WeeklySignatureVerifying {
        let publicKey: Curve25519.Signing.PublicKey?

        func isSignatureValid(_ save: WeeklySave) -> Bool {
            guard let publicKey else { return false }
            return WeeklySigning.verify(save, publicKey: publicKey)
        }
    }

    private struct FakeKeyHolder: WeeklyKeyHolding {
        let isKeyHolder: Bool
    }

    private struct FakeProposalNotifier: WeeklyProposalNotifying {
        let notify: (Int, String?) -> Void

        func notifyProposals(count: Int, host: String?) {
            notify(count, host)
        }
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
            verifier: FakeSignatureVerifier(publicKey: publicKey),
            keyHolder: FakeKeyHolder(isKeyHolder: isKeyHolder),
            proposalNotifier: FakeProposalNotifier(notify: notify))
    }

    // MARK: - WeeklySaveStoreTests

    func testDisplayRoundTripsThroughDisk() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 1), for: .article)

        let reopened = makeStore()
        XCTAssertEqual(reopened.display(for: .article)?.title, "A Title")
        XCTAssertEqual(reopened.display(for: .article)?.subtitleHost, "example.com")
        XCTAssertNil(reopened.display(for: .media))
    }

    func testAnEntryOneSecondPastThirtyDaysNoLongerExists() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0), for: .article)
        XCTAssertNotNil(store.display(for: .article))

        clock = clock.addingTimeInterval(29 * 86_400)
        XCTAssertNotNil(makeStore().display(for: .article), "29 days is still live")

        clock = clock.addingTimeInterval(86_400 + 1)
        XCTAssertNil(makeStore().display(for: .article), "30 days + 1s has aged out")
    }

    func testMonthTierStartsAtNineDays() {
        let eightDays = display(daysOld: 8).save
        XCTAssertFalse(eightDays.isMonthTier(now: clock))
        let nineDays = display(daysOld: 9).save
        XCTAssertTrue(nineDays.isMonthTier(now: clock))
        XCTAssertFalse(nineDays.isExpired(now: clock))
    }

    func testSettingAndClearingPostDidChangeWithTheKind() {
        let store = makeStore()
        let set = expectation(forNotification: WeeklySaveStore.didChange, object: nil) { note in
            note.userInfo?[WeeklySaveStore.kindKey] as? String == "media"
        }
        store.setDisplay(display(daysOld: 0, kind: .media), for: .media)
        wait(for: [set], timeout: 1)

        let cleared = expectation(forNotification: WeeklySaveStore.didChange, object: nil) { note in
            note.userInfo?[WeeklySaveStore.kindKey] as? String == "media"
        }
        store.clear(kind: .media)
        wait(for: [cleared], timeout: 1)
        XCTAssertNil(store.display(for: .media))
    }

    /// Rewriting the identical display is not a change — the util card would
    /// otherwise run its replacement animation on every foreground refresh.
    func testWritingTheSameDisplayTwiceDoesNotPostAgain() {
        let store = makeStore()
        let value = display(daysOld: 0)
        store.setDisplay(value, for: .product)

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: WeeklySaveStore.didChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setDisplay(value, for: .product)
        store.clear(kind: .article)   // never had one
        XCTAssertEqual(posts, 0)
    }

    func testLiveDisplaysFollowTheRequestedKindOrder() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0, kind: .product), for: .product)
        store.setDisplay(display(daysOld: 0), for: .article)
        XCTAssertEqual(
            store.liveDisplays(for: [.article, .media, .product]).map(\.save.kind),
            [.article, .product])
    }

    func testSeenProposalIDsPersist() {
        let store = makeStore()
        XCTAssertTrue(store.seenProposalIDs().isEmpty)
        store.markProposalsSeen(["proposal-a", "proposal-b"])
        XCTAssertEqual(makeStore().seenProposalIDs(), ["proposal-a", "proposal-b"])
        // Marking the current set replaces it, so vanished proposals are forgotten.
        store.markProposalsSeen(["proposal-b"])
        XCTAssertEqual(makeStore().seenProposalIDs(), ["proposal-b"])
    }

    /// `displays` is keyed by `WeeklySaveKind` in memory, but the dictionary's
    /// synthesized `Codable` only special-cases `String`/`Int` keys as a JSON
    /// object — any other key type encodes as an alternating key/value array
    /// instead. `Payload`'s hand-written coding keeps the on-disk shape a
    /// plain string-keyed object rather than silently switching to that array
    /// form.
    func testDisplaysPersistAsAStringKeyedJSONObjectNotAnArray() throws {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0), for: .article)

        let data = try Data(contentsOf: container.appendingPathComponent("weeklySaves.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let displays = json?["displays"] as? [String: Any]
        XCTAssertNotNil(displays, "displays must decode as a JSON object, not an array of pairs")
        XCTAssertNotNil(displays?["article"])
    }

    /// A `weeklySaves.json` written before `hasResolvedMetadata` existed says
    /// nothing about whether its rows ever got their metadata — and the rows
    /// this flag was added for are exactly the ones already sitting in such a
    /// file. An absent flag therefore decodes as UNRESOLVED, which is what
    /// buys a stuck row one more try.
    func testADisplayWrittenBeforeTheFlagExistedDecodesAsUnresolved() throws {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0), for: .article)
        let fileURL = container.appendingPathComponent("weeklySaves.json")

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as! [String: Any]
        var displays = json["displays"] as! [String: Any]
        var article = displays["article"] as! [String: Any]
        XCTAssertNotNil(article.removeValue(forKey: "hasResolvedMetadata"))
        displays["article"] = article
        json["displays"] = displays
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let reopened = makeStore()
        XCTAssertEqual(reopened.display(for: .article)?.title, "A Title")
        XCTAssertEqual(reopened.display(for: .article)?.hasResolvedMetadata, false)
    }

    /// A key this build's `WeeklySaveKind` doesn't recognize (already-garbled
    /// JSON, or a kind a newer build wrote) must not take the rest of the
    /// payload down with it.
    func testAnUnrecognizedDisplayKeyIsDroppedRatherThanFailingTheWholeDecode() throws {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0), for: .article)
        let fileURL = container.appendingPathComponent("weeklySaves.json")

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as! [String: Any]
        var displays = json["displays"] as! [String: Any]
        displays["notARealKind"] = displays["article"]
        json["displays"] = displays
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

        let reopened = makeStore()
        XCTAssertEqual(reopened.display(for: .article)?.title, "A Title")
    }

    // MARK: WeeklySaveStoreTests helpers

    private func makeStore() -> WeeklySaveStore {
        WeeklySaveStore(containerURL: container, now: { self.clock })
    }

    private func display(
        daysOld: Int, kind: WeeklySaveKind = .article
    ) -> WeeklySaveDisplay {
        let key = Curve25519.Signing.PrivateKey()
        let save = try! WeeklySigning.sign(
            kind: kind, urlString: "https://example.com/a",
            date: clock.addingTimeInterval(-Double(daysOld) * 86_400),
            privateKey: key)
        return WeeklySaveDisplay(
            save: save, title: "A Title", subtitleHost: "example.com", imageData: nil)
    }

    // MARK: - WeeklySigningTests
    //
    // The curator's private key deliberately lives OUTSIDE this repository, so
    // these tests split in two: the shipped public key is pinned for shape, and
    // the sign→verify algebra is exercised against a pair each test mints.

    func testBundledPublicKeyDecodes() {
        XCTAssertNotNil(
            WeeklySigning.publicKey,
            "The compiled-in public key must parse — everything else verifies against it.")
        XCTAssertEqual(WeeklySigning.publicKey?.rawRepresentation.count, 32)
    }

    /// Nothing signed by a key that isn't the curator's may pass the shipped
    /// check — this is the whole security model of a world-writable public
    /// database.
    func testASaveSignedByAStrangerIsRejectedByTheBundledKey() throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: stranger)
        XCTAssertFalse(WeeklySigning.verify(save))
    }

    func testSignedSaveVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: key)
        XCTAssertTrue(WeeklySigning.verify(save, publicKey: key.publicKey))
    }

    func testTamperedURLFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: save.kind, urlString: "https://evil.example/a",
            date: save.date, signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testTamperedDateFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .media, urlString: "https://example.com/v", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: save.kind, urlString: save.urlString,
            date: save.date.addingTimeInterval(-86_400), signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testTamperedKindFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .product, urlString: "https://example.com/p", date: Date(),
            privateKey: key)
        let tampered = WeeklySave(
            kind: .article, urlString: save.urlString,
            date: save.date, signature: save.signature)
        XCTAssertFalse(WeeklySigning.verify(tampered, publicKey: key.publicKey))
    }

    func testPrivateKeyMatchRejectsAnythingButTheCuratorsKey() {
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(
            stranger.rawRepresentation.base64EncodedString()))
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey("not base64 at all"))
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(""))
        // A well-formed base64 blob of the wrong length isn't a key either.
        XCTAssertFalse(WeeklySigning.privateKeyMatchesBundledPublicKey(
            Data(repeating: 7, count: 8).base64EncodedString()))
    }

    /// The signed date is rounded to the canonical formatter's precision, so a
    /// value that round-trips through JSON (and CloudKit) still verifies.
    func testSignedDateSurvivesACodableRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let save = try WeeklySigning.sign(
            kind: .article, urlString: "https://example.com/a",
            date: Date(timeIntervalSince1970: 1_700_000_000.512_345),
            privateKey: key)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WeeklySave.self, from: encoder.encode(save))
        XCTAssertEqual(decoded, save)
        XCTAssertTrue(WeeklySigning.verify(decoded, publicKey: key.publicKey))
    }

    func testCanonicalMessageIsStableAndCarriesNoFractionalSeconds() {
        XCTAssertEqual(
            WeeklySave.canonicalMessageString(
                kind: .product, urlString: "https://shop.example/p",
                date: Date(timeIntervalSince1970: 1_700_000_000.75)),
            "product\nhttps://shop.example/p\n2023-11-14T22:13:20Z")
    }

    func testProposalRecordNameIsTheURLDedup() {
        let first = WeeklyProposal(
            kind: .article, urlString: "  https://example.com/x  ", date: Date())
        let second = WeeklyProposal(
            kind: .media, urlString: "https://example.com/x",
            date: Date().addingTimeInterval(500))
        XCTAssertEqual(first.recordName, second.recordName)
        XCTAssertEqual(first.urlString, "https://example.com/x")
        XCTAssertTrue(first.recordName.hasPrefix("proposal-"))
        XCTAssertEqual(first.recordName.count, "proposal-".count + 32)
        XCTAssertNotEqual(
            first.recordName,
            WeeklyProposal(
                kind: .article, urlString: "https://example.com/y", date: Date()).recordName)
    }

}

private extension UIView {
    func firstDescendant(identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.firstDescendant(identifier: identifier) }.first
    }
}
