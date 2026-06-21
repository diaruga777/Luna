//
//  ProductPageSuggestion.swift
//  ReaderKit
//

import Foundation

/// The pure, UNIFIED "should this live page be suggested as a seller?" decision.
///
/// It is exactly the condition under which an Add succeeds, so a page that
/// auto-suggests is precisely a page whose Add will work: the page must
/// 1. classify as a `.product` via the shared `Classifier`, AND
/// 2. yield a real price via the shared `ProductMetadataExtractor`.
///
/// Both checks run over the WKWebView's RENDERED `outerHTML`, so JS-loaded prices
/// are seen (the render-tier equivalent for a live WebView — the page is already
/// rendered, so no off-screen render is needed and `render: nil` is correct here).
/// There is no special-case detection: the same two components the ingest pipeline
/// uses make this call.
enum ProductPageSuggestion {

    /// Whether `html` (a rendered page at `url`) is a product page WITH a resolvable
    /// price. Returns the resolved metadata so the caller can avoid re-extracting,
    /// or nil when the page is not a priced product (→ do not suggest / Add fails).
    static func resolve(
        url: URL,
        html: String,
        classify: (URL, String) -> ContentKind = { Classifier.classify(url: $0, html: $1) },
        extractor: ProductMetadataExtractor = ProductMetadataExtractor()
    ) async -> ProductMetadata? {
        let isProduct: Bool = {
            if case .product = classify(url, html) { return true }
            return false
        }()
        guard isProduct else { return nil }
        // The rendered HTML is already in hand → no render tier needed (render: nil).
        return await extractor.extract(url: url, html: html, render: nil)
    }
}
