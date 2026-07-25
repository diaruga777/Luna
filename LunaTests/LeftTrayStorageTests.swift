import LunaStorage
import XCTest

final class LeftTrayStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LeftTrayStorageTests.\(UUID().uuidString)"
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

    func testFacetedAndCentralSetupMarkersAreIndependent() {
        let status = LunaSetupStatusStore(defaults: defaults)

        status.recordShortcutRun(isCentral: false)

        XCTAssertTrue(status.shortcutHasRun(isCentral: false))
        XCTAssertFalse(status.shortcutHasRun(isCentral: true))
    }
}
