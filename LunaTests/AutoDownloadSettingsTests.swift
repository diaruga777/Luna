//
//  AutoDownloadSettingsTests.swift
//  LunaTests
//

import LunaAppConfig
import LunaStorage
@testable import LunaMediaDownload
import XCTest

final class AutoDownloadSettingsTests: XCTestCase {
    private let photosKey = "autoSaveDownloadsToPhotos"
    private let wifiOnlyKey = "wifiOnlyDownloads"
    private let autoDownloadKey = "autoDownloadMediaInPreview"
    private let pendingWiFiKey = "pendingWiFiDownloads"
    private let retentionDisabledKey = "savedMediaRetention.disabled"
    private let retentionDaysKey = "savedMediaRetention.days"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    private func preservingSettings(_ body: () -> Void) {
        let previousPhotos = defaults.object(forKey: photosKey)
        let previousRetentionDisabled = defaults.object(forKey: retentionDisabledKey)
        let previousRetentionDays = defaults.object(forKey: retentionDaysKey)
        let previousAutoDownload = defaults.object(forKey: autoDownloadKey)
        let previousWiFiOnly = defaults.object(forKey: wifiOnlyKey)
        defer {
            restore(previousPhotos, forKey: photosKey)
            restore(previousRetentionDisabled, forKey: retentionDisabledKey)
            restore(previousRetentionDays, forKey: retentionDaysKey)
            restore(previousAutoDownload, forKey: autoDownloadKey)
            restore(previousWiFiOnly, forKey: wifiOnlyKey)
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

    // MARK: - "Download Automatically" (Never / Always / On Wi-Fi Only)

    func testAutoDownloadPolicyDefaultsToAlways() {
        preservingSettings {
            defaults.removeObject(forKey: autoDownloadKey)
            defaults.removeObject(forKey: wifiOnlyKey)

            XCTAssertEqual(AutoDownloadSettings.policy, .always)
        }
    }

    func testAutoDownloadPolicyRoundTripsThroughBothPrefs() {
        preservingSettings {
            AutoDownloadSettings.policy = .never
            XCTAssertEqual(AutoDownloadSettings.policy, .never)
            XCTAssertFalse(AutoDownloadSettings.autoDownloadMediaInPreview)
            XCTAssertFalse(AutoDownloadSettings.wifiOnlyDownloads)

            AutoDownloadSettings.policy = .wifiOnly
            XCTAssertEqual(AutoDownloadSettings.policy, .wifiOnly)
            XCTAssertTrue(AutoDownloadSettings.autoDownloadMediaInPreview)
            XCTAssertTrue(AutoDownloadSettings.wifiOnlyDownloads)

            AutoDownloadSettings.policy = .always
            XCTAssertEqual(AutoDownloadSettings.policy, .always)
            XCTAssertTrue(AutoDownloadSettings.autoDownloadMediaInPreview)
            XCTAssertFalse(AutoDownloadSettings.wifiOnlyDownloads)
        }
    }

    // MARK: - "Storage" (Photos vs. a deletion age — mutually exclusive)

    func testStorageDefaultsToPhotos() {
        preservingSettings {
            defaults.removeObject(forKey: photosKey)
            defaults.removeObject(forKey: retentionDisabledKey)
            defaults.removeObject(forKey: retentionDaysKey)

            XCTAssertEqual(MediaStorageSettings.option, .photos)
        }
    }

    func testStorageOptionsAreMutuallyExclusive() {
        preservingSettings {
            for retention in MediaRetentionOption.deletionOptions {
                MediaStorageSettings.option = .deleteAfter(retention)
                XCTAssertEqual(MediaStorageSettings.option, .deleteAfter(retention))
                XCTAssertFalse(AutoDownloadSettings.autoSaveDownloadsToPhotos)
                XCTAssertEqual(MediaRetentionSettings.retentionDays, retention.days)
            }

            MediaStorageSettings.option = .photos
            XCTAssertEqual(MediaStorageSettings.option, .photos)
            XCTAssertTrue(AutoDownloadSettings.autoSaveDownloadsToPhotos)
            XCTAssertNil(MediaRetentionSettings.retentionDays)
        }
    }

    /// The old settings allowed "Photos off, no retention"; the collapsed row has no
    /// such choice, so it reads as the default deletion age.
    func testStorageFallsBackToDefaultRetentionWhenNeitherWasChosen() {
        preservingSettings {
            AutoDownloadSettings.autoSaveDownloadsToPhotos = false
            MediaRetentionSettings.option = .never

            XCTAssertEqual(
                MediaStorageSettings.option,
                .deleteAfter(MediaStorageSettings.defaultRetention))
        }
    }

    func testStorageOptionsListOffersPhotosFirstThenEveryDeletionAge() {
        XCTAssertEqual(MediaStorageOption.allCases.first, .photos)
        XCTAssertEqual(
            MediaStorageOption.allCases.count, MediaRetentionOption.deletionOptions.count + 1)
        XCTAssertFalse(MediaRetentionOption.deletionOptions.contains(.never))
        XCTAssertEqual(
            MediaStorageOption.deleteAfter(.oneDay).displayName, "Delete after 1 day")
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
            handlesMedia: true))
        XCTAssertFalse(MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: "https://example.com/article",
            handlesMedia: true))
        XCTAssertFalse(MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: "https://www.tiktok.com/@luna/video/123",
            handlesMedia: false))
    }
}
