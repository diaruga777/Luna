//
//  SurfaceSupport.swift
//  ReaderKit
//

import LunaModels

public extension Outcome {
    /// Which standalone Luna app OWNS this classified outcome. `nil` for
    /// `.failed` — a genuine failure belongs to nobody and is never dropped.
    ///
    /// Lives here (an extension on `Outcome`, in the module that already owns
    /// the type) so low-tier modules never depend upward on `LunaIngest` just
    /// to know about `Outcome`.
    var owningApp: LunaApp? {
        switch self {
        case .article, .needsArchive, .document:
            return .reader
        case .social, .video:
            return .downloader
        case .product:
            return .priceTracker
        case let .unsupported(owner):
            return owner
        case .failed:
            return nil
        }
    }
}

/// The per-app content gate. Every Luna app runs the SAME classification
/// pipeline on any incoming URL, then keeps only the kinds it handles:
///
/// - the central **Luna** app processes every kind;
/// - a single-content app (Reader / Downloader / Price Tracker) processes its
///   own kind and DROPS the rest with a generic error (blocked means nothing
///   remains in the store).
///
/// Which kinds an app handles is fixed at build time by which per-kind
/// packages its target links; this type is the runtime mirror of that static
/// fact, keyed off `LunaApp.current`. There is no purchase and no per-source
/// exemption: email and friend-share ingestion drop foreign kinds too (the
/// owning app's own import picks the same message up when it's installed).
public enum SurfaceSupport {
    public enum Decision: Equatable, Sendable {
        /// The running app processes this outcome — save normally.
        case supported
        /// The outcome belongs to `owner`, which this app doesn't handle:
        /// save nothing and show the generic unsupported-kind error.
        case unsupported(owner: LunaApp)
    }

    /// Pure decision: `owner == nil` (failures) and the central Luna app are
    /// always supported; otherwise the outcome must belong to the running app.
    public static func evaluate(owner: LunaApp?, current: LunaApp) -> Decision {
        guard let owner, current != .luna, owner != current else { return .supported }
        return .unsupported(owner: owner)
    }

    public static func evaluateForCurrentProcess(owner: LunaApp?) -> Decision {
        evaluate(owner: owner, current: .current)
    }

    /// The generic drop explanation shown by every surface (alert body, intent
    /// dialog, extension error). When the sibling apps ship, the App Store
    /// upsell for `owner` slots in here — until then the link is unset and the
    /// copy stays informational.
    public static func unsupportedMessage(owner: LunaApp, current: LunaApp = .current) -> String {
        "\(current.displayName) can't save this type of link — it belongs in \(owner.displayName)."
    }
}
