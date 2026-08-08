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

    /// `metadataExtractor` is a test seam; production uses the default.
    public init(metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor()) {
        self.metadataExtractor = metadataExtractor
    }

    public func extract(
        url: URL, html: String, render: ((URL) async -> String?)?
    ) async -> ProductInfo? {
        guard let metadata = await metadataExtractor.extract(
            url: url, html: html, render: render) else { return nil }
        return ProductInfo(
            name: metadata.name, priceAmount: metadata.price.amount,
            priceCurrency: metadata.price.currency, imageURL: metadata.imageURL,
            brand: metadata.brand, productID: metadata.productID,
            identifiers: metadata.identifiers,
            sellers: metadata.sellers)
    }
}
