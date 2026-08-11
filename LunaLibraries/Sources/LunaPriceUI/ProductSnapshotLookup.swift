//
//  ProductSnapshotLookup.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceMetadata
import LunaURLClassification

/// The app-tier reads of the shared product-snapshot store — the two questions
/// only a target that links `LunaHTMLClassification` can ask, because both are
/// phrased in `ProductInfo`.
///
/// The store itself (and every WRITE) lives in `LunaPriceCompare`, which the
/// Safari appexes link too. Nothing here scans: each call turns its subject into
/// index keys and opens only the records those keys name.
extension ProductSnapshotStore {

    /// Every stored observation that is the same product as `candidate` —
    /// retrieved by identifier through the index, then tiered by
    /// `SnapshotMatcher`. This is the read `ProductTrackerIngestor` makes,
    /// synchronously, while a price tracker is being created.
    public func matchingSnapshots(
        for candidate: ProductInfo, candidateURL: URL, existingStoreURLStrings: [String] = []
    ) -> [ProductSnapshot] {
        let keys = SnapshotMatcher.candidateKeys(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: existingStoreURLStrings)
        let pool = snapshots(forKeys: keys)
        guard !pool.isEmpty else { return [] }
        return SnapshotMatcher.matchingSnapshots(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: existingStoreURLStrings, among: pool)
    }

    /// The newest observation of exactly this page, mapped back into the same
    /// mandatory-price `ProductInfo` the HTML extractor produces. This is the
    /// bot-wall fallback used by app/share/action saves: Safari already read
    /// the rendered Amazon page, so a later blocked native refetch must not
    /// throw that trustworthy metadata away.
    public func productInfo(forPageURL url: URL) -> ProductInfo? {
        let canonical = URLClassification.canonicalURL(url)
        var keys = [ProductSnapshotKeys.urlKey(canonical.absoluteString)]
        // Amazon changes slugs and appends `/ref=…` path components freely, so
        // two visits to one product rarely share a URL. The ASIN is the actual
        // page identity and survives all of it.
        if AmazonStorefronts.storefront(for: canonical.host) != nil,
           let asin = AmazonProductDetails.asin(in: canonical) {
            keys.append(contentsOf: ProductSnapshotKeys.retailerKeys(asin, host: canonical.host))
            keys.append(contentsOf: ProductSnapshotKeys.skuKeys(asin, host: canonical.host))
        }
        let host = canonical.host?.lowercased()
        guard let snapshot = snapshots(forKeys: keys)
            .filter({ $0.host.lowercased() == host })
            .max(by: { $0.capturedAt < $1.capturedAt }),
              let amount = snapshot.priceAmount
        else { return nil }
        return ProductInfo(
            name: snapshot.name, priceAmount: amount, priceCurrency: snapshot.currency,
            imageURL: snapshot.imageURL.flatMap(URL.init(string:)), brand: snapshot.brand,
            productID: snapshot.productID ?? snapshot.retailerItemID,
            identifiers: ProductIdentifiers(
                gtin: snapshot.gtin, mpn: snapshot.mpn,
                sku: snapshot.sku ?? snapshot.retailerItemID, brand: snapshot.brand))
    }
}
