//
//  VoiceFirstRunPrompt.swift
//  ReaderKit
//

import UIKit
import LunaModels

/// Opens the app's Voice settings screen. The only conformer lives in the app
/// shell (the reader is shared with the extensions, which have no Settings), and
/// is installed on `VoiceFirstRunPrompt.voiceSettings` at launch.
@MainActor
public protocol VoiceSettingsPresenting {
    func presentVoiceSettings(from presenter: UIViewController)
}

/// The one-time "better voices available" nudge shown the FIRST time the user
/// starts read-aloud in the app. It never blocks playback — read-aloud proceeds
/// with the standard system voice while the alert is up.
///
/// Navigation to the Voice settings screen lives in the main app, so the app
/// installs `voiceSettings` at launch. The reader (shared with the extensions)
/// only calls `showIfNeeded`; when the seam is unset (i.e. inside an extension,
/// which has no in-app Settings) the prompt is skipped entirely.
public enum VoiceFirstRunPrompt {

    /// Set by the main app at launch. Left `nil` in extensions, which disables
    /// the prompt.
    public static var voiceSettings: VoiceSettingsPresenting?

    /// Shows the prompt once, if it hasn't been shown, the app wired a settings
    /// seam, and the user actually IS on the standard voice — someone already
    /// reading with an installed enhanced voice must not be told otherwise.
    /// Safe to call on every read-aloud start.
    public static func showIfNeeded(from presenter: UIViewController) {
        guard let voiceSettings, !VoiceModelStore.hasSeenVoicePrompt,
              !VoiceModelStore.isAppleEnhancedInstalled else { return }
        VoiceModelStore.hasSeenVoicePrompt = true

        let alert = UIAlertController(
            title: L10n.string("Reader_audio_voicePromptTitle"),
            message: L10n.string("Reader_audio_voicePromptMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_openSettings"), style: .default) { _ in
            voiceSettings.presentVoiceSettings(from: presenter)
        })
        alert.addAction(UIAlertAction(title: L10n.string("Common_notNow"), style: .cancel))
        presenter.present(alert, animated: true)
    }
}
