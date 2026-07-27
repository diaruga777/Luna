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
    /// Which primary path failed — decides which directive kinds are legal.
    public enum FailureKind: String {
        /// The article branch ended `.failed` (unreadable ordinary page).
        case articleFailed
        /// A product-looking page yielded no extractable price.
        case productNoPrice
        /// A downloadable-media link resolved to zero assets.
        case mediaNoAssets
    }

    /// What this save should be rescued into. Mirrors `RescueHint` in
    /// `LunaModels` one tier down; the engine keeps its own copy so it stays
    /// constructible without the coordinator types.
    ///
    /// `.auto` is the DEFAULT and what the failed-save card always sends: the
    /// model is shown every payload option and asked to decide the content type
    /// itself. The three concrete cases remain for the surfaces that genuinely
    /// know (the price screen's "Ask Apple Intelligence", the media card's
    /// no-assets retry) and would rather not have the answer relitigated.
    public enum ContentHint: String {
        case auto
        case article
        case product
        case media

        /// Whether a plan of this payload kind is legal. `.auto` accepts all
        /// three; a concrete hint accepts only its own (anything else is
        /// downgraded to a reroute/JS salvage by the validator).
        public func allows(_ other: ContentHint) -> Bool {
            self == .auto || self == other
        }
    }

    /// The canonical URL the failed pass processed (`IngestResult.url`), NOT the
    /// raw pre-unwrap input.
    public let url: URL
    /// Where the original save came from — travels into the pipeline re-entry so
    /// presentation policy stays consistent with the first pass.
    public let source: CaptureSource
    public let failureKind: FailureKind
    public let hint: ContentHint
    /// HTML the failed pass already fetched, when the caller still holds it.
    /// Nil ⇒ the engine best-effort refetches before building the digest.
    public let fetchedHTML: String?

    public init(
        url: URL,
        source: CaptureSource,
        failureKind: FailureKind,
        hint: ContentHint? = nil,
        fetchedHTML: String? = nil
    ) {
        self.url = url
        self.source = source
        self.failureKind = failureKind
        // No hint means no hint — the model classifies the page. The failure kind
        // still travels into the prompt as a FACT about what already went wrong,
        // which is context rather than an instruction to keep the same kind.
        self.hint = hint ?? .auto
        self.fetchedHTML = fetchedHTML
    }
}
