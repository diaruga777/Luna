//
//  ProductIngestProcessor.swift
//  LunaPriceIngest
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
import Foundation

/// The product-kind pipeline processor: wraps `ProductMetadataExtractor`
/// (mandatory price from one source). Registered into
/// `IngestKindProcessors.product` by product-handling targets' composition
/// roots (Price Tracker + the central Luna app and their extensions).
public final class ProductIngestProcessor: ProductIngestProcessing {
    private let metadataExtractor: ProductMetadataExtractor
    private let fallback: ((URL) -> ProductInfo?)?

    /// `metadataExtractor` and `fallback` are seams. Product surfaces install
    /// the latter from the passive Safari snapshot store, so an Amazon bot wall
    /// cannot erase metadata the rendered page already handed to Luna.
    public init(
        metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor(),
        fallback: ((URL) -> ProductInfo?)? = nil
    ) {
        self.metadataExtractor = metadataExtractor
        self.fallback = fallback
    }

    public func extract(url: URL, html: String) async -> ProductInfo? {
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
}
