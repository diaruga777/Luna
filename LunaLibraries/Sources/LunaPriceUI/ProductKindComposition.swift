//
//  ProductKindComposition.swift
//  LunaPriceUI
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceIngest
import LunaShareSurface
import LunaStorage
import LunaURLClassification
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
        IngestKindProcessors.product = ProductIngestProcessor(fallback: { url in
            ProductSnapshotStore.shared.productInfo(forPageURL: url)
        })
        ShareKindPresenters.product = ProductSharePresenter()
        SellerComparisonRunner.install()
    }
}

/// Adapts the protocol-free `ExtensionProductPresenter` to the kind-neutral
/// `ShareProductPresenting` surface protocol. Previously copy-pasted into four
/// composition roots; `LunaShareSurface` is kind-agnostic, so the kind module
/// owns its own conformance.
struct ProductSharePresenter: ShareProductPresenting {
    private let presenter = ExtensionProductPresenter()

    func presentPriceEditor(
        product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost
    ) {
        presenter.presentPriceEditor(
            product: product, url: url, store: store,
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() },
            openContainingAppForAddSeller: { [weak host] itemID in
                guard let link = LunaDeepLink.priceTrackerAddSellerLink(itemID: itemID) else { return }
                host?.openURL(link)
            })
    }
}
