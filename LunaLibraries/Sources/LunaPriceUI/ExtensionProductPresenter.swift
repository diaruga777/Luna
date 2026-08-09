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
    /// plain save confirmation when the row is gone).
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
    ///
    /// **Merges, rather than always creating.** Before this asked
    /// `ProductTrackerMerge` (shared with the in-app path — see
    /// `claudedocs/price-comparison.md`'s "Extension saves merge and seed"),
    /// a share-sheet save of a product already being tracked created a
    /// second, unrelated tracker even when both pages declared the SAME GTIN.
    /// On a merge the editor opens on the MATCHED tracker's item, in
    /// `.merge` mode, instead of duplicating — synchronously, with no image
    /// download or other await the extension cannot afford.
    public func presentPriceEditor(
        product: ProductInfo, url: URL, store: ReadingListStore,
        presentModally: @escaping (UIViewController) -> Void,
        complete: @escaping () -> Void
    ) {
        guard let placeholder = store.item(forURLString: url.absoluteString) else {
            complete()
            return
        }

        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product, url: url, excludingItemID: placeholder.id, store: store,
            comparisonStarter: { itemID, sourceURL, store in
                SellerComparison.beginAndRunInBackground(itemID: itemID, sourceURL: sourceURL, store: store)
            })

        let editor: PriceTrackingViewController
        switch outcome {
        case let .merged(matchID, highlightedURL):
            // The just-saved placeholder was a duplicate route into an
            // existing tracker; drop it so only the merged tracker remains.
            store.delete(placeholder)
            PriceTrackerSaveAnnouncement.post(
                itemID: matchID, source: placeholder.effectiveCaptureSource,
                isMerge: true, highlightedURL: highlightedURL)
            editor = PriceTrackingViewController(
                mode: .merge(
                    itemID: matchID, addedStoreURLString: highlightedURL ?? url.absoluteString,
                    host: .extension))

        case .newTracker:
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
            editor = PriceTrackingViewController(mode: .creation(itemID: itemID, host: .extension))
        }
        editor.onDone = complete
        presentModally(editor)
    }
}
