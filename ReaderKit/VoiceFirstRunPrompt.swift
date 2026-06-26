//
//  VoiceFirstRunPrompt.swift
//  ReaderKit
//

import UIKit

/// The one-time "choose a voice" nudge shown the FIRST time the user starts
/// read-aloud in the app. It never blocks playback — read-aloud proceeds with
/// the current (default `basic`) engine while the alert is up.
///
/// Navigation to the Voice settings screen lives in the main app, so the app
/// wires `openVoiceSettings` at launch. The reader (shared with the extensions)
/// only calls `showIfNeeded`; when the hook is unset (i.e. inside an extension,
/// which has no in-app Settings) the prompt is skipped entirely.
enum VoiceFirstRunPrompt {

    /// Set by the main app at launch: pushes/presents the Voice settings screen
    /// from `presenter`. Left `nil` in extensions, which disables the prompt.
    static var openVoiceSettings: ((_ presenter: UIViewController) -> Void)?

    /// Shows the prompt once, if it hasn't been shown and the app wired a
    /// settings hook. Safe to call on every read-aloud start.
    static func showIfNeeded(from presenter: UIViewController) {
        guard let openVoiceSettings, !VoiceModelStore.hasSeenVoicePrompt else { return }
        VoiceModelStore.hasSeenVoicePrompt = true

        let alert = UIAlertController(
            title: "Choose a Voice",
            message: "Reading aloud now with the standard voice. Open Settings to "
                + "download a higher-quality voice for read-aloud.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            openVoiceSettings(presenter)
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
