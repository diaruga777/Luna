//
//  SellerDirectory.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// One retailer in the bundled regional seller directory: who they are, which
/// region's storefront this entry is, and — the load-bearing part — how to search
/// THEIR OWN site. The fan-out never goes through an aggregator: it asks each
/// retailer directly, so a result is always a real seller page with a real price.
public struct Seller: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable, unique id (`amazon-us`, `johnlewis-uk`, …). Also the final,
    /// deterministic tiebreak in candidate ordering, so a directory edit can
    /// never silently reshuffle equal-scoring sellers.
    public let id: String
    /// Display name shown to the user ("Best Buy").
    public let name: String
    /// The storefront's region (`US`, `GB`, `AU`, …).
    public let region: String
    /// Registrable domain of the storefront (`bestbuy.com`), no scheme.
    public let domain: String
    /// Search-URL template containing exactly one `{query}` placeholder.
    public let searchURL: String
    /// Whether searching by raw GTIN digits is known to work on this site.
    /// `nil` = unknown (neither rewarded nor penalized).
    public let acceptsGTIN: Bool?
    /// A marketplace hosts third-party listings, so a NAME match there is far
    /// noisier than on a first-party retailer (see the selector's penalty).
    public let marketplace: Bool
    /// Taxonomy categories this seller covers (`SellerCategory` raw values);
    /// `general` marks a mass merchant that sells across categories.
    public let categories: [String]
    /// 1 = a household-name retailer, 2 = well known, 3 = niche.
    public let tier: Int
    /// Whether the search-URL template has been checked against the live site.
    public let verified: Bool

    public init(
        id: String, name: String, region: String, domain: String, searchURL: String,
        acceptsGTIN: Bool?, marketplace: Bool, categories: [String], tier: Int, verified: Bool
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.domain = domain
        self.searchURL = searchURL
        self.acceptsGTIN = acceptsGTIN
        self.marketplace = marketplace
        self.categories = categories
        self.tier = tier
        self.verified = verified
    }

    /// The concrete search URL for `query`, or nil when the template is
    /// unusable. `{query}` may sit in the PATH (`/s/{query}`) or in a query
    /// VALUE (`?k={query}`) — those escape differently (a `+` means "space" only
    /// in a query string; in a path it is a literal plus), so the substitution
    /// looks at where the placeholder actually is instead of assuming.
    public func searchRequestURL(forQuery query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let placeholder = searchURL.range(of: SellerDirectory.queryPlaceholder)
        else { return nil }
        let questionMark = searchURL.firstIndex(of: "?")
        let inQueryString = questionMark.map { placeholder.lowerBound > $0 } ?? false
        guard let escaped = trimmed.addingPercentEncoding(
            withAllowedCharacters: SellerDirectory.unreservedCharacters) else { return nil }
        let substituted = inQueryString
            ? escaped.replacingOccurrences(of: "%20", with: "+")
            : escaped
        return URL(string: searchURL.replacingCharacters(in: placeholder, with: substituted))
    }
}

/// The bundled, versioned list of retailers the alternative-seller fan-out may
/// search — the whole seller universe (`claudedocs/price-comparison.md`).
///
/// Bundled rather than fetched on purpose: the fan-out has to run inside the
/// Safari appex and the share/action extensions, where a network round trip
/// just to learn WHERE to look would spend most of the budget before the first
/// real request.
public struct SellerDirectory: Codable, Equatable, Sendable {
    /// Schema version of the bundled file.
    public let version: Int
    public let sellers: [Seller]

    public init(version: Int, sellers: [Seller]) {
        self.version = version
        self.sellers = sellers
    }

    static let queryPlaceholder = "{query}"

    /// RFC 3986 unreserved characters — everything else is escaped, so a product
    /// name containing `&`, `?`, `#`, `/` or a space cannot break out of the
    /// template's path segment or query value.
    static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Loading

    public enum LoadError: Error, Equatable {
        case resourceMissing
        case malformed(String)
    }

    /// The directory shipped inside this module's resource bundle. Decoded once
    /// and cached — every candidate selection reads it.
    public static func bundled() throws -> SellerDirectory {
        if let cached = cache.value { return cached }
        guard let url = Bundle.module.url(forResource: "seller-directory", withExtension: "json")
        else { throw LoadError.resourceMissing }
        let directory = try decode(Data(contentsOf: url))
        cache.value = directory
        return directory
    }

    public static func decode(_ data: Data) throws -> SellerDirectory {
        do {
            return try JSONDecoder().decode(SellerDirectory.self, from: data)
        } catch {
            throw LoadError.malformed(String(describing: error))
        }
    }

    private static let cache = DirectoryCache()

    private final class DirectoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SellerDirectory?
        var value: SellerDirectory? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Lookup

    /// Every seller whose storefront serves `region` (case-insensitive).
    public func sellers(inRegion region: String) -> [Seller] {
        let wanted = region.uppercased()
        return sellers.filter { $0.region.uppercased() == wanted }
    }

    /// The directory entry whose domain is the same retailer family as `host`,
    /// if any. This is how a saved page's own region is discovered, and how a
    /// web-search result gets a display name.
    public func seller(forHost host: String) -> Seller? {
        let domain = ProductIdentityMatching.registrableDomain(host)
        return sellers.first { ProductIdentityMatching.registrableDomain($0.domain) == domain }
    }

    public var regions: [String] { Array(Set(sellers.map { $0.region.uppercased() })).sorted() }

    // MARK: - Validation

    /// Every structural problem in this directory, as human-readable lines.
    /// Empty means valid. Run against the SHIPPED json by
    /// `SellerDirectoryTests`, so a hand-edited entry cannot reach a release
    /// with a broken template or an invented category.
    public func validate() -> [String] {
        var problems: [String] = []
        if version < 1 { problems.append("version must be >= 1, got \(version)") }
        if sellers.isEmpty { problems.append("directory is empty") }

        var seenIDs: Set<String> = []
        let taxonomy = Set(SellerCategory.allCases.map(\.rawValue))
        for seller in sellers {
            let label = seller.id.isEmpty ? "<empty id>" : seller.id
            if seller.id.isEmpty { problems.append("a seller has an empty id") }
            if !seenIDs.insert(seller.id).inserted { problems.append("\(label): duplicate id") }
            if seller.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(label): empty name")
            }
            if seller.region.count != 2 || seller.region != seller.region.uppercased() {
                problems.append("\(label): region must be a 2-letter uppercase code, got '\(seller.region)'")
            }
            if seller.domain.contains("/") || seller.domain.contains(":")
                || !seller.domain.contains(".") || seller.domain != seller.domain.lowercased() {
                problems.append("\(label): domain must be a bare lowercase host, got '\(seller.domain)'")
            }
            if !seller.searchURL.hasPrefix("https://") {
                problems.append("\(label): searchURL must be https")
            }
            let placeholders = seller.searchURL.components(separatedBy: Self.queryPlaceholder).count - 1
            if placeholders != 1 {
                problems.append("\(label): searchURL must contain exactly one {query}, found \(placeholders)")
            } else if seller.searchRequestURL(forQuery: "test query") == nil {
                problems.append("\(label): searchURL does not resolve to a URL")
            }
            if let host = URL(string: seller.searchURL.replacingOccurrences(
                of: Self.queryPlaceholder, with: "x"))?.host,
               ProductIdentityMatching.registrableDomain(host)
                != ProductIdentityMatching.registrableDomain(seller.domain) {
                problems.append("\(label): searchURL host '\(host)' is not on domain '\(seller.domain)'")
            }
            if seller.categories.isEmpty { problems.append("\(label): no categories") }
            for category in seller.categories where !taxonomy.contains(category) {
                problems.append("\(label): '\(category)' is not in the category taxonomy")
            }
            if Set(seller.categories).count != seller.categories.count {
                problems.append("\(label): duplicate categories")
            }
            if !(1...3).contains(seller.tier) {
                problems.append("\(label): tier must be 1…3, got \(seller.tier)")
            }
        }
        return problems
    }
}
