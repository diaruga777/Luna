//
//  RescueDirective.swift
//  LunaURLRescue
//

import Foundation
import LunaHTMLClassification
import LunaIngest
import LunaModels

/// The CLOSED set of request modifiers a rescue directive may carry. `Cookie`,
/// `Authorization`, and every other header are structurally impossible — there
/// is no dictionary, only these four vetted fields, so a prompt-injected model
/// response can never smuggle credentials or session state into a re-fetch.
public struct RescueHeaders: Equatable {
    /// Resolved from the model's UA *token* (never a free-form string) — see
    /// `RescueDirectiveValidator.userAgent(fromToken:)`.
    public var userAgent: String?
    public var referer: URL?
    public var acceptLanguage: String?
    public var xForwardedFor: String?

    public init(userAgent: String? = nil, referer: URL? = nil,
                acceptLanguage: String? = nil, xForwardedFor: String? = nil) {
        self.userAgent = userAgent
        self.referer = referer
        self.acceptLanguage = acceptLanguage
        self.xForwardedFor = xForwardedFor
    }

    public var isEmpty: Bool {
        userAgent == nil && referer == nil && acceptLanguage == nil && xForwardedFor == nil
    }
}

/// A validated "load this URL instead (with these request modifiers) and re-run
/// the pipeline once" directive.
public struct RescueReroute: Equatable {
    public let url: URL
    public let headers: RescueHeaders

    public init(url: URL, headers: RescueHeaders = RescueHeaders()) {
        self.url = url
        self.headers = headers
    }
}

/// A validated "load this page in an off-screen WKWebView and run this script"
/// directive. The script is size-capped, wrapped (never eval'd raw), executed in
/// a fresh non-persistent data store, and must return a string.
public struct RescueScript: Equatable {
    public enum ResultKind: String, Equatable {
        /// The script returns page HTML (e.g. a scoped container's outerHTML).
        case html
        /// The script returns a JSON string (embedded app state, JSON-LD, …).
        case json
        /// The script returns a direct media-file URL.
        case mediaURL = "media_url"
    }

    /// The page the WebView loads — the original URL or a validated reroute.
    public let pageURL: URL
    public let headers: RescueHeaders
    public let javascript: String
    public let resultKind: ResultKind

    public init(pageURL: URL, headers: RescueHeaders = RescueHeaders(),
                javascript: String, resultKind: ResultKind) {
        self.pageURL = pageURL
        self.headers = headers
        self.javascript = javascript
        self.resultKind = resultKind
    }
}

/// A model response that survived `RescueDirectiveValidator` — the only shape
/// `RescueDirectiveApplier` ever executes.
public enum RescueDirective: Equatable {
    /// PCC-only: the article's full text, reproduced from the digest.
    case articlePayload(ArticleContent)
    /// Product name/price/currency read verbatim from the digest.
    case productPayload(ProductInfo)
    case reroute(RescueReroute)
    case webJS(RescueScript)
    /// A direct media-file URL evidenced by the digest.
    case mediaURL(URL)
    /// Hand the page to the interactive archive-unlock tier: no automated fetch
    /// will pass this door, but a real browser session with the user's own
    /// cookies routinely does (`SaveFailureReason.browserMayRecover` documents
    /// the measurement). Terminal for the engine — nothing is fetched or
    /// re-ingested here; the integration layer moves the item to
    /// `.needsCaptcha`, which is a live card the user can act on rather than a
    /// dead one.
    case openInBrowser
    /// The model concluded nothing here can work.
    case giveUp
}

/// How a successful rescue was achieved — for diagnostics and the learned-rule
/// derivation.
public enum RescueMethod: String {
    case cachedRule
    case articlePayload
    case productPayload
    case reroute
    case webJS
    case mediaURL
    /// A reroute the model SELECTED from live search results rather than read
    /// off the digest. Tracked separately because it is the one method whose
    /// candidate URL came from outside the page.
    case search
    /// The interactive browser handoff.
    case browserHandoff
}

/// Every failure the engine can report, normalized — callers never see a
/// FoundationModels (or WebKit/URLSession) error type.
public enum URLRescueError: Error {
    case modelUnavailable
    /// A content-safety guardrail tripped — permanent for this URL; never retry.
    case guardrailViolation
    case exceededContextWindowSize
    case rateLimited
    case networkFailure
    case quotaLimitReached
    case serviceUnavailable
    case timedOut
    /// The model's plan failed validation beyond salvage.
    case invalidDirective(reason: String)
    /// The model never got to consider the page — its assets were unavailable,
    /// or another request held the session. Must not spend the item's attempt.
    case transientModel(token: String)
    case other(Error)
}

/// The result of one whole `URLRescueEngine.rescue` attempt. Never throws out of
/// the engine — every failure folds into one of these.
public enum RescueOutcome {
    /// The rescue produced a persistable article/product outcome. The
    /// `IngestResult` carries the canonical URL the content was obtained from.
    case rescued(IngestResult, method: RescueMethod)
    /// The rescue produced downloadable media assets (media hint only).
    case rescuedMedia([MediaAsset], method: RescueMethod)
    /// The rescue's verdict is "only a real browser gets in" — the integration
    /// layer moves the item to the interactive archive-unlock tier. Not
    /// `succeeded` (no content was obtained), but it ADVANCES the item out of
    /// `.failed`, so the coordinator treats it as a resolution rather than a
    /// spent attempt.
    case needsBrowser
    /// The model gave up, or every directive failed validation/application.
    case unrescuable
    /// No usable model right now (pre-iOS-26, Apple Intelligence off, stub build).
    case unavailable
    /// The Private Cloud Compute per-account quota is exhausted — worth
    /// surfacing "try again later" rather than "impossible".
    case quotaExhausted
    case failed(URLRescueError)

    /// True when the attempt ended with usable content.
    public var succeeded: Bool {
        switch self {
        case .rescued, .rescuedMedia: return true
        case .needsBrowser, .unrescuable, .unavailable, .quotaExhausted, .failed:
            return false
        }
    }

    /// Whether this outcome should spend the item's once-per-app-version manual
    /// attempt. False whenever the model never really got to answer — no model
    /// at all, a quota wall, a transient model error, or a browser handoff that
    /// moved the item somewhere it can still be acted on. The user's one visible
    /// attempt is for a real verdict on the page.
    public var spendsVersionAttempt: Bool {
        switch self {
        case .rescued, .rescuedMedia, .needsBrowser, .unavailable, .quotaExhausted:
            return false
        case .failed(let error):
            switch error {
            case .transientModel, .modelUnavailable, .rateLimited, .networkFailure,
                 .serviceUnavailable, .quotaLimitReached:
                return false
            case .guardrailViolation, .exceededContextWindowSize, .timedOut,
                 .invalidDirective, .other:
                return true
            }
        case .unrescuable:
            return true
        }
    }

    /// Whether the failure is PERMANENT for this URL, so no automatic sweep and
    /// no manual tap should ever try it again. A content-safety guardrail (or a
    /// flat refusal) is a verdict on the prompt, and the prompt is derived from
    /// the page — the same page will trip it every time.
    public var isPermanentlyBlocked: Bool {
        guard case .failed(.guardrailViolation) = self else { return false }
        return true
    }
}
