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

    /// What the user (or the failing surface) expects this save to become.
    /// Mirrors `RescueHint` in `LunaModels` one tier down; the engine keeps its
    /// own copy so it stays constructible without the coordinator types.
    public enum ContentHint: String {
        case article
        case product
        case media

        /// The natural hint for a failure kind, when the user didn't pick one.
        public init(failureKind: FailureKind) {
            switch failureKind {
            case .articleFailed: self = .article
            case .productNoPrice: self = .product
            case .mediaNoAssets: self = .media
            }
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
        self.hint = hint ?? ContentHint(failureKind: failureKind)
        self.fetchedHTML = fetchedHTML
    }
}
