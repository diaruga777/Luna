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
/// One call per root, so a surface cannot be wired half-way. See
/// `ArticleKindComposition` for why the per-surface lists were replaced.
public enum ProductKindComposition {

    /// Registers every product-kind entry: the price-extraction pipeline
    /// processor, the extension price editor, and the alternative-seller
    /// fan-out.
    ///
    /// The fan-out belongs here for exactly the reason the other two do — it is
    /// consulted from the ingestor, from the extension presenter and from the
    /// Action Button intents, each in a different process, and the one thing
    /// that must never differ between them is whether a save gets compared at
    /// all (`claudedocs/price-comparison.md`).
    ///
    /// Not included: `IngestorKindHandlers.product`, the app-shell persistence
    /// handler, which is built from app-shell types and stays in `KindWiring+*`.
    @MainActor
    public static func install() {
        IngestKindProcessors.product = ProductIngestProcessor(
            fallback: SnapshotProductInfoFallback())
        ShareKindPresenters.product = ExtensionProductPresenter()
        SellerComparisonRunner.install()
    }
}
