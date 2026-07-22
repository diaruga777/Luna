//
//  AppIntentSettingsTests.swift
//  LunaTests
//

@testable import LunaStorage
import XCTest

final class AppIntentSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppIntentSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        AppIntentSettings.testDefaultsOverride = defaults
    }

    override func tearDown() {
        AppIntentSettings.testDefaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testHandleOnScreenURLsDefaultsOn() {
        defaults.removeObject(forKey: AppIntentSettings.handleOnScreenURLsKey)
        XCTAssertTrue(AppIntentSettings.handleOnScreenURLs)
    }

    func testHandleOnScreenURLsRoundTrips() {
        AppIntentSettings.handleOnScreenURLs = false
        XCTAssertFalse(AppIntentSettings.handleOnScreenURLs)

        AppIntentSettings.handleOnScreenURLs = true
        XCTAssertTrue(AppIntentSettings.handleOnScreenURLs)
    }
}
