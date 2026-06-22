//
//  BypassStrategySelector.swift
//  ReaderKit
//

import Foundation

/// The pure (no-I/O) policy that turns (article URL + the already-fetched direct
/// HTML) into the ordered list of `BypassStrategy` to try. This is the heavy
/// unit-test target: every ordering decision lives here, so it can be asserted
/// without touching the network.
enum BypassStrategySelector {

    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed). Pure — no I/O.
    ///
    /// Reasoning order:
    /// 1. The hard `BypassGate` blocks a bypass (product/platform/free page) → `[]`.
    /// 2. A detected paywall goes straight to archive.is. We deliberately do not
    ///    route users through third-party reader/proxy services.
    static func strategies(for url: URL, directHTML: String?) -> [BypassStrategy] {
        // The single gate decides whether ANY bypass may run. It blocks
        // product/platform pages and pages with no paywall evidence; `extracted` is
        // nil here because the resolver already returned early when the direct read
        // was readable, so the selector only sees non-readable pages.
        guard BypassGate.decision(for: url, html: directHTML, extracted: nil).allowsBypass else {
            return []
        }

        return [.archiveToday]
    }
}
