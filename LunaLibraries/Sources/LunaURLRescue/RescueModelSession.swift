//
//  RescueModelSession.swift
//  LunaURLRescue
//

import Foundation

/// The model's raw plan, as plain data — the protocol below carries NO
/// FoundationModels (or iOS-26-only) types, mirroring how
/// `AudioTrimModelSession` returns `[Int]` and `ScreenCaptureModelSession`
/// returns `String`. Every field is UNTRUSTED until it passes
/// `RescueDirectiveValidator`.
public struct RescuePlanResponse: Equatable {
    /// "article" | "product" | "reroute" | "webjs" | "media_url" | "search" |
    /// "inspect_url" | "open_in_browser" | "give_up".
    public var kind: String
    /// For reroute/webjs, and for the URL an `inspect_url` plan wants digested.
    public var rerouteURLString: String?
    /// For "search": the query the engine runs. The model never supplies the
    /// resulting URL — it picks one from the live results in a second round.
    public var searchQuery: String?
    /// A closed-vocabulary browser-identity token — see
    /// `RescueDirectiveValidator.userAgent(fromToken:)`. Never a free-form UA.
    public var userAgentToken: String?
    public var refererString: String?
    public var acceptLanguage: String?
    public var xForwardedFor: String?
    public var javascript: String?
    /// "html" | "json" | "media_url".
    public var scriptResultKind: String?
    public var mediaURLString: String?
    public var productName: String?
    /// Decimal string; validated verbatim against the digest.
    public var productPriceAmount: String?
    public var productCurrency: String?
    public var productImageURLString: String?
    public var productBrand: String?

    public init(
        kind: String,
        rerouteURLString: String? = nil,
        searchQuery: String? = nil,
        userAgentToken: String? = nil,
        refererString: String? = nil,
        acceptLanguage: String? = nil,
        xForwardedFor: String? = nil,
        javascript: String? = nil,
        scriptResultKind: String? = nil,
        mediaURLString: String? = nil,
        productName: String? = nil,
        productPriceAmount: String? = nil,
        productCurrency: String? = nil,
        productImageURLString: String? = nil,
        productBrand: String? = nil
    ) {
        self.kind = kind
        self.rerouteURLString = rerouteURLString
        self.searchQuery = searchQuery
        self.userAgentToken = userAgentToken
        self.refererString = refererString
        self.acceptLanguage = acceptLanguage
        self.xForwardedFor = xForwardedFor
        self.javascript = javascript
        self.scriptResultKind = scriptResultKind
        self.mediaURLString = mediaURLString
        self.productName = productName
        self.productPriceAmount = productPriceAmount
        self.productCurrency = productCurrency
        self.productImageURLString = productImageURLString
        self.productBrand = productBrand
    }
}

/// The model's raw article reproduction (PCC-only second call), as plain data.
public struct RescueArticleResponse: Equatable {
    public struct BlockDTO: Equatable {
        /// "paragraph" | "heading" | "quote" | "listItem".
        public var kind: String
        public var text: String
        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }
    public var title: String
    public var author: String?
    public var blocks: [BlockDTO]

    public init(title: String, author: String? = nil, blocks: [BlockDTO]) {
        self.title = title
        self.author = author
        self.blocks = blocks
    }
}

/// Every FoundationModels failure the engine cares about, normalized so nothing
/// above the seam names a framework type. Mirrors `AudioTrimModelError` +
/// `ScreenCaptureModelError`.
///
/// Every case here gets its OWN log line and its own engine verdict. They used
/// to collapse: `OnDeviceRescueSession.normalize` mapped three cases and folded
/// everything else into `.other`, so a model that refused, or was busy, or whose
/// assets were still downloading, all read as one anonymous failure — and the
/// item spent its per-version attempt on a call the model never really answered.
public enum RescueModelError: Error {
    case modelUnavailable
    case guardrailViolation
    case exceededContextWindowSize
    case rateLimited
    case networkFailure
    case quotaLimitReached
    case serviceUnavailable
    /// The model's assets are absent or still downloading. TRANSIENT — the model
    /// never saw the page, so this must not spend the item's attempt.
    case assetsUnavailable
    /// Another request holds the session. TRANSIENT, same reasoning.
    case concurrentRequests
    /// The model declined to answer this prompt. Like a guardrail violation,
    /// permanent for this URL — the prompt is derived from the page.
    case refusal
    /// The response didn't parse into the schema.
    case decodingFailure
    /// The schema or the locale isn't supported by this model build. Permanent
    /// until Luna itself changes, and never worth a retry for this item.
    case unsupportedSchemaOrLocale
    case other(Error)

    /// Whether the model genuinely never got to consider the page. These do not
    /// spend the once-per-version attempt.
    public var isTransient: Bool {
        switch self {
        case .assetsUnavailable, .concurrentRequests, .rateLimited,
             .networkFailure, .serviceUnavailable:
            return true
        case .modelUnavailable, .guardrailViolation, .exceededContextWindowSize,
             .quotaLimitReached, .refusal, .decodingFailure,
             .unsupportedSchemaOrLocale, .other:
            return false
        }
    }

    /// A stable token for the diagnostic line — never the underlying error's
    /// description, which can quote prompt text.
    public var logToken: String {
        switch self {
        case .modelUnavailable: return "modelUnavailable"
        case .guardrailViolation: return "guardrailViolation"
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .rateLimited: return "rateLimited"
        case .networkFailure: return "networkFailure"
        case .quotaLimitReached: return "quotaLimitReached"
        case .serviceUnavailable: return "serviceUnavailable"
        case .assetsUnavailable: return "assetsUnavailable"
        case .concurrentRequests: return "concurrentRequests"
        case .refusal: return "refusal"
        case .decodingFailure: return "decodingFailure"
        case .unsupportedSchemaOrLocale: return "unsupportedSchemaOrLocale"
        case .other: return "other"
        }
    }
}

/// The seam every FoundationModels type in this module hides behind, so the
/// engine's digest/validation/apply logic is unit-testable with a fake — the
/// real model is never available in a CI simulator, and the PCC conformer is
/// iOS-27-only and absent from the stable-Xcode SDK entirely (see
/// `RescueModelSessionFactory`).
public protocol RescueModelSession: AnyObject {
    /// Mirrors "an on-device or Private Cloud Compute model is usable now."
    var isAvailable: Bool { get }
    /// True only when the Private Cloud Compute model will serve this call — the
    /// full-article payload is impossible in the 4096-token on-device window, so
    /// the validator rejects `kind == "article"` unless this is true.
    var supportsArticlePayload: Bool { get }
    /// Discards any model session left over from the previous attempt.
    ///
    /// The engine is a process-lifetime singleton (`URLRescueWiring.install()`),
    /// so without this the SAME underlying session — and its ever-growing
    /// transcript — is reused by every rescue the app ever runs, including one
    /// whose response a timeout already cancelled. Called once per attempt, so
    /// the plan call and its article follow-up still share a session.
    func beginAttempt()
    /// Warms the model for the attempt. Takes `instructions` because the session
    /// is created here: warming without them would create an instruction-less
    /// session that the plan call then silently reuses, dropping its contract.
    func prewarm(instructions: String)
    /// The plan call. `instructions` is the static task contract; `prompt` is the
    /// URL + hint + untrusted digest. Throws `RescueModelError`.
    func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse
    /// The PCC-only follow-up: reproduce the article body. Throws
    /// `RescueModelError` (including `.modelUnavailable` on the on-device stub).
    func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse
}

public extension RescueModelSession {
    /// Model-less conformers (the stub, test fakes) hold nothing to discard.
    func beginAttempt() {}
}

/// Stands in whenever no model can be constructed — a pre-iOS-26 device, Apple
/// Intelligence off, or (today) any build compiled with stable Xcode 26.2 whose
/// SDK lacks the API. Always unavailable, always throws — callers fold into the
/// same "rescue impossible" path.
public final class UnavailableRescueModelSession: RescueModelSession {
    public init() {}
    public var isAvailable: Bool { false }
    public var supportsArticlePayload: Bool { false }
    public func prewarm(instructions: String) {}
    public func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        throw RescueModelError.modelUnavailable
    }
    public func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse {
        throw RescueModelError.modelUnavailable
    }
}
