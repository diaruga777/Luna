//
//  CapturedPage.swift
//  LunaModels
//

import Foundation

/// The page HTML a surface arrives with, if any, and what it is worth.
///
/// `.unlockedCapture` is the Safari "Read in Luna" hand-off — the on-screen
/// article DOM captured AFTER the extension unlocked it, so the page's stale
/// schema.org lock must not re-reject it. Its payload's init is private to this
/// file, which makes `safariHandoff(html:)` the one producer.
public enum CapturedPage: Equatable {
    public struct UnlockedCapture: Equatable {
        public let html: String

        fileprivate init(html: String) { self.html = html }
    }

    case none
    /// HTML the surface fetched itself. Keeps the full paywall gate.
    case fetched(String)
    case unlockedCapture(UnlockedCapture)

    /// The one way to declare a capture trusted past the paywall signal.
    public static func safariHandoff(html: String) -> CapturedPage {
        .unlockedCapture(UnlockedCapture(html: html))
    }

    /// The HTML this page carries, however it was obtained.
    public var html: String? {
        switch self {
        case .none: return nil
        case .fetched(let html): return html
        case .unlockedCapture(let capture): return capture.html
        }
    }

    public var isUnlockedCapture: Bool {
        if case .unlockedCapture = self { return true }
        return false
    }
}
