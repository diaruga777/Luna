//
//  BackupPolicy.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import os

/// Applies Luna's backup policy to files in the app and app-group containers.
///
/// Durable, user-controlled data stays eligible for iCloud and device backup.
/// Rebuildable caches, diagnostics, and transient downloads are excluded, so
/// backups do not grow with data Luna can recreate.
public enum BackupPolicy {
    private static let logger = Logger(subsystem: LunaLogging.subsystem, category: "backup")

    public static func includeInBackups(_ url: URL) {
        setExcludedFromBackup(false, for: url)
    }

    public static func excludeFromBackups(_ url: URL) {
        setExcludedFromBackup(true, for: url)
    }

    private static func setExcludedFromBackup(_ excluded: Bool, for url: URL) {
        var resourceURL = url
        guard FileManager.default.fileExists(atPath: resourceURL.path) else { return }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try resourceURL.setResourceValues(values)
        } catch {
            logger.debug("Failed to set backup exclusion=\(excluded) for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
