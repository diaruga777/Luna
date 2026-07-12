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

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    private func preservingSettings(_ body: () -> Void) {
        let previousPhotos = defaults.object(forKey: photosKey)
        let previousClipboard = defaults.object(forKey: clipboardKey)
        defer {
            restore(previousPhotos, forKey: photosKey)
            restore(previousClipboard, forKey: clipboardKey)
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
}
