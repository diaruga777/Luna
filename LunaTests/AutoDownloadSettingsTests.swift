//
//  AutoDownloadSettingsTests.swift
//  LunaTests
//

import LunaAppConfig
@testable import LunaMediaDownload
import XCTest

final class AutoDownloadSettingsTests: XCTestCase {
    private let photosKey = "autoSaveDownloadsToPhotos"
    private let clipboardKey = "autoCopyDownloadsToClipboard"
    private let wifiOnlyKey = "wifiOnlyDownloads"
    private let pendingWiFiKey = "pendingWiFiDownloads"
    private let retentionDisabledKey = "savedMediaRetention.disabled"
    private let retentionDaysKey = "savedMediaRetention.days"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    private func preservingSettings(_ body: () -> Void) {
        let previousPhotos = defaults.object(forKey: photosKey)
        let previousClipboard = defaults.object(forKey: clipboardKey)
        let previousRetentionDisabled = defaults.object(forKey: retentionDisabledKey)
        let previousRetentionDays = defaults.object(forKey: retentionDaysKey)
        defer {
            restore(previousPhotos, forKey: photosKey)
            restore(previousClipboard, forKey: clipboardKey)
            restore(previousRetentionDisabled, forKey: retentionDisabledKey)
            restore(previousRetentionDays, forKey: retentionDaysKey)
        }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testDownloadActionDefaults() {
        preservingSettings {
            defaults.removeObject(forKey: photosKey)
            defaults.removeObject(forKey: clipboardKey)

            XCTAssertTrue(AutoDownloadSettings.autoSaveDownloadsToPhotos)
            XCTAssertFalse(AutoDownloadSettings.autoCopyDownloadsToClipboard)
        }
    }

    func testDownloadActionSettingsRoundTrip() {
        preservingSettings {
            AutoDownloadSettings.autoSaveDownloadsToPhotos = false
            AutoDownloadSettings.autoCopyDownloadsToClipboard = true

            XCTAssertFalse(AutoDownloadSettings.autoSaveDownloadsToPhotos)
            XCTAssertTrue(AutoDownloadSettings.autoCopyDownloadsToClipboard)
        }
    }

    func testRetentionDefaultsToNever() {
        preservingSettings {
            defaults.removeObject(forKey: retentionDisabledKey)
            defaults.removeObject(forKey: retentionDaysKey)

            XCTAssertEqual(MediaRetentionSettings.option, .never)
            XCTAssertNil(MediaRetentionSettings.retentionDays)
        }
    }

    func testRetentionOptionsRoundTrip() {
        preservingSettings {
            for option in MediaRetentionOption.allCases {
                MediaRetentionSettings.option = option
                XCTAssertEqual(MediaRetentionSettings.option, option)
                XCTAssertEqual(MediaRetentionSettings.retentionDays, option.days)
            }
        }
    }

    func testWiFiOnlyDownloadsDefaultsOffAndRoundTrips() {
        let previous = defaults.object(forKey: wifiOnlyKey)
        defer { restore(previous, forKey: wifiOnlyKey) }

        defaults.removeObject(forKey: wifiOnlyKey)
        XCTAssertFalse(AutoDownloadSettings.wifiOnlyDownloads)

        AutoDownloadSettings.wifiOnlyDownloads = true
        XCTAssertTrue(AutoDownloadSettings.wifiOnlyDownloads)
    }

    func testPendingWiFiDownloadsMarkAndUnmark() {
        let previous = defaults.object(forKey: pendingWiFiKey)
        defer { restore(previous, forKey: pendingWiFiKey) }
        defaults.removeObject(forKey: pendingWiFiKey)

        let url = "https://www.tiktok.com/@luna/video/999"
        XCTAssertFalse(AutoDownloadSettings.pendingWiFiDownloadURLs().contains(url))

        AutoDownloadSettings.markPendingWiFiDownload(url)
        XCTAssertTrue(AutoDownloadSettings.pendingWiFiDownloadURLs().contains(url))
        // Marking twice doesn't duplicate the entry.
        AutoDownloadSettings.markPendingWiFiDownload(url)
        XCTAssertEqual(AutoDownloadSettings.pendingWiFiDownloadURLs().filter { $0 == url }.count, 1)

        AutoDownloadSettings.unmarkPendingWiFiDownload(url)
        XCTAssertFalse(AutoDownloadSettings.pendingWiFiDownloadURLs().contains(url))
    }

    func testDownloaderInstallationMarkerIsSharedAndStaleByDesign() {
        let key = LunaInstallationMarkers.downloaderKey
        let previous = defaults.object(forKey: key)
        defer { restore(previous, forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(LunaInstallationMarkers.downloaderWasInstalled)
        LunaInstallationMarkers.recordInstalled(surfaceIdentifier: "downloader")
        XCTAssertTrue(LunaInstallationMarkers.downloaderWasInstalled)
    }

    func testDownloaderIntentPreflightOnlyAcceptsDownloadableMedia() {
        XCTAssertTrue(MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: "https://www.tiktok.com/@luna/video/123",
            downloaderWasInstalled: true))
        XCTAssertFalse(MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: "https://example.com/article",
            downloaderWasInstalled: true))
        XCTAssertFalse(MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: "https://www.tiktok.com/@luna/video/123",
            downloaderWasInstalled: false))
    }
}
