//
//  SystemSettingsLink.swift
//  Luna
//

import UIKit

/// Opens the system Settings as close to the relevant page as iOS allows.
///
/// There is NO public API to deep-link into Safari → Extensions or into the
/// Action Button page, and `UIApplication.openSettingsURLString` only opens the
/// app's OWN settings page (unhelpful here). As a best effort we try the
/// `App-Prefs:` scheme (Apps list, then root Settings) and fall back to the
/// app's settings page if those are blocked on the device.
enum SystemSettingsLink {

    static func open() {
        openFirstAvailable([
            "App-Prefs:root=APPS",          // Settings → Apps (iOS 18+)
            "App-Prefs:",                   // root Settings
            UIApplication.openSettingsURLString, // app's own page (always works)
        ])
    }

    /// Opens the first candidate Settings URL the system accepts, in order.
    /// Shared with `VoiceInstallLink`.
    static func openFirstAvailable(_ candidates: [String], at index: Int = 0) {
        guard index < candidates.count, let url = URL(string: candidates[index]) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { openFirstAvailable(candidates, at: index + 1) }
        }
    }
}
