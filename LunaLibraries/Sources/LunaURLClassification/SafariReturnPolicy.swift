//
//  SafariReturnPolicy.swift
//  Luna
//

import Foundation

/// Whether a Safari pill save should bounce the user back to the page they
/// were on (`UIApplication.shared.open` on the original https URL), once the
/// save's own work (download start / price refresh) has been kicked off.
///
/// Pure and standalone so `SceneDelegate`'s decision is unit-testable without
/// a live save: it takes the coarse three-way KIND split the bounce cares
/// about, whether the save actually landed, and whether the deep link asked
/// for it — see `claudedocs/safari-extension.md`.
public enum SafariReturnPolicy {
    /// The three save "shapes" the bounce distinguishes. Coarser than
    /// `ContentKind` — only "did this start a media/product job" matters here.
    public enum Kind: Equatable {
        case article
        case media
        case product
    }

    /// Whether the save press actually did something: persisted, merged into
    /// an existing save (the dedupe path), or deferred (e.g. until Wi-Fi) all
    /// count. A failed or unsupported save does not — the user needs to stay
    /// and see why.
    public enum Outcome: Equatable {
        case handled
        case failedOrUnsupported
    }

    /// Returns to Safari ONLY when the deep link carried the flag, the save
    /// was handled, AND the kind is media or product. Article is refused even
    /// if a flag somehow arrives on one — defense in depth: `content.js`'s
    /// `readTarget` never sets it, but the reader IS the destination, so this
    /// policy must independently refuse to bounce away from it.
    public static func shouldReturn(outcome: Outcome, kind: Kind, flagged: Bool) -> Bool {
        guard flagged, outcome == .handled, kind != .article else { return false }
        return true
    }
}
