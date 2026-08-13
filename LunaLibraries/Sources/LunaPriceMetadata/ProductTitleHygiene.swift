//
//  ProductTitleHygiene.swift
//  LunaPriceMetadata
//

import Foundation

/// Strips a retailer's own furniture off a product title.
///
/// A page title is not a product name. Amazon's is `Amazon.com: Atomic Habits:
/// An Easy & Proven Way to Build Good Habits & Break Bad Ones | Clear, James:
/// Books`; Walmart's ends `- Walmart.com`; a Shopify shop ends `– The Widget
/// Shop`. Two things downstream depend on this stripping:
///
/// - **The search query.** Falling back to the name means searching another
///   retailer's site for the string "Amazon.com", which returns nothing on
///   the first page of every retailer in the directory.
/// - **Name similarity.** `nameSimilarity` is Jaccard over tokens, so the
///   storefront's name, its TLD, and its category trail are all tokens the
///   two sides cannot share — the source is penalized for words that
///   describe the shop rather than the product, and a genuine match falls
///   under the threshold.
///
/// Deliberately conservative: it removes prefixes and suffixes that are
/// definitely chrome and leaves everything it is unsure about, because a title
/// that keeps a redundant word still matches, and one that loses a real one may
/// not.
public enum ProductTitleHygiene {

    /// The title with storefront chrome removed and whitespace tidied.
    public static func cleaned(_ raw: String) -> String {
        var title = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        title = strippingStorefrontPrefix(title)
        title = strippingColonStorefrontTail(title)
        title = strippingStorefrontSuffix(title)
        title = strippingFormatTail(title)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:·,"))
        // Nothing survived: the chrome was the title, so keep the original
        // rather than hand a caller an empty product name.
        return title.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : title
    }

    /// `Amazon.com: `, `Amazon.com.au: `, `Buy … : ` — the storefront naming
    /// itself before the colon.
    static func strippingStorefrontPrefix(_ title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = String(title[..<colon]).trimmingCharacters(in: .whitespaces)
        guard head.count <= 24, looksLikeStorefront(head) else { return title }
        return String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// `<name>: <category>: Amazon.com.au`, `<name> : Amazon.com.au: <category>`
    /// — Amazon AU's `<title>` puts its own domain in a colon-separated
    /// segment after the product name, with a breadcrumb-style category
    /// segment on either side of it (measured live: `… Chrome: Toasters:
    /// Amazon.com.au` and `… ES9600 : Amazon.com.au: Health, Household &
    /// Personal Care` — the second has the storefront before the category,
    /// the first after it). Neither shape is a dash/pipe suffix, so
    /// `strippingStorefrontSuffix` never sees it, and it is not the prefix
    /// either, since `strippingStorefrontPrefix` only looks at the head
    /// before the first colon. Once any segment beyond the first is
    /// domain-shaped (contains a dot, e.g. `amazon.com.au` — narrower than
    /// `looksLikeStorefront`'s bare-word match, which would also fire on an
    /// innocent category segment like "Books"), the product name is just the
    /// first segment: a category carries no product information wherever it
    /// sits relative to the storefront's own name.
    static func strippingColonStorefrontTail(_ title: String) -> String {
        let normalized = title.replacingOccurrences(
            of: #"\s*:\s*"#, with: "\u{0}", options: [.regularExpression])
        let segments = normalized.components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard segments.count > 1, let first = segments.first, !first.isEmpty,
              segments.dropFirst().contains(where: looksLikeStorefrontDomain)
        else { return title }
        return first
    }

    /// The domain-shaped half of `looksLikeStorefront` only — a fragment must
    /// contain a dot (`amazon.com.au`), never a bare word (`Books`, `Target`)
    /// alone. The bare-word match is right for a dash/pipe suffix (an actual
    /// chrome fragment there never doubles as a legitimate category name),
    /// but a colon-separated segment is exactly where a real category name
    /// (`Toasters`, `Books`) sits, so the colon-tail stripper needs the
    /// stricter test to avoid mistaking one for the storefront itself.
    static func looksLikeStorefrontDomain(_ fragment: String) -> Bool {
        let lower = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.contains(".") else { return false }
        if lower.range(of: #"^[a-z0-9][a-z0-9 &'’-]{0,20}\.(com|co\.uk|ca|com\.au|co\.nz|ie|in|sg|co\.za|net|org)$"#,
                        options: [.regularExpression]) != nil {
            return true
        }
        let head = lower.components(separatedBy: ".")[0]
        return storefrontWords.contains(head)
    }

    /// ` - Walmart.com`, ` | Target`, ` – Barnes & Noble` — the storefront
    /// naming itself after the last separator.
    static func strippingStorefrontSuffix(_ title: String) -> String {
        var result = title
        for _ in 0..<2 {
            guard let separator = result.range(
                of: #" [-–—|] [^-–—|]{1,30}$"#, options: [.regularExpression]) else { break }
            let tail = String(result[separator])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|"))
            guard looksLikeStorefront(tail) else { break }
            result = String(result[..<separator.lowerBound])
        }
        return result
    }

    /// A trailing format/edition parenthetical, which is retailer vocabulary
    /// rather than the product: `(Paperback)`, `(Hardcover)`, `[Blu-ray]`. A
    /// parenthetical the table does not recognize — an edition name, a
    /// colour, a pack size — is left alone, because those do distinguish
    /// products.
    static func strippingFormatTail(_ title: String) -> String {
        var result = title
        while let tail = result.range(of: #"[\(\[][^()\[\]]{1,40}[\)\]]\s*$"#,
                                      options: [.regularExpression]) {
            let inner = String(result[tail])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
                .lowercased()
            guard formatWords.contains(inner) else { break }
            result = String(result[..<tail.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static let formatWords: Set<String> = [
        "paperback", "hardcover", "hardback", "mass market paperback", "board book",
        "kindle edition", "audiobook", "audio cd", "ebook", "e-book", "large print",
        "blu-ray", "dvd", "vinyl", "lp", "cd", "4k ultra hd", "digital",
        "new", "used", "refurbished", "open box",
    ]

    /// Whether a fragment names a shop rather than a product: a bare domain,
    /// or a known storefront word. Anything else is left in the title.
    static func looksLikeStorefront(_ fragment: String) -> Bool {
        let text = fragment.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        if lower.range(of: #"^[a-z0-9][a-z0-9 &'’-]{0,20}\.(com|co\.uk|ca|com\.au|co\.nz|ie|in|sg|co\.za|net|org)$"#,
                       options: [.regularExpression]) != nil {
            return true
        }
        if storefrontWords.contains(lower) { return true }
        // "Amazon.com.au", "Amazon.co.uk" and friends: a known storefront word
        // followed by nothing but a TLD.
        let head = lower.components(separatedBy: ".")[0]
        return lower.contains(".") && storefrontWords.contains(head)
    }

    static let storefrontWords: Set<String> = [
        "amazon", "walmart", "target", "ebay", "costco", "sam's club", "samsclub",
        "barnes & noble", "barnes and noble", "b&n", "best buy", "bestbuy",
        "the home depot", "home depot", "lowe's", "lowes", "argos", "john lewis",
        "currys", "tesco", "sainsbury's", "asda", "very", "next", "boots",
        "waterstones", "whsmith", "kmart", "big w", "bunnings", "jb hi-fi",
        "the warehouse", "trade me", "indigo", "chapters indigo", "canadian tire",
        "flipkart", "myntra", "lazada", "shopee", "takealot", "etsy", "wayfair",
        "newegg", "staples", "kohl's", "kohls", "macy's", "macys", "books",
    ]
}
