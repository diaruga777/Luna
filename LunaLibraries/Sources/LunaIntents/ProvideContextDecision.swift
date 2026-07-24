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
/// guessing between divergent URLs. HTTP and HTTPS schemes are ignored for this
/// compatibility comparison because on-screen detection commonly returns both
/// forms for the same page.
public enum ProvideContextOnScreenURL {
    private static let embeddedWebURL = try? NSRegularExpression(
        pattern: #"(?i)https?://[^\s<>\"'\[\]{}]*?(?=(?:,\s*https?://)|[\s<>\"'\[\]{}]|$)"#)

    /// What the extracted on-screen values amount to.
    public enum Resolution: Equatable {
        /// Nothing usable — no values, or none that survive validation.
        case none
        /// One trustworthy save candidate.
        case single(String)
        /// Several DIFFERENT valid URLs that don't collapse into one page. The
        /// intent can't guess between them, and guessing wrong saves the wrong
        /// thing, so this is reported (not swallowed) when any candidate is one
        /// this app could have saved.
        case divergent([String])
    }

    /// Extract every embedded HTTP(S) URL from Shortcuts' scalar text
    /// representation before applying the ordinary collapse rules. The system
    /// may supply bare newline-delimited values, a comma-delimited list, or
    /// values wrapped in descriptive/JSON-like text.
    public static func collapseText(
        _ value: String?,
        isSafari: Bool,
        isEnabled: Bool = true
    ) -> String? {
        guard case let .single(urlString) = resolveText(
            value, isSafari: isSafari, isEnabled: isEnabled)
        else { return nil }
        return urlString
    }

    public static func collapse(_ values: [String]?, isSafari: Bool) -> String? {
        guard case let .single(urlString) = resolve(values, isSafari: isSafari) else {
            return nil
        }
        return urlString
    }

    /// `collapseText`, keeping the reason a collapse failed.
    public static func resolveText(
        _ value: String?,
        isSafari: Bool,
        isEnabled: Bool = true
    ) -> Resolution {
        guard isEnabled, !isSafari, let value, !value.isEmpty, let embeddedWebURL else {
            return .none
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let values: [String] = embeddedWebURL.matches(in: value, range: fullRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: value) else { return nil }
            return trimTransportPunctuation(String(value[range]))
        }
        return resolve(values, isSafari: isSafari)
    }

    /// `collapse`, keeping the reason a collapse failed: divergent values are
    /// reported as such (deduplicated, and only the ones that are valid URLs on
    /// their own) instead of collapsing into an indistinguishable `nil`.
    public static func resolve(_ values: [String]?, isSafari: Bool) -> Resolution {
        guard !isSafari, let values, !values.isEmpty else { return .none }
        let candidates = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let comparableCandidates = candidates.map {
            (original: $0, comparison: comparisonForm($0))
        }
        guard candidates.allSatisfy({ !$0.isEmpty }),
              let longest = comparableCandidates.max(by: {
                  if $0.comparison.count != $1.comparison.count {
                      return $0.comparison.count < $1.comparison.count
                  }
                  // Prefer the explicit HTTPS form when the scheme is the only
                  // difference; it is one character longer than HTTP.
                  return $0.original.count < $1.original.count
              })
        else { return .none }

        guard comparableCandidates.allSatisfy(
            { longest.comparison.contains($0.comparison) })
        else { return divergentResolution(from: candidates) }

        guard let urlString = validatedURLString(longest.original) else { return .none }
        return .single(urlString)
    }

    /// Distinct, individually valid URLs among values that refused to collapse.
    /// Fewer than two leaves nothing to disambiguate (the surviving one still
    /// isn't trustworthy on its own — the others contradict it), so that stays
    /// `.none` and the intent falls through in silence.
    private static func divergentResolution(from candidates: [String]) -> Resolution {
        var seen = Set<String>()
        let valid = candidates.compactMap(validatedURLString).filter { seen.insert($0).inserted }
        return valid.count > 1 ? .divergent(valid) : .none
    }

    /// The shared validity rules for ONE candidate: a real http(s) ingest URL
    /// with a host, no OCR truncation marker, no embedded whitespace.
    private static func validatedURLString(_ candidate: String) -> String? {
        let decoded = candidate.removingPercentEncoding ?? candidate
        guard !hasTruncationSuffix(decoded),
              decoded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URLUnwrapper.ingestURL(from: candidate),
              url.host?.isEmpty == false
        else { return nil }
        return url.absoluteString
    }

    /// What `ProvideContextIntent` should do with the supplied on-screen URLs.
    public enum Plan: Equatable {
        /// Nothing this app could have saved was on screen: continue with the
        /// ordinary onboarding/app/screenshot decision, silently.
        case skip
        /// Save this URL now, and REPORT any failure — pre-validation says this
        /// app handles the kind, so a failed save is a real error.
        case save(String)
        /// Several different saveable URLs are on screen; the intent throws
        /// rather than guessing which one the user meant.
        case divergent
    }

    /// Combines extraction (`resolveText`) with per-app pre-validation
    /// (`IntentURLPrecheck`) into the one decision the intent acts on. `verdict`
    /// is injectable so tests can pin the running app's handled kinds.
    public static func plan(
        text: String?,
        isSafari: Bool,
        isEnabled: Bool = true,
        verdict: (String) -> IntentURLPrecheck.Verdict = { IntentURLPrecheck.verdict(for: $0) }
    ) -> Plan {
        switch resolveText(text, isSafari: isSafari, isEnabled: isEnabled) {
        case .none:
            return .skip
        case let .single(urlString):
            guard case let .handleable(handleable) = verdict(urlString) else { return .skip }
            return .save(handleable)
        case let .divergent(urlStrings):
            // Only ambiguity we could otherwise have acted on is worth an error:
            // several links none of which is ours is the same non-event as none.
            let anyHandleable = urlStrings.contains {
                if case .handleable = verdict($0) { return true }
                return false
            }
            return anyHandleable ? .divergent : .skip
        }
    }

    private static func hasTruncationSuffix(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("...")
            || trimmed.hasSuffix("…")
            || trimmed.hasSuffix("⋯")
    }

    private static func comparisonForm(_ candidate: String) -> String {
        let lowercased = candidate.lowercased()
        if lowercased.hasPrefix("https://") {
            return String(candidate.dropFirst("https://".count))
        }
        if lowercased.hasPrefix("http://") {
            return String(candidate.dropFirst("http://".count))
        }
        return candidate
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
/// that ISN'T the onboarding-hijack step (which runs after supplied-URL handling
/// in the intent itself, via `ActionButtonOnboardingStore`'s state machine) and
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
/// | recognized platform             | !`handlesMediaKind`                                   | `.unsupported`     |
/// | recognized platform             | `handlesMediaKind`, !`visionModelAvailable`           | `.unsupported`     |
/// | recognized platform             | `handlesMediaKind`, `visionModelAvailable`            | `.screenshotNeeded`|
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
        handlesMediaKind: Bool,
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
            // whether THIS app handles the media kind (a recognized platform
            // save is media; Downloader and the central Luna app handle it).
            if !handlesMediaKind { return .unsupported }
            return visionModelAvailable ? .screenshotNeeded : .unsupported
        }

        return .unsupported
    }
}
