//
//  ProvideContextDecisionTests.swift
//  LunaTests
//

import LunaIntents
import LunaModels
import XCTest

final class ProvideContextDecisionTests: XCTestCase {

    private func decide(
        appName: String?,
        isSafari: Bool = false,
        isShortcuts: Bool = false,
        platform: ContentPlatform? = nil,
        safariURLFresh: Bool = false,
        handlesMediaKind: Bool = false,
        visionModelAvailable: Bool = false
    ) -> ProvideContextDecision.Result {
        ProvideContextDecision.decide(
            appName: appName, isSafari: isSafari, isShortcuts: isShortcuts, platform: platform,
            safariURLFresh: safariURLFresh, handlesMediaKind: handlesMediaKind,
            visionModelAvailable: visionModelAvailable)
    }

    // MARK: - Lock screen / empty app name

    func testNilAppNameIsUnsupported() {
        XCTAssertEqual(decide(appName: nil), .unsupported)
    }

    func testEmptyAppNameIsUnsupported() {
        XCTAssertEqual(decide(appName: ""), .unsupported)
    }

    func testWhitespaceOnlyAppNameIsUnsupported() {
        XCTAssertEqual(decide(appName: "   \n\t"), .unsupported)
    }

    // MARK: - Safari

    func testSafariFreshURLSavesImmediately() {
        XCTAssertEqual(
            decide(appName: "Safari", isSafari: true, safariURLFresh: true, visionModelAvailable: false),
            .saveImmediately)
    }

    func testSafariFreshURLSavesImmediatelyEvenWithVisionAvailable() {
        XCTAssertEqual(
            decide(appName: "Safari", isSafari: true, safariURLFresh: true, visionModelAvailable: true),
            .saveImmediately)
    }

    func testSafariStaleURLWithVisionNeedsScreenshot() {
        XCTAssertEqual(
            decide(appName: "Safari", isSafari: true, safariURLFresh: false, visionModelAvailable: true),
            .screenshotNeeded)
    }

    func testSafariStaleURLWithoutVisionIsUnsupported() {
        XCTAssertEqual(
            decide(appName: "Safari", isSafari: true, safariURLFresh: false, visionModelAvailable: false),
            .unsupported)
    }

    // MARK: - Shortcuts

    func testShortcutsOutsideOnboardingIsUnsupported() {
        XCTAssertEqual(decide(appName: "Shortcuts", isShortcuts: true), .unsupported)
    }

    func testShortcutsOutsideOnboardingIsUnsupportedEvenWithVision() {
        XCTAssertEqual(
            decide(appName: "Shortcuts", isShortcuts: true, visionModelAvailable: true),
            .unsupported)
    }

    // MARK: - Recognized platform apps

    func testPlatformAppNotInstalledIsUnsupported() {
        XCTAssertEqual(
            decide(appName: "TikTok", platform: .tiktok, handlesMediaKind: false, visionModelAvailable: true),
            .unsupported)
    }

    func testPlatformAppInstalledWithoutVisionIsUnsupported() {
        XCTAssertEqual(
            decide(appName: "TikTok", platform: .tiktok, handlesMediaKind: true, visionModelAvailable: false),
            .unsupported)
    }

    func testPlatformAppInstalledWithVisionNeedsScreenshot() {
        XCTAssertEqual(
            decide(appName: "TikTok", platform: .tiktok, handlesMediaKind: true, visionModelAvailable: true),
            .screenshotNeeded)
    }

    func testEveryRecognizedPlatformTakesTheSameRoute() {
        for platform in ContentPlatform.allCases {
            XCTAssertEqual(
                decide(appName: "SomeApp", platform: platform, handlesMediaKind: true, visionModelAvailable: true),
                .screenshotNeeded, "platform \(platform) should need a screenshot when installed + vision available")
            XCTAssertEqual(
                decide(appName: "SomeApp", platform: platform, handlesMediaKind: false, visionModelAvailable: true),
                .unsupported, "platform \(platform) should be unsupported when its owning surface isn't installed")
        }
    }

    // MARK: - Unrecognized app

    func testUnrecognizedAppIsUnsupported() {
        XCTAssertEqual(
            decide(appName: "SomeRandomApp", handlesMediaKind: true, visionModelAvailable: true),
            .unsupported)
    }
}
