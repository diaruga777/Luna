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

    /// The saved item this rescue is for, when there is one. It is the
    /// key into the per-save diagnostic trace — read as failure EVIDENCE for the
    /// prompt, and written back with each rescue's own decisions. Nil for the
    /// ad-hoc callers that have no item (the price editor's resolver), which
    /// simply run without evidence.
    public let itemID: UUID?
    /// The recorded reason the save failed, straight off `SaveFailureStore`.
    /// Turns the prompt's one canned sentence into the actual fact — the HTTP
    /// status, the subscribe redirect — so the model isn't re-deriving it.
    public let failureReason: SaveFailureReason?
    /// The best title Luna recovered for the failed page (the failure sidecar's
    /// `resolvedTitle`, else the item's own). ONLY used to gate the search
    /// leg's cross-domain reroutes: a syndicated copy has to be recognizably the
    /// same article, and this is what "the same" is measured against.
    public let pageTitle: String?
    /// Whether this item has already been handed to the interactive
    /// archive-unlock tier. The deterministic `browserMayRecover` fast-path is
    /// once-only — a second handoff would just re-park a card the user already
    /// declined to unlock.
    public let browserHandoffTried: Bool

    public init(
        url: URL,
        source: CaptureSource,
        failureKind: FailureKind,
        hint: RescueHint? = nil,
        fetchedHTML: String? = nil,
        itemID: UUID? = nil,
        failureReason: SaveFailureReason? = nil,
        pageTitle: String? = nil,
        browserHandoffTried: Bool = false
    ) {
        self.url = url
        self.source = source
        self.failureKind = failureKind
        self.hint = hint
        self.fetchedHTML = fetchedHTML
        self.itemID = itemID
        self.failureReason = failureReason
        self.pageTitle = pageTitle
        self.browserHandoffTried = browserHandoffTried
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
