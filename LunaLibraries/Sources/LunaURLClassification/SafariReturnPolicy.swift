//
//  SafariReturnPolicy.swift
//  Luna
//

import Foundation

/// Whether a Safari pill save should bounce the user back to the page they
/// were on (`UIApplication.shared.open` on the original https URL), once the
/// save's own work (download start) has been kicked off.
///
/// Pure and standalone so `SceneDelegate`'s decision is unit-testable without
/// a live save: it takes the coarse three-way KIND split the bounce cares
/// about, whether the save actually landed, and whether the deep link asked
/// for it — see `claudedocs/safari-extension.md`.
public enum SafariReturnPolicy {
    /// The three save "shapes" the hand-off distinguishes. Coarser than
    /// `ContentKind`; only media returns because its Live Activity continues to
    /// show progress after the user goes back to Safari.
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

    /// Returns to Safari ONLY when the deep link carried the flag, the save was
    /// handled, AND the kind is media. Product and article both stay in Luna:
    /// their card is the hand-off's destination. The product guard is also
    /// defense in depth for old Safari-extension deep links that still carry a
    /// return flag.
    public static func shouldReturn(outcome: Outcome, kind: Kind, flagged: Bool) -> Bool {
        flagged && outcome == .handled && kind == .media
    }
}
