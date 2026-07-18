//
//  ProvideContextDecision.swift
//  LunaIntents
//

import LunaModels
import LunaURLClassification
import Foundation

/// Collapses the optional URLs extracted from the current screen into one
/// trustworthy save candidate. Every nonempty input must be a substring of the
/// longest input, which covers duplicate, prefix, and partial OCR results without
/// guessing between divergent URLs.
public enum ProvideContextOnScreenURL {
    public static func collapse(_ values: [String]?, isSafari: Bool) -> String? {
        guard !isSafari, let values, !values.isEmpty else { return nil }
        let candidates = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard candidates.allSatisfy({ !$0.isEmpty }),
              let longest = candidates.max(by: { $0.count < $1.count }),
              candidates.allSatisfy(longest.contains)
        else { return nil }

        let decoded = longest.removingPercentEncoding ?? longest
        guard !hasTruncationSuffix(decoded),
              decoded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URLUnwrapper.ingestURL(from: longest),
              url.host?.isEmpty == false
        else { return nil }
        return url.absoluteString
    }

    private static func hasTruncationSuffix(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("...")
            || trimmed.hasSuffix("…")
            || trimmed.hasSuffix("⋯")
    }
}

/// Pure interpretation of the normal save pipeline's outcome for the optional
/// on-screen URL fast path. Nil means the caller must swallow the opportunistic
/// failure and resume the preexisting Provide Context decision.
public enum ProvideContextOnScreenSave {
    public struct Success: Equatable {
        public let urlString: String
        public let requiresForeground: Bool

        public init(urlString: String, requiresForeground: Bool) {
            self.urlString = urlString
            self.requiresForeground = requiresForeground
        }
    }

    public static func success(
        from outcome: IntentIngestHelper.ActionButtonSaveOutcome
    ) -> Success? {
        switch outcome {
        case let .completed(savedURL, _):
            guard let savedURL else { return nil }
            return Success(urlString: savedURL, requiresForeground: false)
        case .friendPromptRequested(let savedURL):
            return Success(urlString: savedURL, requiresForeground: true)
        case .blockedByInterop:
            return nil
        }
    }
}

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
