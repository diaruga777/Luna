//
//  GoogleShoppingURL.swift
//  ReaderKit
//

import Foundation

/// Recognizes a Google Shopping page by URL alone (host + path + query). The ONE
/// predicate shared by the `Classifier` (which routes a hit to `.product` so a saved
/// shopping page becomes a price tracker, never an article) and
/// `GoogleShoppingProductParser` (which extracts the seller listings). Keeping both
/// callers on this single source means the classifier and the extractor can never
/// disagree about what a Google Shopping URL is.
///
/// A Google Shopping page is `google.com/search` carrying any of the markers Google
/// uses for shopping surfaces:
/// - `tbm=shop` / `udm=28` / `shopmd` — the search-results shopping grid, and
/// - `ibp=oshop` / `prds` — a specific product's offers page (the canonical URL a
///   shared product link resolves to: e.g. a `share.google/<id>` link 301s to
///   `…/search?ibp=oshop&…&prds=productid:…`).
public enum GoogleShoppingURL {
    public static func isProductPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com"),
              url.path == "/search",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let items = components.queryItems ?? []
        func equals(_ name: String, _ value: String) -> Bool {
            items.contains { $0.name == name && $0.value == value }
        }
        func present(_ name: String) -> Bool {
            items.contains { $0.name == name }
        }
        return equals("tbm", "shop") || equals("udm", "28") || present("shopmd")
            || equals("ibp", "oshop") || present("prds")
    }
}
