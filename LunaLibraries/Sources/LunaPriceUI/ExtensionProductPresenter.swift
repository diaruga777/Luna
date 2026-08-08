//
//  ExtensionProductPresenter.swift
//  LunaPriceUI
//

import LunaHTMLClassification
import LunaModels
import LunaStorage
import UIKit

/// The product-kind side of the extension surfaces: persist the tracker for a
/// classified product page, then present the SAME price-tracking editor the
/// main app shows (the extension host wraps it in Done chrome). Protocol-free —
/// each extension target's composition root (`ShareEntry+*` / `ActionEntry+*`)
/// wraps it in a small adapter conforming to `ShareProductPresenting`
/// (LunaShareSurface), the same shape as the `IngestKindProcessors` /
/// `IngestorKindHandlers` wiring. Host side effects arrive as closures so this
/// module never sees the surface's `ExtensionHost`.
@MainActor
public final class ExtensionProductPresenter {

    public init() {}

    /// Persists the tracker first so the editor has an item (falling back to a
    /// plain save confirmation when the row is gone). "Read instead" re-appends
    /// the URL to the shared store (extension-safe: the main app ingests it on
    /// next launch); the editor handles the tracker delete.
    ///
    /// The editor opens IMMEDIATELY, on the one seller the user was actually
    /// looking at. The alternative-seller fan-out is started at the same moment
    /// and runs behind it: its "checking for other sellers" row is already in
    /// the list, and each retailer it verifies appears there as it lands.
    ///
    /// It used to hold a full-screen wait between the save and the editor — up
    /// to half a minute of other people's web servers, in a share sheet, for a
    /// tap the user had already made. What survives a share extension's early
    /// death is not the Task but the PENDING MARKER on the tracker: the app
    /// finishes the run at its next launch or its next refresh cycle.
    public func presentPriceEditor(
        product: ProductInfo, url: URL, store: ReadingListStore,
        presentModally: @escaping (UIViewController) -> Void,
        complete: @escaping () -> Void
    ) {
        guard let itemID = store.savePriceTracker(
            product.makeTracker(
                fallbackURL: url,
                alertThresholdFraction: PriceAlertThresholdPolicy.initialThresholdFraction),
            forURLString: url.absoluteString)
        else {
            complete()
            return
        }
        SellerComparison.beginAndRunInBackground(
            itemID: itemID, sourceURL: url, store: store)
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: itemID, host: .extension),
            onReadInstead: { urlString in
                SharedReadingListAppender.append(urlString: urlString)
            })
        editor.onDone = complete
        presentModally(editor)
    }
}
