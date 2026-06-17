//
//  AppNamePlatformTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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
        XCTAssertTrue(AppNamePlatform.screenPrompt(forAppName: "YouTube")?.contains("channel_name:video_title") ?? false)
        XCTAssertTrue(AppNamePlatform.screenPrompt(forAppName: "Apple Music")?.contains("artist:title") ?? false)
        XCTAssertNotNil(AppNamePlatform.screenPrompt(forAppName: "Reddit"))
    }
}
