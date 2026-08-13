//
//  SellerFanOutNetworking.swift
//  LunaPriceCompare
//

import Foundation

/// The optional legs of the fan-out's networking. A conformer DECLARES the ones
/// it runs, and a leg it does not declare is never called — which is what the
/// old `webSearch: nil, richResolve: nil` at the appex's call site said.
public struct SellerFanOutLayers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Layer 2: the keyless web search.
    public static let webSearch = SellerFanOutLayers(rawValue: 1 << 0)
    /// Candidate resolution through the shared ingest pipeline rather than the
    /// lean regex parser.
    public static let richResolve = SellerFanOutLayers(rawValue: 1 << 1)
    /// Rendering a search page's JavaScript.
    public static let renderedSearch = SellerFanOutLayers(rawValue: 1 << 2)
}

/// Everything the fan-out needs from the network, as one contract with two
/// production conformers: `PipelineSellerNetworking` (LunaPriceUI) routes
/// through `ArticleFetcher`, DuckDuckGo, the shared ingest pipeline and a
/// WKWebView; `URLSessionSellerNetworking` (the Safari appex) has a plain
/// ephemeral `URLSession` and this module's regex parser and nothing else.
///
/// The engine makes no request of its own because those two environments have
/// almost nothing in common — see `claudedocs/price-comparison.md`.
public protocol SellerFanOutNetworking: Sendable {

    /// Which optional legs this conformer runs. Required, so a conformer that
    /// implements a leg cannot forget to turn it on.
    var availableLayers: SellerFanOutLayers { get }

    /// Fetch one URL. Returning nil means "no answer" (transport failure);
    /// returning a page with a blocked status is how a bot wall is reported.
    func fetch(_ url: URL) async -> FetchedPage?

    /// Layer 2: candidate result URLs in rank order
    /// (`DuckDuckGoSearch.results`). Only called with `.webSearch` declared.
    func webSearch(query: String) async -> [URL]?

    /// Richer candidate resolution — the full profile routes pages through
    /// `ProductPageSuggestion.resolve` so a JS-rendered price still counts.
    /// Only called with `.richResolve` declared; otherwise the engine parses the
    /// fetched markup itself.
    func richResolve(_ url: URL) async -> ParsedProductPage?

    /// Renders a search page's JavaScript and returns the rendered markup. Only
    /// called with `.renderedSearch` declared — the engine may not link WebKit,
    /// and the Safari appex could not afford it if it did.
    func renderSearch(_ url: URL) async -> String?
}

/// The undeclared legs answer nothing, so a fetch-only conformer implements one
/// method.
public extension SellerFanOutNetworking {
    func webSearch(query: String) async -> [URL]? { nil }
    func richResolve(_ url: URL) async -> ParsedProductPage? { nil }
    func renderSearch(_ url: URL) async -> String? { nil }
}
