import XCTest
@testable import LunaAppConfig

final class AppConfigTests: XCTestCase {
    // Under `swift test` there is no build-injected Info.plist, so the resolved values
    // fall back to the compiled-in defaults. Assert the shape/invariants of those.

    func testAppGroupHasGroupPrefix() {
        XCTAssertTrue(AppConfig.appGroupID.hasPrefix("group."),
                      "App Group id must start with 'group.' — got \(AppConfig.appGroupID)")
    }

    func testFallbackUsedWithoutInjectedPlist() {
        // Sanity: the test bundle has no LunaAppGroupID key, so we expect the default.
        XCTAssertEqual(AppConfig.appGroupID, AppConfig.defaultAppGroupID)
        XCTAssertFalse(AppConfig.resolvedFromInfoPlist)
    }
}
