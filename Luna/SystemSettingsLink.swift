//
//  SystemSettingsLink.swift
//  Luna
//

import UIKit

/// Opens the system Settings as close to the relevant page as iOS allows.
///
/// There is NO public API to deep-link into Safari → Extensions or into the
/// Action Button page, and `UIApplication.openSettingsURLString` only opens the
/// app's OWN settings page (unhelpful here). As a best effort, this tries the
/// `App-Prefs:` scheme (Apps list, then root Settings) and falls back to the
/// app's settings page if those are blocked on the device.
enum SystemSettingsLink {

    static func open() {
        openFirstAvailable([
            "App-Prefs:root=APPS",          // Settings → Apps (iOS 18+)
            "App-Prefs:",                   // root Settings
            UIApplication.openSettingsURLString, // app's own page (always works)
        ])
    }

    /// Best-effort deep link into Settings → Action Button (no public API for this
    /// either), falling back through the same root-Settings cascade as `open()`.
    static func openActionButton(completion: ((Bool) -> Void)? = nil) {
        openFirstAvailable([
            "App-Prefs:",                   // root Settings
            UIApplication.openSettingsURLString, // app's own page (always works)
        ], completion: completion)
    }

    /// Opens the first candidate Settings URL the system accepts, in order.
    /// Shared with `VoiceInstallLink`.
    static func openFirstAvailable(
        _ candidates: [String],
        at index: Int = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard index < candidates.count else {
            completion?(false)
            return
        }
        guard let url = URL(string: candidates[index]) else {
            openFirstAvailable(
                candidates,
                at: index + 1,
                completion: completion)
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                completion?(true)
            } else {
                openFirstAvailable(
                    candidates,
                    at: index + 1,
                    completion: completion)
            }
        }
    }
}
