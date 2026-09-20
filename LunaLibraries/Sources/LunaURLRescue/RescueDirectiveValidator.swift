//
//  RescueDirectiveValidator.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPaywallBypass
import LunaURLClassification

/// Turns an UNTRUSTED `RescuePlanResponse` (or article payload) into a validated
/// `RescueDirective`, or rejects it. Every guardrail lives here so the applier
/// only ever executes vetted directives. The digest is passed in so payload
/// claims (prices, article text) can be checked against real page evidence
/// (anti-hallucination).
public struct RescueDirectiveValidator {
    public init() {}

    public enum Rejection: Error, Equatable {
        case illegalKind(String)
        case badRerouteURL
        case rerouteHostNotAllowed
        case rerouteEqualsOriginal
        case noRerouteFields
        case badJavaScript
        case badMediaURL
        case articleNotAllowedOnDevice
        case articleTooShort
        case articleNotEvidenced
        case badPrice
        case priceNotEvidenced
        case badCurrency
        case emptyProductName
        case emptySearchQuery
        case searchNotAvailable
        case badInspectURL
        case inspectNotAvailable
        case giveUp
    }

    // MARK: - Plan validation

    /// What a validated plan tells the engine to do next.
    enum PlanResolution: Equatable {
        /// A directive ready to apply immediately.
        case directive(RescueDirective)
        /// The plan chose "article" and the model can produce it — the engine
        /// must make the follow-up article-payload call, then call
        /// `validateArticlePayload`.
        case needsArticlePayload
        /// The plan chose "search": the engine runs this query, filters the live
        /// results through `RescueSearchCandidates`, and asks the model to pick
        /// one. The model never supplies the URL.
        case needsSearch(query: String)
        /// The plan chose "inspect_url": the engine digests this page and asks
        /// once more. The ROUND CAP is the engine's, not the prompt's — this
        /// resolution is simply refused on the second round (`allowsIntermediate`).
        case needsInspection(url: URL)
    }

    /// Validates a plan for `request`. `digest` is the exact text the model saw.
    /// `supportsArticlePayload` gates the "article" kind.
    ///
    /// - Parameters:
    ///   - candidates: URLs the ENGINE offered the model in a search round. A
    ///     reroute to one of these skips the same-registrable-domain rule (and
    ///     only that rule) — the whole point of the search leg is finding the
    ///     content somewhere else, and the safety comes from the list being
    ///     built by the engine from live results rather than by the model.
    ///   - allowsIntermediate: false on a follow-up round, which is what makes
    ///     "one search round, one inspect round" structural rather than a
    ///     promise the prompt asks the model to keep.
    func validate(
        plan: RescuePlanResponse,
        request: RescueRequest,
        digest: String,
        supportsArticlePayload: Bool,
        candidates: Set<String> = [],
        allowsIntermediate: Bool = true
    ) -> Result<PlanResolution, Rejection> {
        let kind = plan.kind.lowercased()
        switch kind {
        case "give_up":
            return .failure(.giveUp)

        case "reroute":
            return validateReroute(plan, request: request, candidates: candidates).map { .directive($0) }

        case "webjs":
            return validateWebJS(plan, request: request).map { .directive($0) }

        case "open_in_browser":
            return .success(.directive(.openInBrowser))

        case "search":
            guard allowsIntermediate else { return .failure(.searchNotAvailable) }
            guard let query = plan.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
                  query.count >= 3, query.count <= 200 else { return .failure(.emptySearchQuery) }
            return .success(.needsSearch(query: query))

        case "inspect_url":
            guard allowsIntermediate else { return .failure(.inspectNotAvailable) }
            guard let raw = plan.rerouteURLString, let url = normalizedHTTPSURL(raw),
                  isAllowedRerouteHost(candidate: url, original: request.url)
            else { return .failure(.badInspectURL) }
            return .success(.needsInspection(url: url))

        case "media_url":
            return validateMediaURL(plan, digest: digest).map { .directive($0) }

        case "product":
            return validateProduct(plan, digest: digest).map { .directive($0) }

        case "article":
            guard supportsArticlePayload else {
                // On-device can't produce a full article — try to salvage a
                // reroute/JS from the same plan, else reject.
                if let salvaged = try? salvage(plan, request: request, illegal: kind).get() {
                    return .success(.directive(salvaged))
                }
                return .failure(.articleNotAllowedOnDevice)
            }
            return .success(.needsArticlePayload)

        default:
            return .failure(.illegalKind(kind))
        }
    }

    /// When a plan's kind cannot be served but it still carries usable
    /// reroute/JS fields, downgrade to that rather than discarding the attempt.
    private func salvage(_ plan: RescuePlanResponse, request: RescueRequest, illegal: String) -> Result<RescueDirective, Rejection> {
        if plan.javascript != nil {
            return validateWebJS(plan, request: request)
        }
        if plan.rerouteURLString != nil {
            return validateReroute(plan, request: request)
        }
        return .failure(.illegalKind(illegal))
    }

    // MARK: - Reroute

    private func validateReroute(
        _ plan: RescuePlanResponse, request: RescueRequest, candidates: Set<String> = []
    ) -> Result<RescueDirective, Rejection> {
        guard let raw = plan.rerouteURLString, let url = normalizedHTTPSURL(raw) else {
            return .failure(.badRerouteURL)
        }
        guard url.absoluteString != request.url.absoluteString else { return .failure(.rerouteEqualsOriginal) }
        guard candidates.contains(url.absoluteString)
                || isAllowedRerouteHost(candidate: url, original: request.url) else {
            return .failure(.rerouteHostNotAllowed)
        }
        let headers = validatedHeaders(plan)
        return .success(.reroute(RescueReroute(url: url, headers: headers)))
    }

    // MARK: - WebJS

    private func validateWebJS(_ plan: RescuePlanResponse, request: RescueRequest) -> Result<RescueDirective, Rejection> {
        guard let js = plan.javascript, !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.badJavaScript)
        }
        guard js.utf8.count <= Self.maxJavaScriptBytes else { return .failure(.badJavaScript) }

        // The page the WebView loads: a validated reroute URL if present, else the
        // original URL.
        var pageURL = request.url
        if let raw = plan.rerouteURLString, let url = normalizedHTTPSURL(raw),
           url.absoluteString != request.url.absoluteString,
           isAllowedRerouteHost(candidate: url, original: request.url) {
            pageURL = url
        }
        let resultKind = RescueScript.ResultKind(rawValue: (plan.scriptResultKind ?? "html").lowercased()) ?? .html
        let headers = validatedHeaders(plan)
        return .success(.webJS(RescueScript(pageURL: pageURL, headers: headers, javascript: js, resultKind: resultKind)))
    }

    // MARK: - Media URL

    private func validateMediaURL(_ plan: RescuePlanResponse, digest: String) -> Result<RescueDirective, Rejection> {
        guard let raw = plan.mediaURLString, let url = httpOrHTTPSURL(raw) else { return .failure(.badMediaURL) }
        // CDN hosts legitimately differ from the page domain, so evidence is either
        // a known media extension OR the URL appearing verbatim in the digest.
        let hasMediaExtension = Self.mediaExtensions.contains(url.pathExtension.lowercased())
        let evidenced = digest.contains(raw) || digest.contains(url.absoluteString)
        guard hasMediaExtension || evidenced else { return .failure(.badMediaURL) }
        return .success(.mediaURL(url))
    }

    // MARK: - Product

    private func validateProduct(_ plan: RescuePlanResponse, digest: String) -> Result<RescueDirective, Rejection> {
        guard let name = plan.productName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 200 else { return .failure(.emptyProductName) }
        guard let amountString = plan.productPriceAmount?.trimmingCharacters(in: .whitespacesAndNewlines),
              let amount = Decimal(string: amountString), amount >= 0 else { return .failure(.badPrice) }
        // The amount must be evidenced verbatim in the digest (or its comma-decimal
        // variant) — a fabricated price is worse than no tracker.
        let commaVariant = amountString.replacingOccurrences(of: ".", with: ",")
        guard digest.contains(amountString) || digest.contains(commaVariant) else {
            return .failure(.priceNotEvidenced)
        }
        guard let currency = plan.productCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            return .failure(.badCurrency)
        }
        let imageURL = plan.productImageURLString.flatMap { httpsOnlyURL($0) }
        let brand = plan.productBrand?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let info = ProductInfo(
            name: name, priceAmount: amount, priceCurrency: currency,
            imageURL: imageURL, brand: brand, productID: nil, sellers: [])
        return .success(.productPayload(info))
    }

    // MARK: - Article payload (validated after the PCC follow-up call)

    /// Validates the article reproduction against the digest. Relaxed length
    /// threshold vs `ArticleContent.readableBodyThreshold` (LLM output is
    /// pre-cleaned) plus an anti-hallucination spot-check: a majority of block
    /// prefixes must actually appear in the digest.
    func validateArticlePayload(
        _ response: RescueArticleResponse, digest: String
    ) -> Result<RescueDirective, Rejection> {
        let blocks: [ArticleContent.Block] = response.blocks.compactMap { dto in
            let kind = ArticleContent.Block.Kind(rawValue: dto.kind) ?? .paragraph
            let text = dto.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ArticleContent.Block(kind: kind, text: text, links: [])
        }
        let nonEmpty = blocks.filter { !$0.text.isEmpty }
        let totalText = nonEmpty.reduce(0) { $0 + $1.text.count }
        guard totalText >= Self.minArticleTextLength, nonEmpty.count >= Self.minArticleBlocks else {
            return .failure(.articleTooShort)
        }
        let normalizedDigest = Self.normalize(digest)
        let evidenced = nonEmpty.filter { block in
            let probe = Self.normalize(String(block.text.prefix(40)))
            return probe.count >= 8 && normalizedDigest.contains(probe)
        }
        guard Double(evidenced.count) / Double(nonEmpty.count) >= 0.5 else {
            return .failure(.articleNotEvidenced)
        }
        let content = ArticleContent(
            title: response.title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: response.author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            blocks: blocks)
        return .success(.articlePayload(content))
    }

    // MARK: - Headers

    /// Only the four closed fields survive; anything malformed is dropped (the
    /// directive is kept). UA comes ONLY from the token map — never a free string.
    func validatedHeaders(_ plan: RescuePlanResponse) -> RescueHeaders {
        var headers = RescueHeaders()
        headers.userAgent = plan.userAgentToken.flatMap { Self.userAgent(fromToken: $0) }
        if let raw = plan.refererString, let url = httpsOnlyURL(raw), raw.count <= 2048 {
            headers.referer = url
        }
        if let lang = plan.acceptLanguage,
           lang.range(of: "^[A-Za-z0-9,;=.\\- ]{1,64}$", options: .regularExpression) != nil {
            headers.acceptLanguage = lang
        }
        if let xff = plan.xForwardedFor, Self.isIPv4(xff) {
            headers.xForwardedFor = xff
        }
        return headers
    }

    static func userAgent(fromToken token: String) -> String? {
        switch token.lowercased() {
        case "iphone_safari": return ArticleFetcher.safariUserAgent
        case "desktop_safari": return Self.desktopSafariUserAgent
        case "googlebot": return CrawlerAgent.googlebotDesktop.userAgent
        case "facebook_crawler": return CrawlerAgent.facebookbot.userAgent
        case "google_inspection": return CrawlerAgent.googleInspectionTool.userAgent
        case "claude_user": return CrawlerAgent.claudeUser.userAgent
        case "openai_file_downloader": return CrawlerAgent.openAIFileDownloader.userAgent
        case "xai_image_fetch": return CrawlerAgent.xaiImageFetch.userAgent
        default: return nil
        }
    }

    static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Host policy

    /// A reroute host is allowed iff it shares the original's registrable domain
    /// (covers amp./m./print./embed variants — the real rescue cases) OR is one of
    /// the fixed mirrors LunaFetch already trusts. Anything broader would let an
    /// injected digest exfiltrate to an attacker host.
    func isAllowedRerouteHost(candidate: URL, original: URL) -> Bool {
        guard let candidateHost = candidate.host?.lowercased() else { return false }
        if Self.rerouteHostAllowlist.contains(candidateHost) { return true }
        guard let originalHost = original.host?.lowercased() else { return false }
        return registrableDomain(candidateHost) == registrableDomain(originalHost)
            && !registrableDomain(candidateHost).isEmpty
    }

    static let rerouteHostAllowlist: Set<String> = ["web.archive.org", "r.jina.ai"]

    /// eTLD+1 via last-two-labels, extended for a small set of well-known
    /// two-level public suffixes so `bbc.co.uk` ↔ `www.bbc.co.uk` matches.
    func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if Self.twoLevelSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static let twoLevelSuffixes: Set<String> = [
        "co.uk", "com.au", "co.jp", "co.nz", "co.in", "com.br", "co.za", "com.mx", "com.tr",
    ]

    // MARK: - URL helpers

    private func normalizedHTTPSURL(_ raw: String) -> URL? {
        guard raw.count <= 2048, let url = httpsOnlyURL(raw) else { return nil }
        return url
    }

    private func httpsOnlyURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private func httpOrHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), (0...255).contains(n), String(n) == part else { return false }
            return true
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Constants

    static let maxJavaScriptBytes = 8 * 1024
    static let minArticleTextLength = 600
    static let minArticleBlocks = 3
    static let mediaExtensions: Set<String> = [
        "mp4", "m3u8", "mov", "webm", "jpg", "jpeg", "png", "webp", "gif", "mp3", "m4a",
    ]
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
