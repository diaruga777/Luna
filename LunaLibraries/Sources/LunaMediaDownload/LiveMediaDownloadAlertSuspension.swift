//
//  LiveMediaDownloadAlertSuspension.swift
//  LunaMediaDownload
//

import Foundation

extension LiveMediaDownloadManager {

    /// While suspended, a download's Live Activity still appears and still
    /// updates — but its `AlertConfiguration` (banner + sound + **haptic**) is
    /// dropped, so the transfer starting and finishing is silent.
    ///
    /// This exists for the bulk link import, where the alerts are per-substep
    /// noise rather than news: a file of two hundred social links starts and
    /// finishes two hundred transfers, and each one of those buzzed the device
    /// while the user was watching the import's own progress bar say the same
    /// thing. One alert is information; four hundred is a vibration storm.
    ///
    /// A COUNTER, not a flag, so nested/overlapping suspensions (two imports, or
    /// an import that outlives its sheet) can't have the inner one un-suspend the
    /// outer. Process-wide rather than a `@TaskLocal` like
    /// `systemProvidesProgressUI`: the finish alert fires from the background
    /// URLSession's delegate callback, in a task tree that has nothing to do with
    /// whoever started the download, so a task-scoped binding would silence the
    /// start and let every finish through.
    public static var areActivityAlertsSuspended: Bool {
        alertSuspensionLock.lock()
        defer { alertSuspensionLock.unlock() }
        return alertSuspensions > 0
    }

    /// Balanced with `resumeActivityAlerts()`. The caller owns the pairing (the
    /// import runner does it in a `defer`, so a cancelled or thrown run still
    /// restores the alerts).
    public static func suspendActivityAlerts() {
        alertSuspensionLock.lock()
        alertSuspensions += 1
        alertSuspensionLock.unlock()
    }

    public static func resumeActivityAlerts() {
        alertSuspensionLock.lock()
        alertSuspensions = max(0, alertSuspensions - 1)
        alertSuspensionLock.unlock()
    }

    private static let alertSuspensionLock = NSLock()
    nonisolated(unsafe) private static var alertSuspensions = 0
}
