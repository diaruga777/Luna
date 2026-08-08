//
//  SellerFanOut.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

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

    public init(
        candidateLimit: Int, resultTarget: Int, concurrency: Int, productURLsPerCandidate: Int,
        totalBudget: TimeInterval, perFetchTimeout: TimeInterval,
        allowsNameOnlyMatch: Bool, usesWebSearchLayer: Bool
    ) {
        self.candidateLimit = candidateLimit
        self.resultTarget = resultTarget
        self.concurrency = concurrency
        self.productURLsPerCandidate = productURLsPerCandidate
        self.totalBudget = totalBudget
        self.perFetchTimeout = perFetchTimeout
        self.allowsNameOnlyMatch = allowsNameOnlyMatch
        self.usesWebSearchLayer = usesWebSearchLayer
    }

    /// Save-time in the app and the share/action extensions: a user is watching
    /// a spinner, so ~35s of wall clock is affordable and worth spending.
    public static let full = SellerFanOutProfile(
        candidateLimit: 12, resultTarget: 6, concurrency: 3, productURLsPerCandidate: 3,
        totalBudget: 35, perFetchTimeout: 10,
        allowsNameOnlyMatch: true, usesWebSearchLayer: true)

    /// The Safari extension: a page is already rendered and the native message
    /// must answer inside the appex's 20s budget, so everything shrinks and the
    /// weakest match tier is switched off — a wrong pill on someone's shopping
    /// page is worse than no pill.
    public static let constrained = SellerFanOutProfile(
        candidateLimit: 6, resultTarget: 3, concurrency: 2, productURLsPerCandidate: 2,
        totalBudget: 15, perFetchTimeout: 8,
        allowsNameOnlyMatch: false, usesWebSearchLayer: false)
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

/// What a run produced, plus enough about HOW it ran to be assertable: the
/// candidates it actually asked, in the order it asked them.
public struct SellerFanOutOutcome: Equatable, Sendable {
    public let results: [ComparableSellerResult]
    public let attemptedSellerIDs: [String]
    public let stopReason: SellerFanOutStopReason

    public init(
        results: [ComparableSellerResult], attemptedSellerIDs: [String],
        stopReason: SellerFanOutStopReason
    ) {
        self.results = results
        self.attemptedSellerIDs = attemptedSellerIDs
        self.stopReason = stopReason
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
    /// Overrides the region the source host / device locale would imply.
    public let regionOverride: String?

    public init(
        sourceURL: URL, productName: String, identifiers: ProductIdentifiers,
        categoryHints: [String] = [], excludedURLStrings: [String] = [],
        regionOverride: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.productName = productName
        self.identifiers = identifiers
        self.categoryHints = categoryHints
        self.excludedURLStrings = excludedURLStrings
        self.regionOverride = regionOverride
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

    private let directory: SellerDirectory
    private let profile: SellerFanOutProfile
    private let fetch: Fetch
    private let webSearch: WebSearch?
    private let richResolve: RichResolve?
    private let localeRegion: String?
    private let now: @Sendable () -> Date

    public init(
        directory: SellerDirectory,
        profile: SellerFanOutProfile,
        fetch: @escaping Fetch,
        webSearch: WebSearch? = nil,
        richResolve: RichResolve? = nil,
        localeRegion: String? = Locale.current.region?.identifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.profile = profile
        self.fetch = fetch
        self.webSearch = webSearch
        self.richResolve = richResolve
        self.localeRegion = localeRegion
        self.now = now
    }

    /// Shared mutable state for the two layers. An actor rather than a lock so
    /// the merge rule is applied at the moment each result LANDS — which is what
    /// makes "first completed wins" true rather than aspirational.
    private actor State {
        private var merger = ComparableResultMerger()
        private var attempted: [String] = []
        private var botWalledDomains: Set<String> = []
        let target: Int

        init(target: Int) { self.target = target }

        func recordAttempt(_ sellerID: String) { attempted.append(sellerID) }
        func markBotWalled(_ domain: String) { botWalledDomains.insert(domain) }
        func isBotWalled(_ domain: String) -> Bool { botWalledDomains.contains(domain) }
        func offer(_ result: ComparableSellerResult) { merger.offer(result) }
        var isSatisfied: Bool { merger.count >= target }
        var snapshot: (results: [ComparableSellerResult], attempted: [String]) {
            (merger.results, attempted)
        }
    }

    /// Finds other retailers selling `request`'s product.
    public func run(_ request: SellerFanOutRequest) async -> SellerFanOutOutcome {
        let start = now()
        let sourceHost = request.sourceURL.host ?? ""
        let region = request.regionOverride?.uppercased()
            ?? SellerCandidateSelector.resolveRegion(
                sourceHost: sourceHost, directory: directory, localeRegion: localeRegion)

        let excludedHosts = request.excludedURLStrings.compactMap { URL(string: $0)?.host }
        let candidates = SellerCandidateSelector.select(
            SellerCandidateSelector.Input(
                sourceHost: sourceHost,
                identifiers: request.identifiers,
                productName: request.productName,
                categoryHints: request.categoryHints,
                excludedHosts: excludedHosts,
                region: region,
                limit: profile.candidateLimit),
            in: directory)

        let excludedDomains = Set(
            ([sourceHost] + excludedHosts)
                .filter { !$0.isEmpty }
                .map(ProductIdentityMatching.registrableDomain))
        let state = State(target: profile.resultTarget)

        await withTaskGroup(of: Void.self) { layers in
            if profile.usesWebSearchLayer, let webSearch {
                layers.addTask {
                    await runWebSearchLayer(
                        request, search: webSearch, excludedDomains: excludedDomains,
                        state: state, start: start)
                }
            }
            layers.addTask {
                await runDirectoryLayer(
                    candidates.map(\.seller), request: request,
                    excludedDomains: excludedDomains, state: state, start: start)
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
            stopReason: stopReason)
    }

    // MARK: - Layer 1: the retailers' own searches

    private func runDirectoryLayer(
        _ candidates: [Seller], request: SellerFanOutRequest,
        excludedDomains: Set<String>, state: State, start: Date
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
                        seller, request: request, excludedDomains: excludedDomains, state: state)
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
    /// price. Any failure consumes the candidate — this never retries.
    private func runCandidate(
        _ seller: Seller, request: SellerFanOutRequest,
        excludedDomains: Set<String>, state: State
    ) async {
        let sellerDomain = ProductIdentityMatching.registrableDomain(seller.domain)
        guard !excludedDomains.contains(sellerDomain) else { return }
        let query = SellerCandidateSelector.query(
            for: seller, identifiers: request.identifiers, productName: request.productName)
        guard let searchURL = seller.searchRequestURL(forQuery: query),
              let searchPage = await fetch(searchURL) else { return }
        if BotWallDetection.isBotWall(statusCode: searchPage.statusCode, html: searchPage.html) {
            await state.markBotWalled(sellerDomain)
            return
        }
        guard (200..<300).contains(searchPage.statusCode) else { return }

        let links = LeanProductPageParser.productLinks(
            inSearchHTML: searchPage.html, baseURL: searchPage.url,
            limit: profile.productURLsPerCandidate)
        for link in links {
            if await state.isSatisfied { return }
            if await state.isBotWalled(sellerDomain) { return }
            guard let page = await resolve(link, state: state, domain: sellerDomain),
                  page.hasUsablePrice,
                  let price = page.price, let currency = page.currency,
                  let confidence = ComparisonMatching.verify(
                    source: request.identifiers, sourceName: request.productName,
                    candidate: page.identifiers, candidateName: page.name,
                    allowsNameOnlyMatch: profile.allowsNameOnlyMatch)
            else { continue }
            await state.offer(ComparableSellerResult(
                sellerID: seller.id, sellerName: seller.name, domain: sellerDomain,
                url: page.url, price: price, currency: currency, productName: page.name,
                identifiers: page.identifiers, imageURL: page.imageURL,
                confidence: confidence, source: .directory))
            return
        }
    }

    // MARK: - Layer 2: keyless web search

    /// Runs alongside Layer 1 rather than after it. It reaches retailers the
    /// directory has never heard of, and it sometimes lands on a page a
    /// retailer's own search buried — but it is a second opinion, not a
    /// replacement: the same verification and the same merge rule apply.
    private func runWebSearchLayer(
        _ request: SellerFanOutRequest, search: WebSearch,
        excludedDomains: Set<String>, state: State, start: Date
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
            guard let page = await resolve(url, state: state, domain: domain),
                  page.hasUsablePrice,
                  let price = page.price, let currency = page.currency,
                  let confidence = ComparisonMatching.verify(
                    source: request.identifiers, sourceName: request.productName,
                    candidate: page.identifiers, candidateName: page.name,
                    allowsNameOnlyMatch: profile.allowsNameOnlyMatch)
            else { continue }
            let known = directory.seller(forHost: host)
            await state.offer(ComparableSellerResult(
                sellerID: known?.id, sellerName: known?.name ?? domain, domain: domain,
                url: page.url, price: price, currency: currency, productName: page.name,
                identifiers: page.identifiers, imageURL: page.imageURL,
                confidence: confidence, source: .webSearch))
        }
    }

    /// The web-search query: raw GTIN digits when we have them (an exact
    /// lookup), else brand + product name.
    public func webSearchQuery(_ request: SellerFanOutRequest) -> String {
        if let gtin = request.identifiers.gtin, !gtin.isEmpty, gtin.allSatisfy(\.isNumber) {
            return gtin
        }
        let brand = request.identifiers.brand ?? ""
        let name = request.productName
        if !brand.isEmpty, !name.lowercased().contains(brand.lowercased()) {
            return "\(brand) \(name)".trimmingCharacters(in: .whitespaces)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shared

    private func resolve(_ url: URL, state: State, domain: String) async -> ParsedProductPage? {
        if let richResolve, let resolved = await richResolve(url) { return resolved }
        guard let page = await fetch(url) else { return nil }
        if BotWallDetection.isBotWall(statusCode: page.statusCode, html: page.html) {
            await state.markBotWalled(domain)
            return nil
        }
        guard (200..<300).contains(page.statusCode) else { return nil }
        return LeanProductPageParser.parse(html: page.html, url: page.url)
    }

    private func hasExpired(_ start: Date) -> Bool {
        now().timeIntervalSince(start) >= profile.totalBudget
    }
}
