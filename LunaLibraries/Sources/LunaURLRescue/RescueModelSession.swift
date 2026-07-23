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
    /// "article" | "product" | "reroute" | "webjs" | "media_url" | "give_up".
    public var kind: String
    public var rerouteURLString: String?
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
public enum RescueModelError: Error {
    case modelUnavailable
    case guardrailViolation
    case exceededContextWindowSize
    case rateLimited
    case networkFailure
    case quotaLimitReached
    case serviceUnavailable
    case other(Error)
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
    func prewarm()
    /// The plan call. `instructions` is the static task contract; `prompt` is the
    /// URL + hint + untrusted digest. Throws `RescueModelError`.
    func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse
    /// The PCC-only follow-up: reproduce the article body. Throws
    /// `RescueModelError` (including `.modelUnavailable` on the on-device stub).
    func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse
}

/// Stands in whenever no model can be constructed — a pre-iOS-26 device, Apple
/// Intelligence off, or (today) any build compiled with stable Xcode 26.2 whose
/// SDK lacks the API. Always unavailable, always throws — callers fold into the
/// same "rescue impossible" path.
public final class UnavailableRescueModelSession: RescueModelSession {
    public init() {}
    public var isAvailable: Bool { false }
    public var supportsArticlePayload: Bool { false }
    public func prewarm() {}
    public func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        throw RescueModelError.modelUnavailable
    }
    public func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse {
        throw RescueModelError.modelUnavailable
    }
}
