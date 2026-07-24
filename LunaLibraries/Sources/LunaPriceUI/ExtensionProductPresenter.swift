//
//  ExtensionProductPresenter.swift
//  LunaPriceUI
//

import LunaHTMLClassification
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
    public func presentPriceEditor(
        product: ProductInfo, url: URL, store: ReadingListStore,
        presentModally: (UIViewController) -> Void,
        complete: @escaping () -> Void
    ) {
        guard let itemID = store.savePriceTracker(
            product.makeTracker(fallbackURL: url), forURLString: url.absoluteString)
        else {
            complete()
            return
        }
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: itemID, host: .extension),
            onReadInstead: { urlString in SharedReadingListAppender.append(urlString: urlString) })
        editor.onDone = complete
        presentModally(editor)
    }
}
