//
//  SurfaceSupport.swift
//  ReaderKit
//

import LunaModels

public extension Outcome {
    /// Which standalone Luna app owns this classified outcome. Nil for
    /// `.failed`: a genuine failure belongs to nobody and is never dropped.
    ///
    /// This extension lives on `Outcome` itself, in the module that already
    /// owns the type, so low-tier modules never depend upward on `LunaIngest`
    /// just to know about `Outcome`.
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

/// The per-app content gate. Every Luna app runs the same classification
/// pipeline on any incoming URL, then keeps only the kinds it handles:
///
/// - the central **Luna** app processes every kind;
/// - a single-content app (Reader, Downloader, or Price Tracker) processes
///   its own kind and drops the rest with a generic error, so a blocked kind
///   leaves nothing in the store.
///
/// Which kinds an app handles is fixed at build time by which per-kind
/// packages its target links. This type is the runtime mirror of that static
/// fact, keyed off `LunaApp.current`. There is no purchase and no per-source
/// exemption: email and friend-share ingestion drop foreign kinds too (the
/// owning app's own import picks up the same message once it is installed).
public enum SurfaceSupport {
    public enum Decision: Equatable, Sendable {
        /// The running app processes this outcome. Save normally.
        case supported
        /// The outcome belongs to `owner`, which this app does not handle.
        /// Save nothing and show the generic unsupported-kind error.
        case unsupported(owner: LunaApp)
    }

    /// Pure decision: `owner == nil` (a failure) and the central Luna app are
    /// always supported; otherwise the outcome must belong to the running app.
    public static func evaluate(owner: LunaApp?, current: LunaApp) -> Decision {
        guard let owner, current != .luna, owner != current else { return .supported }
        return .unsupported(owner: owner)
    }

    public static func evaluateForCurrentProcess(owner: LunaApp?) -> Decision {
        evaluate(owner: owner, current: .current)
    }

    /// The drop explanation for surfaces that can speak only one string (the
    /// App Intents' thrown dialog). It says the same two things
    /// `UnsupportedSaveCardViewController` shows — the header naming this
    /// app, then the sibling app that does handle the link — flattened into
    /// a sentence, from the one copy source in LunaModels.
    public static func unsupportedMessage(owner: LunaApp, current: LunaApp = .current) -> String {
        UnsupportedSaveCopy.sentence(owner: owner, current: current)
    }
}
