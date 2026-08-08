//
//  SellerComparisonRunner.swift
//  LunaPriceUI
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare

/// The alternative-seller fan-out as the APP surfaces run it: the lean engine
/// (`LunaPriceCompare`) wired to real networking and to the whole shared ingest
/// pipeline.
///
/// The engine deliberately makes no request of its own, because the same
/// orchestration also has to run inside a Safari appex that can link almost
/// nothing (`claudedocs/price-comparison.md`). This type is the OTHER end of
/// that trade — the three closures the full profile is worth having:
///
/// - `fetch` goes through `ArticleFetcher`, so a candidate page is read with the
///   same single deterministic Safari UA and the same size ceiling as every
///   other fetch Luna makes. Its `badResponse(status:)` is what carries a bot
///   wall's status code back to the engine.
/// - `webSearch` is `DuckDuckGoSearch.results` — Layer 2, which reaches
///   retailers the bundled directory has never heard of.
/// - `richResolve` is `ProductPageSuggestion.resolve`, i.e. the entire
///   `IngestPipeline`: classification, product eligibility, per-host price
///   rules, and (in the app) the WKWebView render tier. A seller whose price
///   only exists after client-side rendering is invisible to the regex parser
///   and perfectly visible here.
///
/// **It is installed rather than called.** `ProductKindComposition.install()`
/// fills `installed`, so a process that did not compose the product kind has no
/// fan-out at all and every surface skips the comparison instead of guessing
/// (the same shape as `ActionButtonIntentSupport`'s media seams).
public enum SellerComparisonRunner {

    /// One fan-out run. Nil where the product kind is not composed.
    public typealias Run = @Sendable (SellerFanOutRequest) async -> SellerFanOutOutcome?

    /// The installed runner. Written ONLY by `ProductKindComposition.install()`
    /// in production; tests substitute a stub.
    public static var installed: Run?

    /// Installs the live fan-out. Idempotent.
    public static func install() {
        installed = { request in await liveRun(request) }
    }

    /// Runs the fan-out if one is installed. Nil means "no comparison ran" —
    /// which is not the same as "no other seller sells this", and callers must
    /// keep the distinction (nothing is seeded from a nil).
    public static func run(_ request: SellerFanOutRequest) async -> SellerFanOutOutcome? {
        guard let installed else { return nil }
        return await installed(request)
    }

    // MARK: - The live wiring

    /// The profile every app surface uses. The Safari appex's `.constrained`
    /// profile is B3's; nothing here may quietly become the other one.
    public static let profile: SellerFanOutProfile = .full

    /// Slack over the engine's own `totalBudget` before the OUTER cap fires.
    /// The engine checks its budget between candidates, so a single fetch that
    /// somehow outlives its `URLRequest` timeout could otherwise hold a save
    /// surface open indefinitely.
    public static let hardCapGrace: TimeInterval = 5

    private static func liveRun(_ request: SellerFanOutRequest) async -> SellerFanOutOutcome? {
        // Refuse the WHOLE run up front in a test process rather than letting a
        // dozen candidate fetches each be refused individually. `installed` is
        // filled at launch and the test host is the central Luna app, so any
        // test that drives a product save reaches this — see `LiveNetworkPolicy`.
        guard LiveNetworkPolicy.allows(
            request.sourceURL, context: "SellerComparisonRunner.liveRun") else { return nil }
        guard let directory = try? SellerDirectory.bundled() else { return nil }
        let fanOut = SellerFanOut(
            directory: directory,
            profile: profile,
            fetch: fetchPage,
            webSearch: { await DuckDuckGoSearch.results(forQuery: $0) },
            richResolve: richResolve)
        return await withDeadline(profile.totalBudget + hardCapGrace) {
            await fanOut.run(request)
        }
    }

    /// One page, through the app's ordinary fetcher.
    ///
    /// A refusal is a RESULT here, not an error: the engine's bot-wall rule is
    /// the reason candidates are over-provisioned, and it can only apply that
    /// rule if the status code survives the throw.
    static let fetchPage: SellerFanOut.Fetch = { url in
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

    /// A candidate page through the SHARED pipeline, bounded.
    ///
    /// `ProductPageSuggestion.resolve` can spend up to `IngestPipeline
    /// .processTimeout` (28 s) on one URL, which is most of the fan-out's whole
    /// budget — so it is raced against the profile's per-fetch allowance and,
    /// when it loses, the engine falls back to its own regex parser for that
    /// page rather than the run losing a candidate.
    static let richResolve: SellerFanOut.RichResolve = { url in
        await withDeadline(profile.perFetchTimeout * 2) {
            guard let suggestion = await ProductPageSuggestion.resolve(url: url) else {
                return ParsedProductPage?.none
            }
            return parsedPage(from: suggestion)
        } ?? nil
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

    /// Returns `operation`'s value, or nil at `seconds`. The loser is cancelled;
    /// unlike `CaptureIntentFastPath` this never throws, because every caller
    /// treats "no comparison" and "a comparison that found nothing" the same way
    /// at the surface — the save still lands.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
