//
//  VoiceInstallLink.swift
//  Clip
//

import ClipReaderUI
import UIKit

/// Deep-links the user to iOS Settings to install enhanced Apple voices. There is
/// no public deep-link straight into Accessibility → Spoken Content → Voices, so
/// this tries the best available `App-Prefs` path and falls back to the app's own
/// Settings page. Shared by the Voice settings screen and the catch-up voice card
/// (both main-app surfaces).
enum VoiceInstallLink {

    /// Opens the first candidate Settings URL that the system can handle.
    static func open() {
        // Best effort: Accessibility root, then Settings root, then the app page.
        let candidates = [
            "App-Prefs:root=ACCESSIBILITY",
            "App-Prefs:",
            UIApplication.openSettingsURLString,
        ]
        openFirstAvailable(candidates, at: 0)
    }

    private static func openFirstAvailable(_ candidates: [String], at index: Int) {
        guard index < candidates.count, let url = URL(string: candidates[index]) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success { openFirstAvailable(candidates, at: index + 1) }
        }
    }
}
