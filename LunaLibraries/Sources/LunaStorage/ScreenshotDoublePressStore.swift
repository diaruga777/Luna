//
//  ScreenshotDoublePressStore.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// One recorded Action Button screenshot save: its digest (see
/// `ScreenshotDigest` in `LunaIntents`), when it was saved, and the URL it
/// resolved to — so a near-immediate repeat run of the same screenshot can
/// skip the model and repeat that save instead (see `ScreenshotDoublePress`).
public struct ScreenshotDoublePressSnapshot: Equatable {
    public let digest: Data
    public let date: Date
    public let savedURLString: String

    public init(digest: Data, date: Date, savedURLString: String) {
        self.digest = digest
        self.date = date
        self.savedURLString = savedURLString
    }
}

/// App-Group-backed, single-slot store for the most recent Action Button
/// screenshot save — following `SafariContentStore`'s pattern in this
/// module (a plain static enum over the shared App Group). Only ever holds
/// one snapshot; a new `record` overwrites whatever was there. The digest is
/// ~1 KB, so storing it as `Data` in `UserDefaults` is fine.
public enum ScreenshotDoublePressStore {
    public static let appGroupID = AppConfig.appGroupID
    static let digestKey = "screenshotDoublePress.digest"
    static let dateKey = "screenshotDoublePress.date"
    static let urlKey = "screenshotDoublePress.savedURLString"

    /// Overridable so tests can inject an isolated App-Group suite instead of
    /// the real container — mirrors `SafariURLStore`'s test-only hook.
    /// Production code never sets this.
    static var testDefaultsOverride: UserDefaults?

    private static var resolvedDefaults: UserDefaults? {
        testDefaultsOverride ?? UserDefaults(suiteName: appGroupID)
    }

    /// The last recorded snapshot, or nil if none has ever been recorded (or
    /// the record is only partially present, which shouldn't happen outside
    /// of tests poking individual keys).
    public static func last() -> ScreenshotDoublePressSnapshot? {
        guard let defaults = resolvedDefaults,
              let digest = defaults.data(forKey: digestKey),
              let interval = defaults.object(forKey: dateKey) as? Double,
              let savedURLString = defaults.string(forKey: urlKey)
        else { return nil }
        return ScreenshotDoublePressSnapshot(
            digest: digest, date: Date(timeIntervalSince1970: interval), savedURLString: savedURLString)
    }

    /// Overwrites the single slot with a fresh snapshot.
    public static func record(digest: Data, savedURLString: String, now: Date = Date()) {
        guard let defaults = resolvedDefaults else { return }
        defaults.set(digest, forKey: digestKey)
        defaults.set(now.timeIntervalSince1970, forKey: dateKey)
        defaults.set(savedURLString, forKey: urlKey)
    }
}
