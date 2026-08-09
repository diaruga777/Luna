//
//  AutoDownloadSettingsTests.swift
//  LunaTests
//

import LunaAppConfig
import LunaModels
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
    private let explicitChoiceKey = "mediaStorage.userChose.v1"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    private func preservingSettings(_ body: () -> Void) {
        let previousPhotos = defaults.object(forKey: photosKey)
        let previousRetentionDisabled = defaults.object(forKey: retentionDisabledKey)
        let previousRetentionDays = defaults.object(forKey: retentionDaysKey)
        let previousAutoDownload = defaults.object(forKey: autoDownloadKey)
        let previousWiFiOnly = defaults.object(forKey: wifiOnlyKey)
        let previousExplicitChoice = defaults.object(forKey: explicitChoiceKey)
        defer {
            restore(previousExplicitChoice, forKey: explicitChoiceKey)
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

    /// `MediaStorageSettings.option` used to re-normalize a `.never` retention
    /// back to `defaultRetention` on both read and write, defending against
    /// "Photos off, no retention" — reachable only by poking the two backing
    /// prefs independently, which is exactly what `autoSaveDownloadsToPhotos`'s
    /// setter going module-internal (this D12 change) rules out: `option` is
    /// now the only path that can set either pref, and it always sets both
    /// together. `.deleteAfter(.never)` is still constructible and, since
    /// nothing needs to defend against a combination nothing can produce
    /// anymore, `option` now simply round-trips it rather than re-normalizing.
    func testStorageOptionRoundTripsNeverWithoutRenormalizing() {
        preservingSettings {
            MediaStorageSettings.option = .deleteAfter(.never)
            XCTAssertEqual(MediaStorageSettings.option, .deleteAfter(.never))
        }
    }

    // MARK: - The util card's inline "Store downloads …" choice

    /// The row waits on a choice the USER made. A fresh install's `.photos` is
    /// Luna's default, not an answer, which is the whole reason the row exists.
    func testTheStorageQuestionIsUnansweredUntilSomeoneAnswersIt() {
        preservingSettings {
            defaults.removeObject(forKey: explicitChoiceKey)
            XCTAssertFalse(MediaStorageSettings.hasExplicitChoice)

            // Written by Luna rather than chosen: still unanswered.
            MediaStorageSettings.option = .deleteAfter(.oneDay)
            XCTAssertFalse(MediaStorageSettings.hasExplicitChoice)

            MediaStorageSettings.choose(.photos)
            XCTAssertTrue(MediaStorageSettings.hasExplicitChoice)
            XCTAssertEqual(MediaStorageSettings.option, .photos)
        }
    }

    @MainActor
    func testChoosingInLunaTakesTheInlineAgeButNeverRetimesAnExistingOne() {
        preservingSettings {
            let choice = MediaUtilCardStorageChoice(
                saver: StubPhotoLibrary(granted: true), authorizationStatus: { .authorized })

            MediaStorageSettings.option = .photos
            choice.chooseInLuna()
            XCTAssertEqual(
                MediaStorageSettings.option,
                .deleteAfter(MediaStorageSettings.inlineRetention))

            // Already on a clock the user set elsewhere — the row is only moving
            // them off Photos, so it leaves the age alone.
            MediaStorageSettings.option = .deleteAfter(.oneDay)
            choice.chooseInLuna()
            XCTAssertEqual(MediaStorageSettings.option, .deleteAfter(.oneDay))
        }
    }

    @MainActor
    func testPhotosIsSavedOnlyOnceTheSystemHasGrantedIt() async {
        for granted in [true, false] {
            let saver = StubPhotoLibrary(granted: granted)
            let choice = MediaUtilCardStorageChoice(
                saver: saver, authorizationStatus: { .notDetermined })
            let previousPhotos = defaults.object(forKey: photosKey)
            let previousDisabled = defaults.object(forKey: retentionDisabledKey)
            let previousDays = defaults.object(forKey: retentionDaysKey)
            let previousChoice = defaults.object(forKey: explicitChoiceKey)
            defer {
                restore(previousPhotos, forKey: photosKey)
                restore(previousDisabled, forKey: retentionDisabledKey)
                restore(previousDays, forKey: retentionDaysKey)
                restore(previousChoice, forKey: explicitChoiceKey)
            }
            MediaStorageSettings.option = .photos
            defaults.removeObject(forKey: explicitChoiceKey)

            let outcome = await withCheckedContinuation { continuation in
                choice.choosePhotos { continuation.resume(returning: $0) }
            }

            XCTAssertTrue(saver.didRequestRead)
            if granted {
                XCTAssertEqual(outcome, .granted)
                XCTAssertEqual(MediaStorageSettings.option, .photos)
            } else {
                // A refusal reverts: an install left saying "Photos" would
                // silently keep writing local files instead.
                XCTAssertEqual(outcome, .refused)
                XCTAssertEqual(
                    MediaStorageSettings.option,
                    .deleteAfter(MediaStorageSettings.inlineRetention))
            }
            // A refusal is still an answer — the row does not come back.
            XCTAssertTrue(MediaStorageSettings.hasExplicitChoice)
        }
    }

    /// iOS shows its Photos prompt once. A second attempt cannot ask again, so
    /// it reports that the only way through is system Settings.
    @MainActor
    func testASecondAttemptAfterARefusalAsksNobodyAndReportsSettings() async {
        preservingSettings {
            defaults.removeObject(forKey: explicitChoiceKey)
        }
        let saver = StubPhotoLibrary(granted: true)
        let choice = MediaUtilCardStorageChoice(
            saver: saver, authorizationStatus: { .denied })
        let previousChoice = defaults.object(forKey: explicitChoiceKey)
        defer { restore(previousChoice, forKey: explicitChoiceKey) }

        let outcome = await withCheckedContinuation { continuation in
            choice.choosePhotos { continuation.resume(returning: $0) }
        }

        XCTAssertEqual(outcome, .refusedBefore)
        XCTAssertFalse(saver.didRequestRead)
        XCTAssertTrue(MediaStorageSettings.hasExplicitChoice)
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
        let previousAutoDownload = defaults.object(forKey: autoDownloadKey)
        defer {
            restore(previous, forKey: wifiOnlyKey)
            restore(previousAutoDownload, forKey: autoDownloadKey)
        }

        defaults.removeObject(forKey: wifiOnlyKey)
        XCTAssertFalse(AutoDownloadSettings.wifiOnlyDownloads)

        AutoDownloadSettings.policy = .wifiOnly
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

/// A photo library that answers however the test needs and records whether it
/// was asked at all — the point of the "already refused" case is that nothing
/// asks.
private final class StubPhotoLibrary: PhotoLibrarySaving, @unchecked Sendable {
    private let granted: Bool
    private(set) var didRequestRead = false

    init(granted: Bool) { self.granted = granted }

    func requestAddAuthorization() async -> Bool { granted }

    func requestReadAuthorization() async -> Bool {
        didRequestRead = true
        return granted
    }

    func save(fileURL: URL, kind: MediaAsset.Kind, shouldMoveFile: Bool) async throws -> String {
        throw MediaDownloadError.permissionDenied
    }
}
