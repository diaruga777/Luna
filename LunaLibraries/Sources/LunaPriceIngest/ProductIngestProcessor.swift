//
//  ProductIngestProcessor.swift
//  LunaPriceIngest
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceCompare
import Foundation

/// The product-kind pipeline processor: wraps `ProductMetadataExtractor`
/// (mandatory price from one source). Registered into
/// `IngestKindProcessors.product` by product-handling targets' composition
/// roots (Price Tracker + the central Luna app and their extensions).
///
/// **Every page that gets this far is recorded as a product snapshot**, in
/// whichever process did the classifying — the app, the share extension, the
/// action extension. This is the app-side half of the capture rule the Safari
/// extension has always had: a product page Luna looked at is a price
/// observation, unconditionally, whether or not this visit ends in a save
/// (`claudedocs/price-tracking.md`'s "Product snapshots"). Before it existed,
/// the ONLY writer in the whole codebase was the Safari extension, so a user
/// who saves through the app, the share sheet or the Action Button accumulated
/// an empty store and every tracker was born with a single point.
public final class ProductIngestProcessor: ProductIngestProcessing {
    private let metadataExtractor: ProductMetadataExtractor
    private let fallback: ((URL) -> ProductInfo?)?
    private let snapshotStore: ProductSnapshotStore?

    /// `metadataExtractor` and `fallback` are seams. Product surfaces install
    /// the latter from the passive Safari snapshot store, so an Amazon bot wall
    /// cannot erase metadata the rendered page already handed to Luna.
    /// `snapshotStore` is the capture destination; nil disables recording (a
    /// test that does not want to touch the container).
    public init(
        metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor(),
        fallback: ((URL) -> ProductInfo?)? = nil,
        snapshotStore: ProductSnapshotStore? = .shared
    ) {
        self.metadataExtractor = metadataExtractor
        self.fallback = fallback
        self.snapshotStore = snapshotStore
    }

    public func extract(url: URL, html: String) async -> ProductInfo? {
        guard let product = await extractProduct(url: url, html: html) else { return nil }
        record(product, url: url)
        return product
    }

    private func extractProduct(url: URL, html: String) async -> ProductInfo? {
        if let metadata = await metadataExtractor.extract(url: url, html: html) {
            return ProductInfo(
                name: metadata.name, priceAmount: metadata.price.amount,
                priceCurrency: metadata.price.currency, imageURL: metadata.imageURL,
                brand: metadata.brand, productID: metadata.productID,
                identifiers: metadata.identifiers,
                sellers: metadata.sellers)
        }
        return fallback?(url)
    }

    /// One observation, filed under every identifier the page declared.
    private func record(_ product: ProductInfo, url: URL) {
        guard let snapshotStore else { return }
        snapshotStore.record(payload: Self.snapshotPayload(for: product, url: url))
    }

    /// A detected product page as a snapshot payload — the same key shape
    /// `content.js`'s `extractProductSnapshot()` sends and
    /// `ComparableSellerResult.snapshotPayload` produces, so all three writers
    /// go through one validator.
    static func snapshotPayload(for product: ProductInfo, url: URL) -> [String: Any] {
        var payload: [String: Any] = [
            "name": product.name,
            "price": NSDecimalNumber(decimal: product.priceAmount).stringValue,
            "currency": product.priceCurrency,
            "url": url.absoluteString,
        ]
        if let gtin = product.identifiers.gtin { payload["gtin"] = gtin }
        if let mpn = product.identifiers.mpn { payload["mpn"] = mpn }
        if let sku = product.identifiers.sku { payload["sku"] = sku }
        if let brand = product.brand ?? product.identifiers.brand { payload["brand"] = brand }
        if let productID = product.productID { payload["productID"] = productID }
        if let imageURL = product.imageURL { payload["imageURL"] = imageURL.absoluteString }
        return payload
    }
}
