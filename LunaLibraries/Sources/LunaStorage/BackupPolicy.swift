//
//  BackupPolicy.swift
//  LunaStorage
//

import Foundation
import os

/// Applies Luna's backup policy to files in the app/group containers.
///
/// Durable, user-controlled data should remain eligible for iCloud/device backup.
/// Rebuildable caches, diagnostics, and transient downloads should be explicitly
/// excluded so backups stay useful without growing from data Luna can recreate.
public enum BackupPolicy {
    private static let logger = Logger(subsystem: "luna", category: "backup")

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
