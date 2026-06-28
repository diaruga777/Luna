//
//  ProductSuggestionDebouncer.swift
//  ReaderKit
//

import Foundation

/// Tracks which page URLs have already been auto-offered as a seller, so the
/// "Use this page?" prompt fires at most once per URL even though `didFinish`
/// re-fires on in-page updates / SPA navigations. Pure and order-independent.
public struct ProductSuggestionDebouncer {

    public init() {}

    private var offeredURLStrings: Set<String> = []

    /// Whether `urlString` should be auto-offered now: true exactly once per URL.
    /// Records the URL as offered on the first true so subsequent calls return false.
    public mutating func shouldOffer(urlString: String) -> Bool {
        guard !offeredURLStrings.contains(urlString) else { return false }
        offeredURLStrings.insert(urlString)
        return true
    }

    /// Whether `urlString` has already been offered (without recording it).
    public func hasOffered(urlString: String) -> Bool {
        offeredURLStrings.contains(urlString)
    }
}
