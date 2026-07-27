//
//  RescueRequest.swift
//  LunaURLRescue
//

import Foundation
import LunaModels

/// Everything the rescue engine needs about one failed save. Built by the
/// integration layer (`URLRescueCoordinator` via the app-shell wiring) at the
/// moment a primary ingest pass has already failed.
public struct RescueRequest {
    /// Which primary path failed. Diagnostic context only — it becomes one
    /// sentence in the prompt telling the model which road is already known to be
    /// blocked. It does NOT constrain the answer (that's `hint`).
    public enum FailureKind: String {
        /// The article branch ended `.failed` (unreadable ordinary page).
        case articleFailed
        /// A product-looking page yielded no extractable price.
        case productNoPrice
        /// A downloadable-media link resolved to zero assets.
        case mediaNoAssets
    }

    /// The canonical URL the failed pass processed (`IngestResult.url`), NOT the
    /// raw pre-unwrap input.
    public let url: URL
    /// Where the original save came from — travels into the pipeline re-entry so
    /// presentation policy stays consistent with the first pass.
    public let source: CaptureSource
    public let failureKind: FailureKind
    /// What this save should be rescued into, or **nil to let the MODEL decide** —
    /// which is the default, and what every user-facing surface sends.
    ///
    /// This is `RescueHint` from LunaModels, not a mirror of it: the engine used to
    /// keep its own parallel `ContentHint` enum with an extra `.auto` case, so the
    /// same three-way split existed twice and every caller translated between them.
    /// Nil already meant "no hint", so `.auto` was a second spelling of nil.
    ///
    /// A concrete hint survives for the surfaces that genuinely know the kind from
    /// where the user pressed: the price editor's no-price retry and the media
    /// card's no-assets retry.
    public let hint: RescueHint?
    /// HTML the failed pass already fetched, when the caller still holds it.
    /// Nil ⇒ the engine best-effort refetches before building the digest.
    public let fetchedHTML: String?

    public init(
        url: URL,
        source: CaptureSource,
        failureKind: FailureKind,
        hint: RescueHint? = nil,
        fetchedHTML: String? = nil
    ) {
        self.url = url
        self.source = source
        self.failureKind = failureKind
        self.hint = hint
        self.fetchedHTML = fetchedHTML
    }

    /// Whether a plan carrying `kind`'s payload is legal here. No hint accepts all
    /// three (the model classified the page); a concrete hint accepts only its own,
    /// and the validator downgrades anything else to a reroute/JS salvage.
    public func allows(_ kind: RescueHint) -> Bool {
        hint == nil || hint == kind
    }

    /// The learned-rule store's key segment for this request's hint. Rules are
    /// keyed per (host, hint) so a model-classified rescue doesn't replay a rule
    /// learned under a pinned kind.
    public var hintKey: String { hint?.rawValue ?? "auto" }
}
