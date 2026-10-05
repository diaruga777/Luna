//
//  ProductKindComposition.swift
//  LunaPriceUI
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceCompare
import LunaPriceIngest
import LunaShareSurface
import LunaStorage
import Foundation

/// THE single definition of what registering the **product kind** (price
/// tracking) means, for every surface of every product-handling app.
///
/// A composition root calls `install()` once, so no surface can wire only
/// part of the kind. See `ArticleKindComposition` for the same pattern.
public enum ProductKindComposition {

    /// Registers every product-kind entry: the price-extraction pipeline
    /// processor, the extension price editor, and the alternative-seller
    /// fan-out.
    ///
    /// The fan-out belongs here because the ingestor, the extension presenter,
    /// and the Action Button intents each run in a different process and must
    /// agree on whether a save gets compared at all
    /// (`claudedocs/price-comparison.md`).
    ///
    /// Excludes `IngestorKindHandlers.product`: the app-shell persistence
    /// handler is built from app-shell types and stays in `KindWiring+*`.
    @MainActor
    public static func install() {
        IngestKindProcessors.product = URLBehaviorPolicy.pluginsOnly ? nil : ProductIngestProcessor(
            fallback: SnapshotProductInfoFallback())
        ShareKindPresenters.product = ExtensionProductPresenter()
        PluginModelAdopters.product = ProductModelAdopter()
        if !URLBehaviorPolicy.pluginsOnly { SellerComparisonRunner.install() }
    }
}
