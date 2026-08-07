//
//  VoiceInstallLink.swift
//  Luna
//

import LunaReaderUI
import UIKit

/// Opens iOS Settings at its ROOT so the user can walk to Accessibility →
/// Read & Speak → Voices, which is where enhanced Apple voices are installed.
/// Used by the Voice settings screen, whose footer names that exact path.
///
/// Root Settings is the only destination offered, deliberately. There is no
/// public deep link to the Voices pane, and both of the fallbacks this used to
/// carry land somewhere that does NOT contain what the footer just told the
/// user to find: `root=ACCESSIBILITY`/`root=APPS` drop into a sub-screen they
/// then have to back out of, and `openSettingsURLString` opens Luna's own
/// page, which has no voices on it at all. If root Settings is blocked on a
/// device, nothing opening is better than the wrong pane opening.
enum VoiceInstallLink {

    /// Opens the root of iOS Settings.
    static func open() {
        SystemSettingsLink.openFirstAvailable(["App-Prefs:"])
    }
}
