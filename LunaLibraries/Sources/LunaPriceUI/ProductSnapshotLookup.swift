//
//  ProductSnapshotLookup.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceIngest
import LunaPriceMetadata
import LunaStorage
import LunaURLClassification

/// The app-tier reads of the shared product-snapshot store — the two questions
/// only a target that links `LunaHTMLClassification` can ask, because both are
/// phrased in `ProductInfo`.
///
/// The store itself (and every WRITE) lives in shared SQLite storage. Nothing
/// here scans: each call turns its subject into index keys and reads only their
/// matching rows.
extension ProductSnapshotStore {

    /// Every stored observation that is the same product as `candidate` —
    /// retrieved by identifier through the index, then tiered by
    /// `SnapshotMatcher`. This is the read `ProductTrackerIngestor` makes,
    /// synchronously, while a price tracker is being created.
    /// Two retrievals, in tier order, and the second one usually never happens:
    /// the identifier keys first, and only when they yield NO match the
    /// name-bucket keys — capped at `SnapshotMatcher.fuzzyCandidateLimit`
    /// records. Cost: O(candidate identifiers + matched records), plus, on the
    /// identifier-less pages that need it, ≤ (2 scopes × 5 tokens) index hits
    /// and ≤ 40 record reads. Never O(store).
    public func matchingSnapshots(
        for candidate: ProductInfo, candidateURL: URL, existingStoreURLStrings: [String] = []
    ) -> [ProductSnapshot] {
        let keys = SnapshotMatcher.candidateKeys(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: existingStoreURLStrings)
        let keyedPool = snapshots(forKeys: keys)
        let identified = SnapshotMatcher.identifierMatches(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: existingStoreURLStrings, among: keyedPool)
        guard identified.isEmpty else { return identified }

        let namePool = snapshots(
            forKeys: SnapshotMatcher.nameCandidateKeys(for: candidate, candidateURL: candidateURL),
            limit: SnapshotMatcher.fuzzyCandidateLimit)
        return SnapshotMatcher.merged(
            SnapshotMatcher.urlMatches(
                for: candidateURL, existingStoreURLStrings: existingStoreURLStrings,
                among: keyedPool),
            SnapshotMatcher.fuzzyNameMatches(
                for: candidate, candidateURL: candidateURL, among: namePool))
    }

    /// The newest observation of exactly this page, mapped back into the same
    /// mandatory-price `ProductInfo` the HTML extractor produces. This is the
    /// bot-wall fallback used by app/share/action saves (installed through
    /// `SnapshotProductInfoFallback`): Safari already read the rendered Amazon
    /// page, so a later blocked native refetch must not throw that trustworthy
    /// metadata away.
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

/// The snapshot lookup above as the ingest pipeline's fallback seam
/// (`ProductInfoFallbackProviding`). It lives here rather than in LunaPriceIngest
/// because the lookup does — the protocol is one tier down, where it is asked.
public struct SnapshotProductInfoFallback: ProductInfoFallbackProviding {
    private let store: ProductSnapshotStore

    public init(store: ProductSnapshotStore = .shared) {
        self.store = store
    }

    public func productInfo(forPageURL url: URL) -> ProductInfo? {
        store.productInfo(forPageURL: url)
    }
}
