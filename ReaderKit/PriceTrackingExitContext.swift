//
//  PriceTrackingExitContext.swift
//  Clip
//

import Foundation

/// Where the price-tracker editor is being shown, which decides its top-left
/// navigation button.
///
/// - `inApp`: pushed onto the reading-list navigation stack. The user came from the
///   list and should be able to go **back** to it (a chevron that pops).
/// - `extension`: presented modally inside the action/share extension, which has no
///   navigation stack to pop to — the only way out is to **complete/dismiss** the
///   extension (a **Done** button).
///
/// This is an explicit host flag rather than something inferred from the view
/// hierarchy, so the correct button is chosen even when the in-app navigation
/// controller is itself presented modally (which would make a hierarchy guess wrong).
enum PriceTrackingHost: Equatable {
    case inApp
    case `extension`
}

/// Why the editor was opened, which (with the host) decides whether the top-right
/// "Read instead" button appears.
///
/// "Read instead" is a SAVE-TIME affordance: a brand-new product was just classified
/// as a tracker, and the user can override that decision and read it as a normal
/// article instead. It must NEVER appear when the user merely returns to an
/// already-saved tracker from within the app.
enum PriceTrackingEntry: Equatable {
    /// A brand-new product saved as its OWN new tracker. "Read instead" discards the
    /// whole new tracker and saves the URL as a normal article.
    case creation
    /// The just-saved URL was matched & added as a seller to an EXISTING tracker.
    /// "Read instead" reverts ONLY that newly-added seller URL (leaving the existing
    /// tracker otherwise intact) and saves that URL as a normal article.
    /// `addedStoreURLString` is the exact URL that was just added, so it can be
    /// reverted precisely.
    case merge(addedStoreURLString: String)
    /// Opened from within the app on an already-saved tracker — NOT a save-time flow.
    /// No "Read instead" button; the top-left back button is the only chrome.
    case existing
}

/// The kind of top-left navigation button the editor should show for a given host.
enum PriceTrackingLeftButton: Equatable {
    /// A chevron that pops back to the reading list (in-app).
    case back
    /// A "Done" button that completes/dismisses the hosting extension.
    case done
}

/// What the top-right "Read instead" button should do (or that it should be absent).
enum PriceTrackingReadInsteadAction: Equatable {
    /// No "Read instead" button (the `existing` entry — just viewing a saved tracker).
    case hidden
    /// Discard the whole new tracker and save its URL as a normal article.
    case discardTracker
    /// Remove exactly `urlString` from the existing tracker (leaving the rest intact)
    /// and save that one URL as a normal article.
    case revertAddedStore(urlString: String)
}

/// Pure mapping from the editor's host + entry to its navigation chrome, so the
/// decisions can be unit-tested without building the view controller.
///
/// The host decides the LEFT button (back in-app vs Done in an extension). The
/// entry decides the RIGHT "Read instead" button — present only at save time
/// (creation/merge), absent when returning to an existing tracker.
struct PriceTrackingExitContext: Equatable {
    let host: PriceTrackingHost
    let entry: PriceTrackingEntry

    init(host: PriceTrackingHost, entry: PriceTrackingEntry) {
        self.host = host
        self.entry = entry
    }

    /// The top-left button: a back chevron in-app, a Done button in an extension.
    var leftButton: PriceTrackingLeftButton {
        switch host {
        case .inApp: return .back
        case .extension: return .done
        }
    }

    /// The top-right "Read instead" behaviour for this entry. Hidden when simply
    /// viewing an existing tracker; otherwise discards (creation) or reverts just the
    /// newly-added seller (merge).
    var readInsteadAction: PriceTrackingReadInsteadAction {
        switch entry {
        case .creation: return .discardTracker
        case .merge(let urlString): return .revertAddedStore(urlString: urlString)
        case .existing: return .hidden
        }
    }
}
