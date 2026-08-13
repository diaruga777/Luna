//
//  PipelineSellerNetworking.swift
//  LunaPriceUI
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare

/// The fan-out's networking as the APP surfaces have it: the app's own fetcher,
/// a keyless web search, the whole shared ingest pipeline, and a WKWebView
/// render tier. Every leg the engine offers, which is why it declares all three
/// optional layers.
///
/// The Safari appex's `URLSessionSellerNetworking` is the other conformer, and
/// the difference between the two is the entire reason the engine makes no
/// request of its own (`claudedocs/price-comparison.md`).
struct PipelineSellerNetworking: SellerFanOutNetworking {
    /// Bounds every leg: the profile's per-fetch allowance is advisory on the
    /// profile precisely because the engine does not fetch, so honouring it is
    /// this type's job.
    private let profile: SellerFanOutProfile

    init(profile: SellerFanOutProfile) {
        self.profile = profile
    }

    let availableLayers: SellerFanOutLayers = [.webSearch, .richResolve, .renderedSearch]

    /// One page, through the app's ordinary fetcher, under the profile's
    /// per-fetch allowance.
    ///
    /// A refusal is a RESULT here, not an error: the engine's bot-wall rule is
    /// the reason candidates are over-provisioned, and it can only apply that
    /// rule if the status code survives the throw.
    ///
    /// **The cap is this leg's job, and it was missing.** `perFetchTimeout`
    /// is advisory on the profile precisely because the engine makes no request
    /// of its own — the Safari appex honours it by building its `URLSession`
    /// around it, and this side simply did not, so a candidate fetch was bounded
    /// only by `URLRequest.timeoutInterval` (20 s). That interval measures the
    /// gap between packets, not the transfer, and `URLSession.shared` leaves
    /// `timeoutIntervalForResource` at its 7-day default: a retailer that dribbles
    /// a multi-megabyte search page never trips either. One such page could
    /// outlast the whole run's 35 s budget, which the engine checks only BETWEEN
    /// candidates.
    func fetch(_ url: URL) async -> FetchedPage? {
        await TimeLimit.run(profile.perFetchTimeout) { await Self.uncappedFetch(url) } ?? nil
    }

    private static func uncappedFetch(_ url: URL) async -> FetchedPage? {
        do {
            let html = try await ArticleFetcher().fetchHTML(from: url)
            return FetchedPage(url: url, html: html, statusCode: 200)
        } catch let error as ArticleFetcher.FetchError {
            guard case let .badResponse(status) = error, let status else { return nil }
            return FetchedPage(url: url, html: "", statusCode: status)
        } catch {
            return nil
        }
    }

    /// Layer 2 — the keyless search that reaches retailers the bundled directory
    /// has never heard of.
    func webSearch(query: String) async -> [URL]? {
        await DuckDuckGoSearch.results(forQuery: query)
    }

    /// A candidate page through the SHARED pipeline, bounded.
    ///
    /// `ProductPageSuggestion.resolve` is classification, product eligibility,
    /// per-host price rules and the WKWebView render tier — a seller whose price
    /// only exists after client-side rendering is invisible to the regex parser
    /// and perfectly visible here. It can spend up to `IngestPipeline
    /// .processTimeout` (28 s) on one URL, which is most of the fan-out's whole
    /// budget — so it is raced against the profile's per-fetch allowance and,
    /// when it loses, the engine falls back to its own regex parser for that
    /// page rather than the run losing a candidate.
    func richResolve(_ url: URL) async -> ParsedProductPage? {
        await SellerComparisonRunner.withDeadline(profile.perFetchTimeout * 2) {
            guard let suggestion = await ProductPageSuggestion.resolve(url: url) else {
                return ParsedProductPage?.none
            }
            return Self.parsedPage(from: suggestion)
        } ?? nil
    }

    /// The render fallback, and the only reason this module is the one wiring
    /// the engine up: a search page whose results are drawn by JavaScript is
    /// empty markup to the lean extractor, and `LunaPriceCompare` may not link
    /// WebKit (it has to fit in the Safari appex).
    ///
    /// Readiness is "the rendered DOM yields a product link" rather than a fixed
    /// settle window, so a fast page returns fast and a slow one is still caught.
    func renderSearch(_ url: URL) async -> String? {
        await WebViewPriceRenderer.renderedSearchHTML(for: url) { html in
            !LeanProductPageParser.productLinks(
                inSearchHTML: html, baseURL: url, limit: 1).isEmpty
        }
    }

    /// Maps the pipeline's answer onto the engine's value type, folding the
    /// flattened brand into the keyed set so a name-tier match can still be
    /// brand-qualified.
    static func parsedPage(from suggestion: ProductPageSuggestion) -> ParsedProductPage? {
        let metadata = suggestion.metadata
        var identifiers = metadata.identifiers
        if identifiers.brand == nil { identifiers.brand = metadata.brand }
        return ParsedProductPage(
            url: suggestion.url,
            name: metadata.name,
            price: metadata.price.amount,
            currency: metadata.price.currency,
            imageURL: metadata.imageURL,
            identifiers: identifiers)
    }
}
