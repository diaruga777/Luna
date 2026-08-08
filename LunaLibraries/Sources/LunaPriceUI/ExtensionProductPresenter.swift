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
    /// Between the two there is now a phase: the alternative-seller fan-out,
    /// announced on the surface's own wait screen. The editor opens on the
    /// finished tracker — every seller found, the baseline already re-based onto
    /// the median — because a store list that grows under an open editor is a
    /// list the user cannot trust to still be there when they tap it.
    ///
    /// `showLoadingPhase` is a no-op on a host with no wait screen, and the
    /// whole leg is skipped when no fan-out is installed, so a surface that
    /// cannot compare presents exactly as it did before. The engine's own
    /// budget plus `SellerComparisonRunner.hardCapGrace` is the hard cap; when
    /// it expires the editor opens with whatever had landed.
    public func presentPriceEditor(
        product: ProductInfo, url: URL, store: ReadingListStore,
        showLoadingPhase: @escaping (String) -> Void = { _ in },
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
        let present = { [weak self] in
            guard self != nil else { return }
            let editor = PriceTrackingViewController(
                mode: .creation(itemID: itemID, host: .extension),
                onReadInstead: { urlString in
                    SharedReadingListAppender.append(urlString: urlString)
                })
            editor.onDone = complete
            presentModally(editor)
        }
        guard SellerComparisonRunner.installed != nil else {
            present()
            return
        }
        showLoadingPhase(L10n.string("PriceTracker_comparison_findingSellersStatus"))
        Task { @MainActor in
            _ = await SellerComparison.runAndAttach(
                itemID: itemID, sourceURL: url, store: store)
            present()
        }
    }
}
