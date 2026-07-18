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
    private static let embeddedWebURL = try? NSRegularExpression(
        pattern: #"(?i)https?://[^\s<>\"'\[\]{}]*?(?=(?:,\s*https?://)|[\s<>\"'\[\]{}]|$)"#)

    /// Extract every embedded HTTP(S) URL from Shortcuts' scalar text
    /// representation before applying the ordinary collapse rules. The system
    /// may supply bare newline-delimited values, a comma-delimited list, or
    /// values wrapped in descriptive/JSON-like text.
    public static func collapseText(_ value: String?, isSafari: Bool) -> String? {
        guard !isSafari, let value, !value.isEmpty, let embeddedWebURL else { return nil }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let values: [String] = embeddedWebURL.matches(in: value, range: fullRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: value) else { return nil }
            return trimTransportPunctuation(String(value[range]))
        }
        return collapse(values, isSafari: isSafari)
    }

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

    private static func trimTransportPunctuation(_ candidate: String) -> String {
        var value = candidate
        while let last = value.last, ",;:!".contains(last) {
            value.removeLast()
        }
        if value.hasSuffix(".") && !value.hasSuffix("...") {
            value.removeLast()
        }
        while value.hasSuffix(")"),
              value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count {
            value.removeLast()
        }
        return value
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
