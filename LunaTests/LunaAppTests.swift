//
//  LunaAppTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest
@testable import LunaModels

final class LunaAppTests: XCTestCase {

    // MARK: - detect(bundleIdentifier:)

    func testAppBundleIdentifierParsing() {
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna"), .luna)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.reader"), .reader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.downloader"), .downloader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.pricetracker"), .priceTracker)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.vault"), .vault)
    }

    func testExtensionBundleIdentifierParsing() {
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.share"), .luna)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.reader.share"), .reader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.reader.action2"), .reader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.reader.safari"), .reader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.downloader.share"), .downloader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.downloader.action2"), .downloader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.downloader.safari"), .downloader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.pricetracker.share"), .priceTracker)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.pricetracker.action2"), .priceTracker)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.pricetracker.safari"), .priceTracker)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.luna.vault.share"), .vault)
    }

    func testNilOrEmptyIdentifierDefaultsToLuna() {
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: nil), .luna)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: ""), .luna)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.somethingelse"), .luna)
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "com.hsanabria.Luna.Reader"), .reader)
        XCTAssertEqual(LunaApp.detect(bundleIdentifier: "COM.HSANABRIA.LUNA.DOWNLOADER"), .downloader)
    }

    // MARK: - installedMarkerKey

    func testInstalledMarkerKeys() {
        XCTAssertEqual(LunaApp.luna.installedMarkerKey, "lunaInstalled.luna")
        XCTAssertEqual(LunaApp.reader.installedMarkerKey, "lunaInstalled.reader")
        XCTAssertEqual(LunaApp.downloader.installedMarkerKey, "lunaInstalled.downloader")
        XCTAssertEqual(LunaApp.priceTracker.installedMarkerKey, "lunaInstalled.pricetracker")
        XCTAssertEqual(LunaApp.vault.installedMarkerKey, "lunaInstalled.vault")
    }

    // MARK: - displayName

    func testDisplayNames() {
        XCTAssertEqual(LunaApp.luna.displayName, "Luna")
        XCTAssertEqual(LunaApp.reader.displayName, "Luna Reader")
        XCTAssertEqual(LunaApp.downloader.displayName, "Luna Video")
        XCTAssertEqual(LunaApp.priceTracker.displayName, "Luna Price Tracker")
        XCTAssertEqual(LunaApp.vault.displayName, "Luna Vault")
    }

    // MARK: - deepLinkScheme

    func testDeepLinkSchemes() {
        XCTAssertEqual(LunaApp.luna.deepLinkScheme, "luna")
        XCTAssertEqual(LunaApp.reader.deepLinkScheme, "lunareader")
        XCTAssertEqual(LunaApp.downloader.deepLinkScheme, "lunadownloader")
        XCTAssertEqual(LunaApp.priceTracker.deepLinkScheme, "lunapricetracker")
        XCTAssertEqual(LunaApp.vault.deepLinkScheme, "lunavault")
    }

    func testLegacySiblingSystemsDoNotSelectVaultBeforeCentralIntegration() {
        XCTAssertEqual(
            LunaApp.onboardingRankedSiblings,
            [.reader, .downloader, .priceTracker])
        XCTAssertEqual(
            LunaApp.legacyContentApps,
            [.luna, .reader, .downloader, .priceTracker])
        XCTAssertFalse(LunaApp.onboardingRankedSiblings.contains(.vault))
    }

    // MARK: - current

    func testCurrentIsLunaInTheUnitTestHost() {
        // The unit-test host is the central Luna app (`com.hsanabria.luna`, plus
        // `.tests` for the test bundle) — `.detect` on either resolves to `.luna`.
        XCTAssertEqual(LunaApp.current, .luna)
    }
}
