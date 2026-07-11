//
//  ProvideContextDecision.swift
//  LunaIntents
//

import LunaModels
import Foundation

/// The pure decision core of the "Provide Context" App Intent — everything
/// that ISN'T the onboarding-hijack step (which happens first, in the intent
/// itself, via `ActionButtonOnboardingStore`'s existing state machine) and
/// isn't a side effect (saving the fresh Safari URL, foregrounding). Given
/// only the facts below, decides what the Shortcut should do next.
///
/// Decision table (evaluated top to bottom — the first matching row wins):
///
/// | `appName`                     | conditions                                          | result             |
/// |--------------------------------|------------------------------------------------------|--------------------|
/// | nil / empty (trimmed)          | — (lock screen)                                      | `.unsupported`     |
/// | Safari                          | `safariURLFresh`                                      | `.saveImmediately` |
/// | Safari                          | !`safariURLFresh`, `visionModelAvailable`             | `.screenshotNeeded`|
/// | Safari                          | !`safariURLFresh`, !`visionModelAvailable`            | `.unsupported`     |
/// | Shortcuts (outside onboarding)  | — (no meaningful screenshot of Shortcuts' own UI)     | `.unsupported`     |
/// | recognized platform             | !`owningSurfaceInstalled`                             | `.unsupported`     |
/// | recognized platform             | `owningSurfaceInstalled`, !`visionModelAvailable`     | `.unsupported`     |
/// | recognized platform             | `owningSurfaceInstalled`, `visionModelAvailable`      | `.screenshotNeeded`|
/// | unrecognized app                | —                                                      | `.unsupported`     |
public enum ProvideContextDecision {
    public enum Result: Equatable {
        /// Nothing to do — the Shortcut exits with no further steps.
        case unsupported
        /// Safari with a fresh tracked URL: the intent saves it itself, right
        /// now, through the action-button save path (double-save preserved).
        /// No screenshot is taken.
        case saveImmediately
        /// The Shortcut should take a screenshot and hand it to Save.
        case screenshotNeeded
    }

    public static func decide(
        appName: String?,
        isSafari: Bool,
        isShortcuts: Bool,
        platform: ContentPlatform?,
        safariURLFresh: Bool,
        owningSurfaceInstalled: Bool,
        visionModelAvailable: Bool
    ) -> Result {
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported
        }

        if isSafari {
            if safariURLFresh { return .saveImmediately }
            return visionModelAvailable ? .screenshotNeeded : .unsupported
        }

        if isShortcuts {
            // Onboarding's "Shortcuts" run is intercepted before this function
            // is ever reached; a plain Shortcuts call here has no meaningful
            // screenshot of its own to capture.
            return .unsupported
        }

        if platform != nil {
            // Platform identity isn't itself branched on below — only
            // whether its owning surface (all recognized platforms route to
            // Downloader today) is installed.
            if !owningSurfaceInstalled { return .unsupported }
            return visionModelAvailable ? .screenshotNeeded : .unsupported
        }

        return .unsupported
    }
}
