//
//  InteropSurfaceTests.swift
//  LunaTests
//

import XCTest
@testable import LunaInterop

final class InteropSurfaceTests: XCTestCase {

    func testBundleIdentifierParsing() {
        XCTAssertEqual(InteropSurface.surface(forBundleIdentifier: "com.acme.luna.reader"), .reader)
        XCTAssertEqual(InteropSurface.surface(forBundleIdentifier: "com.acme.luna.downloader"), .downloader)
        XCTAssertEqual(InteropSurface.surface(forBundleIdentifier: "com.acme.luna.pricetracker"), .priceTracker)
    }

    func testExtensionBundleIdentifierParsing() {
        XCTAssertEqual(
            InteropSurface.surface(forBundleIdentifier: "com.acme.luna.downloader.share"), .downloader)
        XCTAssertEqual(
            InteropSurface.surface(forBundleIdentifier: "com.acme.luna.downloader.action"), .downloader)
        XCTAssertEqual(
            InteropSurface.surface(forBundleIdentifier: "com.acme.luna.pricetracker.safari"), .priceTracker)
        XCTAssertEqual(
            InteropSurface.surface(forBundleIdentifier: "com.acme.luna.reader.share"), .reader)
    }

    func testUnknownOrEmptyIdentifierDefaultsToReader() {
        XCTAssertEqual(InteropSurface.surface(forBundleIdentifier: ""), .reader)
        XCTAssertEqual(InteropSurface.surface(forBundleIdentifier: "com.acme.somethingelse"), .reader)
    }

    func testStorageIdentifiersMatchInstalledAppMarkersConvention() {
        XCTAssertEqual(InteropSurface.reader.storageIdentifier, "reader")
        XCTAssertEqual(InteropSurface.downloader.storageIdentifier, "downloader")
        XCTAssertEqual(InteropSurface.priceTracker.storageIdentifier, "pricetracker")
    }

    func testInstalledMarkerKeys() {
        XCTAssertEqual(InteropSurface.reader.installedMarkerKey, "lunaInstalled.reader")
        XCTAssertEqual(InteropSurface.downloader.installedMarkerKey, "lunaInstalled.downloader")
        XCTAssertEqual(InteropSurface.priceTracker.installedMarkerKey, "lunaInstalled.pricetracker")
    }

    func testDeepLinkSchemes() {
        XCTAssertEqual(InteropSurface.reader.deepLinkScheme, "lunareader")
        XCTAssertEqual(InteropSurface.downloader.deepLinkScheme, "lunadownloader")
        XCTAssertEqual(InteropSurface.priceTracker.deepLinkScheme, "lunapricetracker")
    }

    func testDisplayNames() {
        XCTAssertEqual(InteropSurface.reader.displayName, "Luna Reader")
        XCTAssertEqual(InteropSurface.downloader.displayName, "Luna Downloader")
        XCTAssertEqual(InteropSurface.priceTracker.displayName, "Luna Price Tracker")
    }

    func testInstallationMarkerReadsInjectedDefaults() {
        let suiteName = "InteropSurfaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(InteropInstallationMarkers.isInstalled(.downloader, defaults: defaults))
        defaults.set(true, forKey: InteropSurface.downloader.installedMarkerKey)
        XCTAssertTrue(InteropInstallationMarkers.isInstalled(.downloader, defaults: defaults))
        // A different surface's marker is independent.
        XCTAssertFalse(InteropInstallationMarkers.isInstalled(.reader, defaults: defaults))
    }
}
