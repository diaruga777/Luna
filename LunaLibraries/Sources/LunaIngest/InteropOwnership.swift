//
//  InteropOwnership.swift
//  ReaderKit
//

import LunaInterop

/// Which standalone Luna app a classified `Outcome` belongs to, for the
/// cross-app-interop purchase gate (`claudedocs/interop-purchase.md`).
///
/// Lives here (an extension on `Outcome`, in the module that already owns the
/// type) rather than as logic inside `LunaInterop` itself, so the low-tier
/// `LunaInterop` module never has to depend upward on `LunaIngest` (which pulls
/// in `LunaFetch`/`LunaHTMLClassification`/`LunaPaywallBypass`) just to know
/// about `Outcome`.
public extension Outcome {
    /// `nil` for `.failed` — a genuine failure belongs to nobody and is NEVER
    /// gated, identical to today.
    var interopOwner: InteropSurface? {
        switch self {
        case .article, .needsArchive, .document:
            return .reader
        case .social, .video:
            return .downloader
        case .product:
            return .priceTracker
        case .failed:
            return nil
        }
    }
}
