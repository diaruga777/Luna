//
//  SellerFanOut.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels
import LunaPriceMetadata

// MARK: - Inputs and outputs

/// One fetched page: the bytes and the status the fan-out needs to tell a real
/// answer from a refusal. Injected — this module makes no requests itself, which
/// is what lets the same orchestration run behind `ArticleFetcher` in the app
/// and behind a bare `URLSession` in the Safari appex.
public struct FetchedPage: Equatable, Sendable {
    public let url: URL
    public let html: String
    public let statusCode: Int

    public init(url: URL, html: String, statusCode: Int) {
        self.url = url
        self.html = html
        self.statusCode = statusCode
    }
}

/// How hard the fan-out is allowed to try. Two profiles ship, and the difference
/// between them is where the code runs, not what it wants.
public struct SellerFanOutProfile: Equatable, Sendable {
    /// How many retailers may be ASKED. Over-provisioned relative to
    /// `resultTarget` because bot walls and stock misses are routine.
    public let candidateLimit: Int
    /// How many verified prices are enough — the run stops there.
    public let resultTarget: Int
    /// How many candidates are in flight at once.
    public let concurrency: Int
    /// How many search-result links one candidate may follow before giving up.
    public let productURLsPerCandidate: Int
    /// Wall-clock ceiling for the whole run. Checked between candidates, so a
    /// single hung fetch is the injected `fetch`'s problem to time out.
    public let totalBudget: TimeInterval
    /// Advisory per-fetch timeout for the injected fetcher to honour.
    public let perFetchTimeout: TimeInterval
    /// Whether a name+brand match (no shared identifier) may be accepted.
    public let allowsNameOnlyMatch: Bool
    /// Whether the Layer-2 web-search leg runs at all.
    public let usesWebSearchLayer: Bool
    /// Whether a retailer whose search results only exist after client-side
    /// rendering may be asked at all.
    ///
    /// Target's and Walmart's US search pages are JS shells: 123KB and 248KB of
    /// bundle with literally zero product links in the served markup. A context
    /// that cannot render (the Safari appex) should not spend one of six
    /// candidate slots and a full fetch discovering that again on every run —
    /// so it skips them, and a context that CAN render keeps them.
    public let skipsClientRenderedSearch: Bool
    /// How many client-rendered search pages the run may hand to an injected
    /// renderer. A render is an off-screen WebView and seconds of wall clock;
    /// this bounds the damage when several candidates need one.
    public let renderedSearchLimit: Int

    public init(
        candidateLimit: Int, resultTarget: Int, concurrency: Int, productURLsPerCandidate: Int,
        totalBudget: TimeInterval, perFetchTimeout: TimeInterval,
        allowsNameOnlyMatch: Bool, usesWebSearchLayer: Bool,
        skipsClientRenderedSearch: Bool = false, renderedSearchLimit: Int = 0
    ) {
        self.candidateLimit = candidateLimit
        self.resultTarget = resultTarget
        self.concurrency = concurrency
        self.productURLsPerCandidate = productURLsPerCandidate
        self.totalBudget = totalBudget
        self.perFetchTimeout = perFetchTimeout
        self.allowsNameOnlyMatch = allowsNameOnlyMatch
        self.usesWebSearchLayer = usesWebSearchLayer
        self.skipsClientRenderedSearch = skipsClientRenderedSearch
        self.renderedSearchLimit = renderedSearchLimit
    }

    /// Save-time in the app and the share/action extensions: a user is watching
    /// a spinner, so ~35s of wall clock is affordable and worth spending.
    ///
    /// `renderedSearchLimit` is 5, not 3: the AU seller directory alone adds
    /// four client-rendered majors on top of the pre-existing US ones
    /// (`appliancesonline-au`, `costco-au`, `betta-au` are Angular/Handlebars
    /// SPAs; `thegoodguys-au` already was) — a 12-candidate run with several
    /// JS shells among its top scorers needs more than 3 render slots to see
    /// past all of them in one run.
    public static let full = SellerFanOutProfile(
        candidateLimit: 12, resultTarget: 6, concurrency: 3, productURLsPerCandidate: 3,
        totalBudget: 35, perFetchTimeout: 10,
        allowsNameOnlyMatch: true, usesWebSearchLayer: true,
        skipsClientRenderedSearch: false, renderedSearchLimit: 5)

    /// The Safari extension: a page is already rendered and the native message
    /// must answer inside the appex's 20s budget, so everything shrinks and the
    /// name matching remains available for retailer-scoped identifiers such as
    /// an Amazon ASIN: those ids reliably establish that the source is one
    /// concrete product but cannot travel to another retailer. Sources with a
    /// GTIN/MPN still cannot use the ordinary name-only tier
    /// (`ComparisonMatching` enforces that invariant); only its stricter
    /// model-code evidence route remains available.
    public static let constrained = SellerFanOutProfile(
        candidateLimit: 6, resultTarget: 3, concurrency: 2, productURLsPerCandidate: 2,
        totalBudget: 15, perFetchTimeout: 8,
        allowsNameOnlyMatch: true, usesWebSearchLayer: false,
        skipsClientRenderedSearch: true, renderedSearchLimit: 0)
}

/// Where a comparison result came from.
public enum ComparableResultSource: String, Codable, Sendable {
    /// Layer 1 — the retailer's own search, from the bundled directory.
    case directory
    /// Layer 2 — a keyless web search that named a page on some retailer.
    case webSearch
}

/// One other retailer's price for the same product.
public struct ComparableSellerResult: Equatable, Sendable {
    /// Directory id, when the retailer is one we know. Nil for a web-search hit
    /// on a host the directory has never heard of.
    public let sellerID: String?
    /// Display name — the directory's, else the registrable domain.
    public let sellerName: String
    /// Registrable domain. THE merge key: one price per retailer, never two.
    public let domain: String
    public let url: URL
    public let price: Decimal
    public let currency: String
    public let productName: String
    public let identifiers: ProductIdentifiers
    public let imageURL: URL?
    public let confidence: SellerMatchConfidence
    public let source: ComparableResultSource

    public init(
        sellerID: String?, sellerName: String, domain: String, url: URL,
        price: Decimal, currency: String, productName: String,
        identifiers: ProductIdentifiers, imageURL: URL?,
        confidence: SellerMatchConfidence, source: ComparableResultSource
    ) {
        self.sellerID = sellerID
        self.sellerName = sellerName
        self.domain = domain
        self.url = url
        self.price = price
        self.currency = currency
        self.productName = productName
        self.identifiers = identifiers
        self.imageURL = imageURL
        self.confidence = confidence
        self.source = source
    }
}

/// Why the run stopped.
public enum SellerFanOutStopReason: String, Equatable, Sendable {
    case reachedTarget
    case exhausted
    case budgetExpired
}

/// Why one candidate produced no price. Not an error type — most of these are
/// the ordinary weather of asking a dozen retailers a question — but the whole
/// difference between a fan-out you can debug and one that just returns nothing.
public enum SellerFanOutRejection: String, Equatable, Sendable, Codable {
    /// The retailer's search page could not be fetched at all.
    case searchUnreachable
    /// The search answered with a bot wall (or a challenge served as a 200).
    case searchBotWalled
    /// The search answered with a non-2xx that was not a refusal.
    case searchBadStatus
    /// The search page was fetched and contained no product links Luna could
    /// recognize — usually a client-rendered shell.
    case noProductLinks
    /// The seller's search is known to be client-rendered and this profile
    /// cannot render.
    case clientRenderedSearchSkipped
    /// Every product link led to a page with no price, or none at all.
    case noPriceOnAnyLink
    /// Pages were priced, but only in a currency that is not the source
    /// market's — a price that cannot be compared is not a better price.
    case foreignCurrency
    /// Pages were priced, but none verified as the same product.
    case noVerifiedMatch
    /// The run stopped (target reached or budget spent) before this candidate
    /// finished.
    case runEndedFirst
}

/// One candidate retailer's whole story: what was asked, what came back, and
/// what became of every link followed.
public struct SellerFanOutAttempt: Equatable, Sendable {
    public let sellerID: String
    public let sellerName: String
    public let domain: String
    public let searchURL: URL?
    /// The query the search was actually made with — a GTIN or a product name.
    public let query: String
    public let statusCode: Int?
    /// Size of the fetched search page, which is how a JS shell announces itself.
    public let searchBytes: Int
    public let productLinks: [URL]
    /// Whether a rendered search page was used because the static one was empty.
    public let usedRenderedSearch: Bool
    public let rejection: SellerFanOutRejection?
    public let accepted: SellerMatchConfidence?

    public init(
        sellerID: String, sellerName: String, domain: String, searchURL: URL?, query: String,
        statusCode: Int?, searchBytes: Int, productLinks: [URL], usedRenderedSearch: Bool,
        rejection: SellerFanOutRejection?, accepted: SellerMatchConfidence?
    ) {
        self.sellerID = sellerID
        self.sellerName = sellerName
        self.domain = domain
        self.searchURL = searchURL
        self.query = query
        self.statusCode = statusCode
        self.searchBytes = searchBytes
        self.productLinks = productLinks
        self.usedRenderedSearch = usedRenderedSearch
        self.rejection = rejection
        self.accepted = accepted
    }

    /// A single log line. Written here rather than at the two logging call
    /// sites so the app's diagnostic log and the appex's console say the same
    /// thing about the same run.
    public var logLine: String {
        var parts = ["\(sellerID) q=\(query)"]
        if let statusCode { parts.append("http=\(statusCode)") }
        parts.append("bytes=\(searchBytes)")
        parts.append("links=\(productLinks.count)")
        if usedRenderedSearch { parts.append("rendered") }
        if let accepted { parts.append("ACCEPTED(\(accepted))") }
        if let rejection { parts.append("rejected(\(rejection.rawValue))") }
        return parts.joined(separator: " ")
    }
}

/// What a run produced, plus enough about HOW it ran to be assertable: the
/// candidates it actually asked, in the order it asked them, and why each one
/// that produced nothing produced nothing.
public struct SellerFanOutOutcome: Equatable, Sendable {
    public let results: [ComparableSellerResult]
    public let attemptedSellerIDs: [String]
    public let stopReason: SellerFanOutStopReason
    /// Per-candidate detail, in the order the candidates were launched.
    public let attempts: [SellerFanOutAttempt]
    /// Wall clock the run spent.
    public let elapsed: TimeInterval
    /// The region whose storefronts were searched.
    public let region: String

    public init(
        results: [ComparableSellerResult], attemptedSellerIDs: [String],
        stopReason: SellerFanOutStopReason,
        attempts: [SellerFanOutAttempt] = [], elapsed: TimeInterval = 0, region: String = ""
    ) {
        self.results = results
        self.attemptedSellerIDs = attemptedSellerIDs
        self.stopReason = stopReason
        self.attempts = attempts
        self.elapsed = elapsed
        self.region = region
    }

    /// Why `sellerID` produced nothing, if it was asked and produced nothing.
    public func rejection(for sellerID: String) -> SellerFanOutRejection? {
        attempts.first { $0.sellerID == sellerID }?.rejection
    }

    /// The whole run in a handful of lines, for a diagnostic log.
    public var logSummary: String {
        var lines = [
            "fan-out region=\(region) results=\(results.count) stop=\(stopReason.rawValue) "
                + "elapsed=\(String(format: "%.1f", elapsed))s",
        ]
        lines.append(contentsOf: attempts.map { "  " + $0.logLine })
        for result in results {
            lines.append("  = \(result.domain) \(result.currency) \(result.price) "
                + "[\(result.confidence)] \(result.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    /// One line, for a log that cannot afford the rest (the Safari appex).
    public var compactLogLine: String {
        "fanout region=\(region) asked=\(attempts.count) found=\(results.count) "
            + "stop=\(stopReason.rawValue) elapsed=\(String(format: "%.1f", elapsed))s"
    }
}

/// The product to find elsewhere.
public struct SellerFanOutRequest: Equatable, Sendable {
    public let sourceURL: URL
    public let productName: String
    public let identifiers: ProductIdentifiers
    /// Free-text category evidence from the source page.
    public let categoryHints: [String]
    /// Store URLs already attached (never re-found).
    public let excludedURLStrings: [String]
    /// Overrides the region the source host would imply.
    public let regionOverride: String?
    /// The currency the SOURCE page itself prices in (ISO 4217). This is the
    /// market's currency: a result priced in anything else is refused, and when
    /// the source host is unknown to the directory it also helps pick the
    /// region whose storefronts to search. Nil ⇒ the resolved region's own
    /// transaction currency stands in.
    public let sourceCurrency: String?

    public init(
        sourceURL: URL, productName: String, identifiers: ProductIdentifiers,
        categoryHints: [String] = [], excludedURLStrings: [String] = [],
        regionOverride: String? = nil, sourceCurrency: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.productName = productName
        self.identifiers = identifiers
        self.categoryHints = categoryHints
        self.excludedURLStrings = excludedURLStrings
        self.regionOverride = regionOverride
        self.sourceCurrency = sourceCurrency
    }
}

// MARK: - Merge rule

/// Folds results from both layers into one list, at most one per retailer.
///
/// The rule, in full: a result for a domain nobody has claimed is appended; a
/// result for a claimed domain SUPPLANTS the incumbent only when it is verified
/// more strongly (a GTIN match beating a name match), otherwise the
/// first-completed one stands. Concurrency makes "first completed" the only
/// stable notion of priority between the two layers, and confidence is the only
/// reason worth overriding it for.
public struct ComparableResultMerger: Equatable, Sendable {
    public private(set) var results: [ComparableSellerResult] = []

    public init() {}

    /// Offers a result; returns whether it changed the list.
    @discardableResult
    public mutating func offer(_ result: ComparableSellerResult) -> Bool {
        if let index = results.firstIndex(where: { $0.domain == result.domain }) {
            guard result.confidence > results[index].confidence else { return false }
            results[index] = result
            return true
        }
        results.append(result)
        return true
    }

    public var count: Int { results.count }
}

// MARK: - The orchestrator

/// Runs the alternative-seller fan-out: pick candidates, search each retailer's
/// own site, verify that what came back is the same product, and collect its
/// price — with a keyless web search running alongside as a second opinion.
///
/// Everything that touches the network is injected. That is not only for tests:
/// the app fetches through `ArticleFetcher` and can route candidate
/// verification through the whole shared ingest pipeline, while the Safari
/// appex has neither and must use `URLSession` plus this module's regex parser.
/// One orchestration, two very different environments.
public struct SellerFanOut {

    /// Fetch one URL. Returning nil means "no answer" (transport failure);
    /// returning a page with a blocked status is how a bot wall is reported.
    public typealias Fetch = @Sendable (URL) async -> FetchedPage?
    /// Layer 2: a keyless web search returning candidate result URLs in rank
    /// order (`DuckDuckGoSearch.results`). Nil disables the layer.
    public typealias WebSearch = @Sendable (String) async -> [URL]?
    /// Optional richer candidate resolution — the full profile routes pages
    /// through `ProductPageSuggestion.resolve` so a JS-rendered price still
    /// counts. Absent ⇒ the lean regex parser.
    public typealias RichResolve = @Sendable (URL) async -> ParsedProductPage?
    /// Called the moment a verified seller ENTERS the merged list, so a surface
    /// can show it before the run ends. A result that is later supplanted by a
    /// better-verified one for the same retailer is reported again — the
    /// callback is "this is the current answer for this domain", not "this is
    /// final".
    public typealias OnResult = @Sendable (ComparableSellerResult) async -> Void
    /// Renders a search page's JS and returns the rendered markup. Injected
    /// exactly like everything else that touches the network — the engine may
    /// not link WebKit, and the Safari appex could not use it if it did.
    public typealias RenderSearch = @Sendable (URL) async -> String?
    /// Called as each candidate finishes. The run's own summary arrives through
    /// the returned `SellerFanOutOutcome`; this is what makes a run watchable
    /// while it is still going.
    public typealias OnAttempt = @Sendable (SellerFanOutAttempt) async -> Void

    private let directory: SellerDirectory
    private let profile: SellerFanOutProfile
    private let fetch: Fetch
    private let webSearch: WebSearch?
    private let richResolve: RichResolve?
    private let renderSearch: RenderSearch?
    private let now: @Sendable () -> Date
    private let onResult: OnResult?
    private let onAttempt: OnAttempt?

    public init(
        directory: SellerDirectory,
        profile: SellerFanOutProfile,
        fetch: @escaping Fetch,
        webSearch: WebSearch? = nil,
        richResolve: RichResolve? = nil,
        renderSearch: RenderSearch? = nil,
        onResult: OnResult? = nil,
        onAttempt: OnAttempt? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.profile = profile
        self.fetch = fetch
        self.webSearch = webSearch
        self.richResolve = richResolve
        self.renderSearch = renderSearch
        self.now = now
        self.onResult = onResult
        self.onAttempt = onAttempt
    }

    /// Shared mutable state for the two layers. An actor rather than a lock so
    /// the merge rule is applied at the moment each result LANDS — which is what
    /// makes "first completed wins" true rather than aspirational.
    private actor State {
        private var merger = ComparableResultMerger()
        private var attempted: [String] = []
        private var attempts: [SellerFanOutAttempt] = []
        private var botWalledDomains: Set<String> = []
        private var rendersUsed = 0
        let target: Int
        let renderBudget: Int

        init(target: Int, renderBudget: Int) {
            self.target = target
            self.renderBudget = renderBudget
        }

        func recordAttempt(_ sellerID: String) { attempted.append(sellerID) }
        func record(_ attempt: SellerFanOutAttempt) { attempts.append(attempt) }
        func markBotWalled(_ domain: String) { botWalledDomains.insert(domain) }
        func isBotWalled(_ domain: String) -> Bool { botWalledDomains.contains(domain) }
        /// Claims one of the run's render slots, or refuses. Claimed inside the
        /// actor so three concurrent candidates cannot each decide they are the
        /// first.
        func claimRenderSlot() -> Bool {
            guard rendersUsed < renderBudget else { return false }
            rendersUsed += 1
            return true
        }
        /// Whether the offer changed the merged list — the signal a streaming
        /// surface needs, and the reason the merge rule is applied HERE rather
        /// than after the run.
        func offer(_ result: ComparableSellerResult) -> Bool { merger.offer(result) }
        var isSatisfied: Bool { merger.count >= target }
        var snapshot: (results: [ComparableSellerResult], attempted: [String],
                       attempts: [SellerFanOutAttempt]) {
            (merger.results, attempted, attempts)
        }
    }

    /// Finds other retailers selling `request`'s product.
    public func run(_ request: SellerFanOutRequest) async -> SellerFanOutOutcome {
        let start = now()
        let sourceHost = request.sourceURL.host ?? ""
        let region = request.regionOverride?.uppercased()
            ?? SellerCandidateSelector.resolveRegion(
                sourceHost: sourceHost, sourceCurrency: request.sourceCurrency,
                directory: directory)
        // The one currency a result may be priced in: the source page's own
        // declaration first (the store the user is looking at names its own
        // market), else the resolved region's transaction currency. A candidate
        // priced in anything else — or in nothing establishable — is refused,
        // because there is no FX source anywhere in Luna and a price that
        // cannot be compared is not a better price.
        let requiredCurrency = request.sourceCurrency?.uppercased()
            ?? SellerDirectory.currencies[region]

        let excludedHosts = request.excludedURLStrings.compactMap { URL(string: $0)?.host }
        let candidates = SellerCandidateSelector.select(
            SellerCandidateSelector.Input(
                sourceHost: sourceHost,
                identifiers: request.identifiers,
                productName: request.productName,
                categoryHints: request.categoryHints,
                excludedHosts: excludedHosts,
                region: region,
                limit: profile.candidateLimit,
                excludesClientRenderedSearch: profile.skipsClientRenderedSearch),
            in: directory)

        let excludedDomains = Set(
            ([sourceHost] + excludedHosts)
                .filter { !$0.isEmpty }
                .map(ProductIdentityMatching.registrableDomain))
        let state = State(
            target: profile.resultTarget,
            renderBudget: renderSearch == nil ? 0 : profile.renderedSearchLimit)

        await withTaskGroup(of: Void.self) { layers in
            if profile.usesWebSearchLayer, let webSearch {
                layers.addTask {
                    await runWebSearchLayer(
                        request, search: webSearch, excludedDomains: excludedDomains,
                        requiredCurrency: requiredCurrency, state: state, start: start)
                }
            }
            layers.addTask {
                await runDirectoryLayer(
                    candidates.map(\.seller), request: request,
                    excludedDomains: excludedDomains, requiredCurrency: requiredCurrency,
                    state: state, start: start)
            }
            await layers.waitForAll()
        }

        let snapshot = await state.snapshot
        let stopReason: SellerFanOutStopReason
        if snapshot.results.count >= profile.resultTarget {
            stopReason = .reachedTarget
        } else if hasExpired(start) {
            stopReason = .budgetExpired
        } else {
            stopReason = .exhausted
        }
        return SellerFanOutOutcome(
            results: snapshot.results,
            attemptedSellerIDs: snapshot.attempted,
            stopReason: stopReason,
            attempts: snapshot.attempts,
            elapsed: now().timeIntervalSince(start),
            region: region)
    }

    // MARK: - Layer 1: the retailers' own searches

    private func runDirectoryLayer(
        _ candidates: [Seller], request: SellerFanOutRequest,
        excludedDomains: Set<String>, requiredCurrency: String?, state: State, start: Date
    ) async {
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            func launchNext() async -> Bool {
                guard next < candidates.count else { return false }
                let seller = candidates[next]
                next += 1
                await state.recordAttempt(seller.id)
                group.addTask {
                    await runCandidate(
                        seller, request: request, excludedDomains: excludedDomains,
                        requiredCurrency: requiredCurrency, state: state, start: start)
                }
                return true
            }

            for _ in 0..<max(1, profile.concurrency) {
                if await !launchNext() { break }
            }
            while await group.next() != nil {
                if await state.isSatisfied { break }
                if hasExpired(start) { break }
                if await !launchNext() { break }
            }
            group.cancelAll()
        }
    }

    /// One retailer: search its site, follow the most plausible product links,
    /// and keep the first page that verifies as the same product AND has a
    /// price. Any failure consumes the candidate — this never retries a FAILURE,
    /// though it may ask the same shop a second QUESTION (see
    /// `SellerCandidateSelector.queries`).
    private func runCandidate(
        _ seller: Seller, request: SellerFanOutRequest,
        excludedDomains: Set<String>, requiredCurrency: String?, state: State, start: Date
    ) async {
        let sellerDomain = ProductIdentityMatching.registrableDomain(seller.domain)
        let record = AttemptRecord(seller: seller, domain: sellerDomain)
        // The record is reported exactly once, however the body exits — which is
        // why the body is a separate method: a `defer` cannot await, and the
        // report has to reach an actor.
        await runCandidateBody(
            seller, request: request, sellerDomain: sellerDomain,
            excludedDomains: excludedDomains, requiredCurrency: requiredCurrency,
            state: state, start: start, record: record)
        let attempt = record.attempt
        await state.record(attempt)
        await onAttempt?(attempt)
    }

    /// One retailer, across every question it is asked (identifier then
    /// name). A query whose links all fail to verify no longer ends the
    /// candidate outright — the NEXT query, if any, gets a chance too, which
    /// is what stops a junk-yielding GTIN query (a retailer's own nav/menu
    /// link that happens to match the shared URL patterns) from silently
    /// discarding the name query that would have found the real product. The
    /// total number of pages FETCHED per candidate is still capped at
    /// `profile.productURLsPerCandidate` — the same budget one query used to
    /// get alone — so falling through cannot double the run's cost.
    private func runCandidateBody(
        _ seller: Seller, request: SellerFanOutRequest, sellerDomain: String,
        excludedDomains: Set<String>, requiredCurrency: String?, state: State, start: Date,
        record: AttemptRecord
    ) async {
        guard !excludedDomains.contains(sellerDomain) else {
            record.reject(.runEndedFirst)
            return
        }
        if seller.searchRequiresRendering, profile.skipsClientRenderedSearch {
            record.reject(.clientRenderedSearchSkipped)
            return
        }

        let queries = SellerCandidateSelector.queries(
            for: seller, identifiers: request.identifiers, productName: request.productName)
        let gtinDigits = GTINForms.digits(request.identifiers.gtin)
        let preferred = GTINForms.variants(of: request.identifiers.gtin)

        var allLinks: [URL] = []
        var sawAnyLinks = false
        var sawPrice = false
        var sawForeignPrice = false
        var pendingRejection: SellerFanOutRejection = .noProductLinks

        queryLoop: for query in queries {
            if await state.isSatisfied || hasExpired(start) {
                record.reject(.runEndedFirst)
                return
            }
            let remainingBudget = profile.productURLsPerCandidate - allLinks.count
            guard remainingBudget > 0 else { break }
            record.query = query
            guard let searchURL = seller.searchRequestURL(forQuery: query) else { continue }
            record.searchURL = searchURL
            guard let searchPage = await fetch(searchURL) else {
                pendingRejection = .searchUnreachable
                continue
            }
            record.statusCode = searchPage.statusCode
            record.searchBytes = searchPage.html.count

            // A blocked STATUS is a hard refusal — nothing to render past.
            if BotWallDetection.blockedStatusCodes.contains(searchPage.statusCode) {
                await state.markBotWalled(sellerDomain)
                record.reject(.searchBotWalled)
                return
            }
            guard (200..<300).contains(searchPage.statusCode) else {
                pendingRejection = .searchBadStatus
                continue
            }

            var html = searchPage.html
            var renderedThisQuery = false
            if BotWallDetection.isBotWall(statusCode: 200, html: html) {
                // A markup-only challenge under an ordinary 200 (a genuinely
                // BLOCKED status already returned above) — some retailers
                // serve a soft interstitial a render can see past, and a
                // context that can render deserves the same one chance it
                // gets for a structurally-empty page below.
                guard let renderSearch, await state.claimRenderSlot(),
                      let rendered = await renderSearch(searchURL)
                else {
                    await state.markBotWalled(sellerDomain)
                    record.reject(.searchBotWalled)
                    return
                }
                renderedThisQuery = true
                record.usedRenderedSearch = true
                record.searchBytes = rendered.count
                if BotWallDetection.isBotWall(statusCode: 200, html: rendered) {
                    await state.markBotWalled(sellerDomain)
                    record.reject(.searchBotWalled)
                    return
                }
                html = rendered
            }

            var links = LeanProductPageParser.productLinks(
                inSearchHTML: html, baseURL: searchPage.url,
                limit: remainingBudget, preferring: preferred, query: query)

            // Nothing in the served markup. On a retailer whose results are drawn
            // by JS this is not a miss, it is the entire page — so a context that
            // can render is given one chance to see what a browser would have seen
            // (unless it already rendered above for the challenge check).
            if links.isEmpty, !renderedThisQuery, let renderSearch, await state.claimRenderSlot(),
               let rendered = await renderSearch(searchURL) {
                record.usedRenderedSearch = true
                record.searchBytes = rendered.count
                links = LeanProductPageParser.productLinks(
                    inSearchHTML: rendered, baseURL: searchPage.url,
                    limit: remainingBudget, preferring: preferred, query: query)
            }

            guard !links.isEmpty else {
                pendingRejection = .noProductLinks
                continue
            }
            sawAnyLinks = true
            // The identifier question is the one that makes containment on
            // the answer meaningful. Recorded per QUERY, not per candidate.
            let reachedByGTINSearch = gtinDigits.map { !$0.isEmpty && query == $0 } ?? false

            for link in links {
                guard allLinks.count < profile.productURLsPerCandidate else { break queryLoop }
                allLinks.append(link)
                if await state.isSatisfied || hasExpired(start) {
                    record.productLinks = allLinks
                    record.reject(sawPrice ? .noVerifiedMatch : .runEndedFirst)
                    return
                }
                if await state.isBotWalled(sellerDomain) {
                    record.productLinks = allLinks
                    record.reject(.searchBotWalled)
                    return
                }
                guard let resolved = await resolve(
                    link, state: state, domain: sellerDomain, currencyHint: seller.regionCurrency)
                else { continue }
                let page = resolved.page
                guard page.hasUsablePrice, let price = page.price, let currency = page.currency
                else { continue }
                // The market's currency is a refusal, not a preference: a page
                // priced in anything else cannot be compared to the source page
                // (no FX source), so it must never become a "better price".
                if let requiredCurrency, currency.uppercased() != requiredCurrency {
                    sawForeignPrice = true
                    continue
                }
                sawPrice = true
                guard let confidence = await verify(
                    resolved, request: request, reachedByGTINSearch: reachedByGTINSearch)
                else { continue }
                let result = ComparableSellerResult(
                    sellerID: seller.id, sellerName: seller.name, domain: sellerDomain,
                    url: page.url, price: price, currency: currency, productName: page.name,
                    identifiers: page.identifiers, imageURL: page.imageURL,
                    confidence: confidence, source: .directory)
                record.productLinks = allLinks
                record.accept(confidence)
                if await state.offer(result) { await onResult?(result) }
                return
            }
            // This query's links didn't pan out; the next query (identifier
            // then name), if any and if budget remains, gets a chance too.
        }

        record.productLinks = allLinks
        guard sawAnyLinks else {
            record.reject(pendingRejection)
            return
        }
        if sawPrice {
            record.reject(.noVerifiedMatch)
        } else {
            record.reject(sawForeignPrice ? .foreignCurrency : .noPriceOnAnyLink)
        }
    }

    /// Verifies a resolved candidate, fetching the page's markup if — and only
    /// if — that is the one thing still standing between it and acceptance.
    ///
    /// The rich resolver (the app's full ingest pipeline) hands back a parse and
    /// no HTML, which is exactly the case where the `.gtinInPage` tier has
    /// nothing to read. Rather than fetching every page twice, the run asks
    /// whether the evidence would decide the question and only then goes and
    /// gets it.
    private func verify(
        _ resolved: Resolved, request: SellerFanOutRequest, reachedByGTINSearch: Bool
    ) async -> SellerMatchConfidence? {
        let page = resolved.page
        var evidence = CandidatePageEvidence(
            reachedByGTINSearch: reachedByGTINSearch, html: resolved.html, url: page.url)
        if let confidence = ComparisonMatching.verify(
            source: request.identifiers, sourceName: request.productName,
            candidate: page.identifiers, candidateName: page.name,
            evidence: evidence, allowsNameOnlyMatch: profile.allowsNameOnlyMatch) {
            return confidence
        }
        guard resolved.html == nil, reachedByGTINSearch,
              ComparisonMatching.requiresPageEvidence(
                source: request.identifiers, sourceName: request.productName,
                candidate: page.identifiers, candidateName: page.name),
              let refetched = await fetch(page.url), (200..<300).contains(refetched.statusCode)
        else { return nil }
        evidence = CandidatePageEvidence(
            reachedByGTINSearch: true, html: refetched.html, url: page.url)
        return ComparisonMatching.verify(
            source: request.identifiers, sourceName: request.productName,
            candidate: page.identifiers, candidateName: page.name,
            evidence: evidence, allowsNameOnlyMatch: profile.allowsNameOnlyMatch)
    }

    /// Accumulates one candidate's story and hands it to the state + the
    /// diagnostics callback exactly once, however the candidate exits.
    private final class AttemptRecord {
        private let seller: Seller
        private let domain: String
        var searchURL: URL?
        var query: String = ""
        var statusCode: Int?
        var searchBytes = 0
        var productLinks: [URL] = []
        var usedRenderedSearch = false
        private var rejection: SellerFanOutRejection?
        private var accepted: SellerMatchConfidence?
        init(seller: Seller, domain: String) {
            self.seller = seller
            self.domain = domain
        }

        func reject(_ reason: SellerFanOutRejection?) { rejection = reason }
        func accept(_ confidence: SellerMatchConfidence) {
            accepted = confidence
            rejection = nil
        }

        var attempt: SellerFanOutAttempt {
            SellerFanOutAttempt(
                sellerID: seller.id, sellerName: seller.name, domain: domain,
                searchURL: searchURL, query: query, statusCode: statusCode,
                searchBytes: searchBytes, productLinks: productLinks,
                usedRenderedSearch: usedRenderedSearch,
                rejection: rejection, accepted: accepted)
        }
    }

    // MARK: - Layer 2: keyless web search

    /// Runs alongside Layer 1 rather than after it. It reaches retailers the
    /// directory has never heard of, and it sometimes lands on a page a
    /// retailer's own search buried — but it is a second opinion, not a
    /// replacement: the same verification and the same merge rule apply.
    private func runWebSearchLayer(
        _ request: SellerFanOutRequest, search: WebSearch,
        excludedDomains: Set<String>, requiredCurrency: String?, state: State, start: Date
    ) async {
        let query = webSearchQuery(request)
        guard !query.isEmpty, let urls = await search(query) else { return }
        var seenDomains: Set<String> = []
        var examined = 0
        for url in urls {
            if await state.isSatisfied { return }
            if hasExpired(start) { return }
            guard examined < profile.resultTarget * 2 else { return }
            guard let host = url.host else { continue }
            let domain = ProductIdentityMatching.registrableDomain(host)
            guard !excludedDomains.contains(domain), seenDomains.insert(domain).inserted,
                  !LeanProductURLRules.isMultiProductListing(url)
            else { continue }
            examined += 1
            guard let resolved = await resolve(url, state: state, domain: domain) else { continue }
            let page = resolved.page
            guard page.hasUsablePrice,
                  let price = page.price, let currency = page.currency,
                  // A web search reaches storefronts in ANY country — this
                  // layer is where a foreign-market price most easily sneaks
                  // in, so the market-currency refusal matters most here.
                  requiredCurrency == nil || currency.uppercased() == requiredCurrency,
                  // A web-search hit was NOT reached by asking this retailer for
                  // the identifier, so the `.gtinInPage` tier does not apply:
                  // a search engine's result page can name any number.
                  let confidence = ComparisonMatching.verify(
                    source: request.identifiers, sourceName: request.productName,
                    candidate: page.identifiers, candidateName: page.name,
                    allowsNameOnlyMatch: profile.allowsNameOnlyMatch)
            else { continue }
            let known = directory.seller(forHost: host)
            let result = ComparableSellerResult(
                sellerID: known?.id, sellerName: known?.name ?? domain, domain: domain,
                url: page.url, price: price, currency: currency, productName: page.name,
                identifiers: page.identifiers, imageURL: page.imageURL,
                confidence: confidence, source: .webSearch)
            if await state.offer(result) { await onResult?(result) }
        }
    }

    /// The web-search query: raw GTIN digits when we have them (an exact
    /// lookup), else brand + product name.
    public func webSearchQuery(_ request: SellerFanOutRequest) -> String {
        if let gtin = request.identifiers.gtin, !gtin.isEmpty, gtin.allSatisfy(\.isNumber) {
            return gtin
        }
        let brand = request.identifiers.brand ?? ""
        // The CLEANED name, same as the retailer searches: a web search for
        // "… Chrome: Toasters: Amazon.com.au" buries the product under the
        // storefront's own chrome.
        let name = ProductTitleHygiene.cleaned(request.productName)
        if !brand.isEmpty, !name.lowercased().contains(brand.lowercased()) {
            return "\(brand) \(name)".trimmingCharacters(in: .whitespaces)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shared

    /// A candidate page, plus its raw markup when the resolution path still has
    /// it. The rich resolver returns a parse and nothing else, which is why
    /// `html` is optional rather than a field on `ParsedProductPage`.
    private struct Resolved {
        let page: ParsedProductPage
        let html: String?
    }

    private func resolve(
        _ url: URL, state: State, domain: String, currencyHint: String? = nil
    ) async -> Resolved? {
        if let richResolve, let resolved = await richResolve(url) {
            return Resolved(page: resolved, html: nil)
        }
        guard let page = await fetch(url) else { return nil }
        if BotWallDetection.isBotWall(statusCode: page.statusCode, html: page.html) {
            await state.markBotWalled(domain)
            return nil
        }
        guard (200..<300).contains(page.statusCode) else { return nil }
        guard let parsed = LeanProductPageParser.parse(
            html: page.html, url: page.url, currencyHint: currencyHint) else { return nil }
        return Resolved(page: parsed, html: page.html)
    }

    private func hasExpired(_ start: Date) -> Bool {
        now().timeIntervalSince(start) >= profile.totalBudget
    }
}
