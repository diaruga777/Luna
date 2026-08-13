import LunaModels
@testable import LunaStorage
import XCTest

final class UtilCardStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UtilCardStorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSafariHistoryIsNewestFirstAndLimitedToTwenty() {
        defaults.set(
            (0..<24).map { "https://example.com/\($0)" },
            forKey: SafariRecentHistoryStore.historyKey)

        let history = SafariRecentHistoryStore(defaults: defaults).URLs

        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.first, "https://example.com/0")
        XCTAssertEqual(history.last, "https://example.com/19")
    }

    /// A repeat must not cost one of the twenty slots.
    func testSafariHistoryCollapsesRepeatsBeforeTheLimitApplies() {
        let repeated = "https://example.com/repeat"
        defaults.set(
            [repeated, repeated] + (0..<21).map { "https://example.com/\($0)" },
            forKey: SafariRecentHistoryStore.historyKey)

        let history = SafariRecentHistoryStore(defaults: defaults).URLs

        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.filter { $0 == repeated }.count, 1)
        XCTAssertEqual(history.last, "https://example.com/18")
    }

    /// The write side, which every Safari extension's native handler owns.
    func testRecordingAVisitPutsItFirstAndKeepsTwenty() {
        let store = SafariRecentHistoryStore(defaults: defaults)
        for index in 0..<24 { store.record("https://example.com/\(index)") }

        let history = store.URLs

        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.first, "https://example.com/23")
        XCTAssertEqual(history.last, "https://example.com/4")
    }

    /// A revisit is promoted rather than added, so it can never cost a slot.
    func testRecordingAVisitedPagePromotesItInsteadOfRepeatingIt() {
        let store = SafariRecentHistoryStore(defaults: defaults)
        store.record("https://example.com/first")
        store.record("https://example.com/second")
        store.record("https://example.com/first")

        XCTAssertEqual(
            store.URLs, ["https://example.com/first", "https://example.com/second"])
    }

    func testShortcutInstallAndIntentMarkersArePerApp() {
        let status = LunaSetupStatusStore(defaults: defaults)

        status.recordShortcutInstallPressed(for: .reader)
        XCTAssertNil(status.previouslyConfiguredShortcutApp(excluding: .downloader))
        status.recordShortcutRun(for: .reader)

        XCTAssertTrue(status.shortcutInstallWasPressed(for: .reader))
        XCTAssertFalse(status.shortcutInstallWasPressed(for: .downloader))
        XCTAssertTrue(status.shortcutHasRun(for: .reader))
        XCTAssertFalse(status.shortcutHasRun(for: .downloader))
        XCTAssertFalse(status.shortcutHasRun(for: .luna))
        XCTAssertEqual(
            status.previouslyConfiguredShortcutApp(excluding: .downloader),
            .reader)
        XCTAssertNil(status.previouslyConfiguredShortcutApp(excluding: .reader))
    }

    func testShortcutRunPostsSetupStatusChange() {
        let status = LunaSetupStatusStore(defaults: defaults)
        let expectation = expectation(
            forNotification: LunaSetupStatusStore.didChange, object: nil)

        status.recordShortcutRun(for: .downloader)

        wait(for: [expectation], timeout: 1)
    }

    func testCentralRunEvidenceAppliesToFutureFacetedApps() {
        let status = LunaSetupStatusStore(defaults: defaults)

        status.recordShortcutRun(for: .luna)
        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)

        XCTAssertTrue(status.shortcutRunApplies(to: .reader))
        XCTAssertTrue(status.safariRunApplies(to: .priceTracker))
        XCTAssertTrue(status.centralAppCoversAllOnboarding(for: .downloader))
        XCTAssertFalse(status.centralAppCoversAllOnboarding(for: .luna))
    }

    /// Reading the shared tracked URL is opportunistic: a faceted app's
    /// extension is evidence for central Luna too, which its per-app onboarding
    /// completion (`safariRunApplies`) deliberately refuses to accept.
    func testAnySafariExtensionRunCountsForEveryApp() {
        let status = LunaSetupStatusStore(defaults: defaults)
        XCTAssertFalse(status.anySafariExtensionHasRun)

        defaults.set(true, forKey: LunaSetupStatusStore.sharedSafariKey)
        XCTAssertTrue(status.anySafariExtensionHasRun)
        XCTAssertFalse(status.safariRunApplies(to: .luna))

        defaults.set(false, forKey: LunaSetupStatusStore.sharedSafariKey)
        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        XCTAssertTrue(status.anySafariExtensionHasRun)
    }

    func testShareActionMarkersAreIndependentAndPostAChange() {
        let status = LunaSetupStatusStore(defaults: defaults)
        let changed = expectation(
            forNotification: LunaSetupStatusStore.didChange, object: nil)

        status.recordShareActionRun(isCentral: false)

        wait(for: [changed], timeout: 1)
        XCTAssertTrue(status.shareActionHasRun(isCentral: false))
        XCTAssertFalse(status.shareActionHasRun(isCentral: true))
    }
}
