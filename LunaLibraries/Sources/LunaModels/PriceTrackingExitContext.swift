//
//  PriceTrackingExitContext.swift
//  Luna
//

import Foundation

/// Where the price-tracker editor is being shown, which decides its top-left
/// navigation button.
///
/// - `inApp`: pushed onto the saves navigation stack. The user came from the
///   list and should be able to go **back** to it (a chevron that pops).
/// - `extension`: presented modally inside the action/share extension, which has no
///   navigation stack to pop to — the only way out is to **complete/dismiss** the
///   extension (a **Done** button).
///
/// This is an explicit host flag rather than something inferred from the view
/// hierarchy, so the correct button is chosen even when the in-app navigation
/// controller is itself presented modally (which would make a hierarchy guess wrong).
public enum PriceTrackingHost: Equatable {
    case inApp
    case `extension`
}

/// Why the editor was opened. Save-time entries (`creation`, `merge`) are what
/// distinguish a tracker the user is meeting for the first time from one they
/// came back to; `merge` additionally names the seller URL that was just added,
/// which the editor flashes at the top so the user can see what changed.
public enum PriceTrackingEntry: Equatable {
    /// A brand-new product saved as its OWN new tracker.
    case creation
    /// The just-saved URL was matched & added as a seller to an EXISTING tracker.
    /// `addedStoreURLString` is the exact URL that was just added.
    case merge(addedStoreURLString: String)
    /// Opened from within the app on an already-saved tracker — NOT a save-time flow.
    case existing
}

/// The kind of top-left navigation button the editor should show for a given host.
public enum PriceTrackingLeftButton: Equatable {
    /// A chevron that pops back to the saves list (in-app).
    case back
    /// A "Done" button that completes/dismisses the hosting extension.
    case done
}

/// Pure mapping from the editor's host + entry to its exit chrome, so the
/// decision can be unit-tested without building the view controller.
///
/// The host is what decides it: in-app the editor was pushed and goes BACK, in an
/// extension it is the whole sheet and the only way out is to complete the
/// request. The entry carries no chrome of its own — it used to decide a
/// top-right "Read instead" button, which is gone.
public struct PriceTrackingExitContext: Equatable {
    public let host: PriceTrackingHost
    public let entry: PriceTrackingEntry

    public init(host: PriceTrackingHost, entry: PriceTrackingEntry) {
        self.host = host
        self.entry = entry
    }

    /// The top-left button: a back chevron in-app, a Done button in an extension.
    public var leftButton: PriceTrackingLeftButton {
        switch host {
        case .inApp: return .back
        case .extension: return .done
        }
    }
}
