//
//  AppNamePlatformTests.swift
//  LunaTests
//

import LunaIntents
import XCTest
@testable import Luna

final class AppNamePlatformTests: XCTestCase {

    func testAppNameMapsToPlatform() {
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "YouTube"), .youtube)
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "Apple Music"), .music)
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "Spotify"), .music)
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "Apple Podcasts"), .podcast)
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "X"), .x)
        XCTAssertEqual(AppNamePlatform.platform(forAppName: "Bluesky"), .bluesky)
        XCTAssertNil(AppNamePlatform.platform(forAppName: "Safari"))
        XCTAssertNil(AppNamePlatform.platform(forAppName: "Notes"))
    }

    func testSafariAndUnknownHaveNoPrompt() {
        XCTAssertNil(AppNamePlatform.screenPrompt(forAppName: "Safari"))
        XCTAssertNil(AppNamePlatform.screenPrompt(forAppName: "Calculator"))
    }

    func testPlatformsHaveConcretePrompts() {
        XCTAssertTrue(AppNamePlatform.screenPrompt(forAppName: "YouTube")?.contains("channel ; title") ?? false)
        XCTAssertTrue(AppNamePlatform.screenPrompt(forAppName: "Apple Music")?.contains("artist ; title") ?? false)
        XCTAssertNotNil(AppNamePlatform.screenPrompt(forAppName: "Reddit"))
    }

    func testSupportedApps() {
        XCTAssertTrue(AppNamePlatform.isSupported(forAppName: "YouTube"))
        XCTAssertTrue(AppNamePlatform.isSupported(forAppName: "Reddit"))
        XCTAssertTrue(AppNamePlatform.isSupported(forAppName: "Safari"))
        XCTAssertFalse(AppNamePlatform.isSupported(forAppName: "Calculator"))
        XCTAssertFalse(AppNamePlatform.isSupported(forAppName: "Notes"))
    }

    func testSafariIsSupportedButPromptless() {
        XCTAssertTrue(AppNamePlatform.isSafari(forAppName: "Safari"))
        XCTAssertFalse(AppNamePlatform.isSafari(forAppName: "YouTube"))
        XCTAssertNil(AppNamePlatform.screenPrompt(forAppName: "Safari"))
    }

    // MARK: - Shortcuts (Action Button onboarding's own first run)

    func testShortcutsIsSupportedButPromptless() {
        XCTAssertTrue(AppNamePlatform.isShortcuts(forAppName: "Shortcuts"))
        XCTAssertTrue(AppNamePlatform.isSupported(forAppName: "Shortcuts"))
        XCTAssertNil(AppNamePlatform.screenPrompt(forAppName: "Shortcuts"))
        XCTAssertNil(AppNamePlatform.platform(forAppName: "Shortcuts"))
    }

    func testShortcutsMatchIsCaseInsensitive() {
        XCTAssertTrue(AppNamePlatform.isShortcuts(forAppName: "shortcuts"))
        XCTAssertTrue(AppNamePlatform.isShortcuts(forAppName: "SHORTCUTS"))
    }

    func testShortcutsDoesNotMatchOtherApps() {
        XCTAssertFalse(AppNamePlatform.isShortcuts(forAppName: "YouTube"))
        XCTAssertFalse(AppNamePlatform.isShortcuts(forAppName: "Safari"))
    }
}
