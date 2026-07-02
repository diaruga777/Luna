//
//  VoiceInstallLink.swift
//  Luna
//

import LunaReaderUI
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
        SystemSettingsLink.openFirstAvailable([
            "App-Prefs:root=ACCESSIBILITY",
            "App-Prefs:",
            UIApplication.openSettingsURLString,
        ])
    }
}
