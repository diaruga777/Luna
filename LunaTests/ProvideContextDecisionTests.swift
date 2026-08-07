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
        safariExtensionHasRun: Bool = true,
        handlesMediaKind: Bool = false,
        visionModelAvailable: Bool = false
    ) -> ProvideContextDecision.Result {
        ProvideContextDecision.decide(
            appName: appName, isSafari: isSafari, isShortcuts: isShortcuts, platform: platform,
            safariURLFresh: safariURLFresh, safariExtensionHasRun: safariExtensionHasRun,
            handlesMediaKind: handlesMediaKind,
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

    func testSafariStaleURLWithoutVisionIsAnError() {
        XCTAssertEqual(
            decide(appName: "Safari", isSafari: true, safariURLFresh: false, visionModelAvailable: false),
            .noSafariURL)
    }

    // MARK: - Safari before any extension has ever run

    /// Nothing has ever been in a position to capture the page, so Safari being
    /// frontmost is a situation this device isn't set up for — not a failure.
    func testSafariWithoutAnyExtensionRunIsUnsupported() {
        for visionAvailable in [false, true] {
            XCTAssertEqual(
                decide(
                    appName: "Safari", isSafari: true, safariURLFresh: false,
                    safariExtensionHasRun: false, visionModelAvailable: visionAvailable),
                .unsupported,
                "an unenabled extension should never error (vision=\(visionAvailable))")
        }
    }

    /// A URL captured before the running app existed is still this app's to
    /// save: freshness outranks the never-ran evidence, which is only about
    /// whether an ABSENT URL deserves an error.
    func testSafariFreshURLSavesEvenWithoutRecordedExtensionRun() {
        XCTAssertEqual(
            decide(
                appName: "Safari", isSafari: true, safariURLFresh: true,
                safariExtensionHasRun: false, visionModelAvailable: true),
            .saveImmediately)
    }

    /// The extension gate is Safari's alone — a platform app's screenshot route
    /// has nothing to do with whether Safari's extension was ever enabled.
    func testExtensionRunDoesNotAffectNonSafariApps() {
        XCTAssertEqual(
            decide(
                appName: "TikTok", platform: .tiktok, safariExtensionHasRun: false,
                handlesMediaKind: true, visionModelAvailable: true),
            .screenshotNeeded)
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
