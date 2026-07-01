//
//  ProductSearchURL.swift
//  Luna
//

import Foundation

/// Pure builders for the web searches used by the price-tracker's "Search" /
/// browse-to-add-a-seller flow. No I/O, no UIKit — fully unit-testable.
public enum ProductSearchURL {

    /// The base used for the Google Shopping search (the "Shopping" tab).
    private static let googleShoppingBase = "https://www.google.com/search"

    /// Builds a Google **Shopping**-tab search URL for `productName`
    /// (`https://www.google.com/search?tbm=shop&q=<percent-encoded name>`).
    ///
    /// `tbm=shop` selects the Shopping tab. The product name is percent-encoded for a
    /// query value: spaces become `+` (the conventional query-string space) and any
    /// other reserved characters are escaped, so a name like `Sony WH-1000XM5` or one
    /// with `&`/spaces produces a valid, single-result URL. Returns nil only when the
    /// name is empty/whitespace (nothing to search for).
    public static func googleShoppingURL(forProductName productName: String) -> URL? {
        let trimmed = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Percent-encode for a query value, then use `+` for spaces (the standard
        // x-www-form-urlencoded space, which Google's search expects).
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: queryValueAllowed) else { return nil }
        let query = encoded.replacingOccurrences(of: "%20", with: "+")
        return URL(string: "\(googleShoppingBase)?tbm=shop&q=\(query)")
    }

    /// Resolves what the bottom URL bar's text should navigate to: a real URL when
    /// the text already looks like one (has a scheme, or a `host.tld[/…]` shape), else
    /// a plain Google web search for the typed text (so typing a product name and
    /// hitting Go searches rather than failing). Returns nil only for empty input.
    public static func navigationURL(fromBarText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
           let url = URL(string: trimmed) {
            return url
        }
        // A bare domain (no spaces and a dotted host like `amazon.com/dp/…`) → load it
        // over https; otherwise treat the text as a search query.
        if !trimmed.contains(" "), looksLikeBareHost(trimmed),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return googleWebSearchURL(forQuery: trimmed)
    }

    /// A plain Google **web** search (not the Shopping tab) for free-text typed into
    /// the URL bar.
    public static func googleWebSearchURL(forQuery query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
        else { return nil }
        let q = encoded.replacingOccurrences(of: "%20", with: "+")
        return URL(string: "\(googleShoppingBase)?q=\(q)")
    }

    /// True when `text` has a `something.tld` shape (a dot with a short alphabetic
    /// suffix), so the bar treats it as a host to load rather than a search query.
    private static func looksLikeBareHost(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        guard let dotIndex = host.lastIndex(of: ".") else { return false }
        let suffix = host[host.index(after: dotIndex)...]
        return suffix.count >= 2 && suffix.allSatisfy { $0.isLetter }
    }

    /// Characters allowed unescaped in a query VALUE: the URL query set minus the
    /// sub-delimiters that carry meaning in a query string (`&`, `=`, `+`, `?`, `#`,
    /// …), so a product name containing them can't break out of the `q=` value.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        return allowed
    }()
}
