//
//  KindWiring+PriceTracker.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors and
//  ingestor handlers this app's target links. EXACTLY ONE KindWiring variant is
//  compiled into each app target (the other variants are excluded via the
//  synchronized group's per-target membership exceptions) — the registries
//  mirror the link set.
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceIngest
import LunaPriceUI
import LunaReadingList
import LunaStorage
import Foundation

enum KindWiring {
    static func install() {
        IngestKindProcessors.product = ProductIngestProcessor()
        IngestorKindHandlers.product = ProductKindHandler()
        EmailShareCenter.priceGraphSnapshot = { PriceGraphEmailSnapshot.jpegData(for: $0) }
    }
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}
