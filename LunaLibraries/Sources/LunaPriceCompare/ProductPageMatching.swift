//
//  ProductPageMatching.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// "Is the product page I am looking at the same product as this stored one?" —
/// asked about a page's freshly extracted `ProductSnapshot`, against the
/// app-written tracked-product index and against other stored observations.
///
/// Same identifier precedence `SnapshotMatcher` (LunaPriceUI) applies to a
/// product being SAVED, in the terms a page has: GTIN → retailer item id within
/// one retailer family → mpn with a compatible brand → sku on the same host →
/// canonical URL. It lives here because its callers are the Safari extensions
/// (the history pill and the alternative-seller pill), and this is the kind
/// module they link.
public enum ProductPageMatching {

    /// Page vs. a tracked index entry, whose only identifier is ONE flattened
    /// `productID` string (exactly `ProductInfo.productID`'s shape) — so the
    /// page's own KEYED fields are compared against it in precedence order.
    ///
    /// It ends with a fuzzy-name tier the snapshot comparison below has no need
    /// of: a tracked product is one the user chose, its name is the one they
    /// gave it, and the index carries no keyed identifiers to match on instead.
    public static func matches(page: ProductSnapshot, indexEntry entry: PriceHistoryIndexEntry) -> Bool {
        let entryID = ProductIdentityMatching.normalizedID(entry.productID)
        let storeHosts = entry.stores.map(\.host)
        let storeURLs = entry.stores.map(\.url)

        if let entryGTIN = ProductIdentityMatching.normalizedGTIN(entryID),
           let pageGTIN = ProductIdentityMatching.normalizedGTIN(
               ProductIdentityMatching.normalizedID(page.gtin)),
           entryGTIN == pageGTIN {
            return true
        }
        if let entryID,
           let pageRetailerID = ProductIdentityMatching.normalizedID(page.retailerItemID),
           entryID == pageRetailerID,
           storeHosts.contains(where: {
               ProductIdentityMatching.hostFamilyMatches($0, page.host)
           }) {
            return true
        }
        if let entryID, let pageMPN = ProductIdentityMatching.normalizedID(page.mpn),
           entryID == pageMPN,
           ProductIdentityMatching.brandsCompatible(page.brand, entry.brand) {
            return true
        }
        if let entryID, let pageSKU = ProductIdentityMatching.normalizedID(page.sku),
           entryID == pageSKU,
           storeHosts.contains(where: { $0.lowercased() == page.host.lowercased() }) {
            return true
        }
        let strippedPageURL = ProductSnapshotKeys.strippedTrackingURL(page.url)
        if storeURLs.contains(where: {
            ProductSnapshotKeys.strippedTrackingURL($0) == strippedPageURL
        }) {
            return true
        }
        if ProductIdentityMatching.brandsCompatible(page.brand, entry.brand),
           ProductIdentityMatching.nameSimilarity(page.name, entry.name)
               >= ProductIdentityMatching.nameThreshold {
            return true
        }
        return false
    }

    /// Page vs. another stored observation — both sides carry the same keyed
    /// identifiers, so each tier compares the matching field directly.
    ///
    /// No fuzzy-name tier, exactly as `SnapshotMatcher`'s identifier tiers have
    /// none: a name is not an identifier, the store is retrieved BY identifier,
    /// and it is the tier most likely to claim two different products are one.
    public static func matches(page: ProductSnapshot, snapshot: ProductSnapshot) -> Bool {
        if let pageGTIN = ProductIdentityMatching.normalizedGTIN(
               ProductIdentityMatching.normalizedID(page.gtin)),
           let otherGTIN = ProductIdentityMatching.normalizedGTIN(
               ProductIdentityMatching.normalizedID(snapshot.gtin)),
           pageGTIN == otherGTIN {
            return true
        }
        if let pageRetailerID = ProductIdentityMatching.normalizedID(page.retailerItemID),
           let otherRetailerID = ProductIdentityMatching.normalizedID(snapshot.retailerItemID),
           pageRetailerID == otherRetailerID,
           ProductIdentityMatching.hostFamilyMatches(page.host, snapshot.host) {
            return true
        }
        if let pageMPN = ProductIdentityMatching.normalizedID(page.mpn),
           let otherMPN = ProductIdentityMatching.normalizedID(snapshot.mpn),
           pageMPN == otherMPN,
           ProductIdentityMatching.brandsCompatible(page.brand, snapshot.brand) {
            return true
        }
        if let pageSKU = ProductIdentityMatching.normalizedID(page.sku),
           let otherSKU = ProductIdentityMatching.normalizedID(snapshot.sku),
           pageSKU == otherSKU,
           page.host.lowercased() == snapshot.host.lowercased() {
            return true
        }
        return ProductSnapshotKeys.strippedTrackingURL(page.url)
            == ProductSnapshotKeys.strippedTrackingURL(snapshot.url)
    }
}
