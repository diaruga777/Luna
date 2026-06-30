import XCTest
@testable import LuneAppConfig

final class AppConfigTests: XCTestCase {
    // Under `swift test` there is no build-injected Info.plist, so the resolved values
    // fall back to the compiled-in defaults. Assert the shape/invariants of those.

    func testAppGroupHasGroupPrefix() {
        XCTAssertTrue(AppConfig.appGroupID.hasPrefix("group."),
                      "App Group id must start with 'group.' — got \(AppConfig.appGroupID)")
    }

    func testICloudContainerHasICloudPrefix() {
        XCTAssertTrue(AppConfig.iCloudContainerID.hasPrefix("iCloud."),
                      "iCloud container id must start with 'iCloud.' — got \(AppConfig.iCloudContainerID)")
    }

    func testDefaultsAgreeOnNamespace() {
        // The App Group and iCloud container must share the same bundle namespace so all
        // surfaces co-locate; guards against the two xcconfig derivations drifting apart.
        let groupSuffix = AppConfig.defaultAppGroupID.replacingOccurrences(of: "group.", with: "")
        let iCloudSuffix = AppConfig.defaultICloudContainerID.replacingOccurrences(of: "iCloud.", with: "")
        XCTAssertEqual(groupSuffix, iCloudSuffix)
    }

    func testFallbackUsedWithoutInjectedPlist() {
        // Sanity: the test bundle has no LuneAppGroupID key, so we expect the default.
        XCTAssertEqual(AppConfig.appGroupID, AppConfig.defaultAppGroupID)
        XCTAssertFalse(AppConfig.resolvedFromInfoPlist)
    }
}
