//
//  ProductPageSuggestion.swift
//  ReaderKit
//

import ClipIngest
import ClipHTMLClassification
import ClipModels
import Foundation

/// The shared-pipeline result used to offer a product page as a seller.
public struct ProductPageSuggestion: Equatable {
    public let url: URL
    public let html: String
    public let metadata: ProductMetadata
}

/// The UNIFIED "should this live page be suggested as a seller?" decision.
///
/// This deliberately calls `IngestPipeline` rather than reproducing its classifier
/// and metadata-extractor branches. The search overlay is therefore subject to the
/// same URL unwrapping, classification, product eligibility, and price rules as
/// every other capture surface.
///
/// A rendered `outerHTML` is supplied as `prefetchedHTML`, which avoids refetching
/// a page that is already open and lets JS-hydrated product data take the same path.
/// Google Shopping merchant links intentionally omit it: that HTML belongs to
/// Google, so the pipeline fetches and evaluates the selected seller's own page.
/// There is no special-case product detection in this type.
public extension ProductPageSuggestion {

    /// Processes `url` through the shared URL pipeline and returns a suggestion only
    /// for a price-tracking-eligible product result.
    public static func resolve(
        url: URL,
        html: String? = nil
    ) async -> ProductPageSuggestion? {
        let result = await IngestPipeline.processResolved(
            IngestInput(url: url, source: .manual, prefetchedHTML: html))
        guard case let .product(product, processedHTML) = result.outcome else { return nil }
        return ProductPageSuggestion(
            url: result.url,
            html: processedHTML,
            metadata: ProductMetadata(
                name: product.name,
                price: ProductPrice(amount: product.priceAmount, currency: product.priceCurrency),
                imageURL: product.imageURL,
                brand: product.brand,
                productID: product.productID))
    }
}
