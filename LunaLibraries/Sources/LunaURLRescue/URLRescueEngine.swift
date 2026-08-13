//
//  URLRescueEngine.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaStorage
import LunaURLClassification

/// The URL-rescue orchestrator. When primary ingestion fails, it asks Apple's
/// FoundationModels (on-device baseline, Private Cloud Compute opportunistically)
/// for a directive, validates it, and applies it by re-entering the RAW pipeline
/// at most once. NEVER throws — every failure folds into a `RescueOutcome`.
///
/// The "no second LLM pass" guarantee is structural: the applier's re-entry
/// witness defaults to `RawIngestPipelineReentry`, which calls the raw
/// `IngestPipeline.processResolved`, so a rescue-triggered re-run can never
/// recurse into rescue.
///
/// Model rounds are bounded in CODE, never by asking the prompt to behave: the
/// plan call gets one digest-halving retry on overflow, and at most ONE
/// intermediate round (a search selection or a single `inspect_url` look) may
/// follow it, because the follow-up call is validated with
/// `allowsIntermediate: false`.
public final class URLRescueEngine {
    /// Hard ceiling on a whole rescue attempt.
    public static let totalBudget: TimeInterval = 90
    /// Per model round-trip.
    public static let llmCallTimeout: TimeInterval = 30
    /// The slice of the character budget the failure-evidence excerpt takes when
    /// there IS one. The digest keeps the rest, and the overflow retry halves the
    /// whole budget, so both shrink together.
    static let evidenceShare = 0.15

    private let session: RescueModelSession
    private let digestBuilder: RescueDigestBuilder
    private let validator: RescueDirectiveValidator
    private let applier: RescueDirectiveApplier
    private let ruleStore: RescueRuleStoring
    private let fetcher: HTMLFetching
    private let traceStore: RescueTraceStoring
    private let stats: RescueStatsStore
    private let search: any RescueSearching
    private let now: () -> Date

    public init(
        session: RescueModelSession = RescueModelSessionFactory.makeDefault(),
        scriptRunner: RescueScriptRunning = RescueWebScriptRunner(),
        ruleStore: RescueRuleStoring = RescueRuleStore.shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        mediaResolver: SocialMediaResolving = NoMediaResolver(),
        traceStore: RescueTraceStoring = SaveDiagnosticsStore.shared,
        stats: RescueStatsStore = .shared,
        search: any RescueSearching = DuckDuckGoRescueSearch(),
        runPipeline: any RescuePipelineReentering = RawIngestPipelineReentry(),
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.digestBuilder = RescueDigestBuilder()
        self.validator = RescueDirectiveValidator()
        self.applier = RescueDirectiveApplier(
            fetcher: fetcher, scriptRunner: scriptRunner,
            mediaResolver: mediaResolver, runPipeline: runPipeline)
        self.ruleStore = ruleStore
        self.fetcher = fetcher
        self.traceStore = traceStore
        self.stats = stats
        self.search = search
        self.now = now
    }

    /// True when a model is usable right now — the cheap gate the integration
    /// layer checks before scheduling a rescue.
    public var isAvailable: Bool { session.isAvailable }

    /// Attempts to rescue a failed save. Never throws.
    ///
    /// `onProgress` is called as each internal stage begins, on whatever executor
    /// the engine happens to be running on — the UI-facing observer
    /// (`URLRescueCoordinator`) is responsible for hopping to the main queue. It
    /// always ends with `.finished`, whatever the outcome, so a progress bar can
    /// close itself out without also inspecting the return value.
    public func rescue(
        _ request: RescueRequest,
        onProgress: @escaping (RescueStage) -> Void = { _ in }
    ) async -> RescueOutcome {
        let host = request.url.host ?? "?"
        // Read the trace BEFORE the first log line. This engine appends its own
        // decisions to the same file, so reading it later would feed the rescue
        // its own "start" line back as evidence of what already failed — the
        // model's log excerpt has to be the state of the world before this
        // attempt, not a mirror.
        let trace = request.itemID.flatMap { traceStore.contents(for: $0) }
        log("start host=\(host) hint=\(request.hintKey)", request)
        onProgress(.queued)
        stats.recordAttempt()

        // Bound the whole attempt.
        let outcome = await withTimeout(seconds: Self.totalBudget, fallback: .failed(.timedOut)) {
            await self.runRescue(request, host: host, trace: trace, onProgress: onProgress)
        }
        onProgress(.finished)
        recordStats(for: outcome)
        return outcome
    }

    private func runRescue(
        _ request: RescueRequest, host: String, trace: String?,
        onProgress: @escaping (RescueStage) -> Void
    ) async -> RescueOutcome {
        // This engine outlives every attempt, so the model session must not:
        // start from a clean one rather than inheriting the previous rescue's
        // transcript (or a response our own timeout cancelled mid-flight).
        session.beginAttempt()

        // (1) Learned rule — deterministic, before any LLM.
        if let cached = ruleStore.rule(forHost: host, hint: request.hint) {
            log("cachedRule hit host=\(host)", request)
            if let directive = directiveFromRule(cached, request: request) {
                onProgress(.replayingRule)
                let outcome = await applier.apply(directive, request: request)
                if outcome.succeeded {
                    ruleStore.recordSuccess(cached)
                    stats.recordCachedRuleHit()
                    log("cachedRule success host=\(host)", request)
                    return Self.relabel(outcome, as: .cachedRule)
                }
                ruleStore.recordFailure(forHost: host, hint: request.hint)
                log("cachedRule fail host=\(host)", request)
            }
        }

        // (2) The deterministic browser fast-path, BEFORE the model.
        //
        // A 401/403/429 is the server saying "not you" to a background fetch;
        // `SaveFailureReason.browserMayRecover` documents the measurement that a
        // real WKWebView session routinely gets a 200 for the very same page. The
        // model has nothing to read in that case (the fetch was refused, so there
        // is no HTML), and asking it costs 30 seconds to arrive at the answer we
        // already have. Ordering it ahead of the availability gate is deliberate
        // too: on a device with no Apple Intelligence at all this is still the
        // right move.
        if request.failureReason?.browserMayRecover == true, !request.browserHandoffTried {
            log("browserFastPath host=\(host) reason=\(Self.reasonToken(request.failureReason))", request)
            return .needsBrowser
        }

        // (3) Model availability.
        guard session.isAvailable else { log("unavailable host=\(host)", request); return .unavailable }

        // (4) HTML → digest (best-effort refetch when the caller didn't hand us HTML).
        //
        // An empty result no longer ends the rescue. Reroute, search and the
        // browser handoff need no page HTML, and the pages most in need of rescue
        // — bot-walled, paywalled — are exactly the ones whose refetch fails, so
        // dying here meant never asking about the cases that matter most.
        let html: String?
        var fetchFailure: String?
        if let prefetched = request.fetchedHTML {
            html = prefetched
        } else {
            onProgress(.fetching)
            do {
                html = try await fetcher.fetchHTML(from: request.url)
            } catch {
                html = nil
                fetchFailure = Self.fetchFailureToken(error)
            }
        }
        let pageHTML: String? = (html?.isEmpty == false) ? html : nil
        if pageHTML == nil {
            log("no-html host=\(host) reason=\(fetchFailure ?? "empty")", request)
        }

        let supportsArticle = session.supportsArticlePayload
        var budget: RescueDigestBudget = supportsArticle ? .privateCloud : .onDevice

        // (5) Plan call, with one digest-halving retry on context overflow.
        let instructions = RescuePrompts.planInstructions(hint: request.hint, allowsArticlePayload: supportsArticle)
        session.prewarm(instructions: instructions)

        var plan: RescuePlanResponse?
        var digest = ""
        for attempt in 0..<2 {
            onProgress(.digesting)
            let split = Self.split(budget: budget, hasEvidence: trace != nil)
            digest = pageHTML.map {
                digestBuilder.buildDigest(
                    url: request.url, html: $0, hint: request.hint, budget: split.digest)
            } ?? RescuePrompts.unavailableDigest(reason: fetchFailure ?? "empty response")
            let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: split.evidence)
            log("digest chars=\(digest.count) evidence chars=\(evidence?.count ?? 0) "
                + "est-tokens=\(RescueDigestBudget.estimatedTokens(forCharacters: digest.count + (evidence?.count ?? 0))) attempt=\(attempt)",
                request)
            let prompt = RescuePrompts.planPrompt(
                url: request.url, hint: request.hint,
                failureKind: request.failureKind, failureReason: request.failureReason,
                digest: digest, evidence: evidence)
            do {
                onProgress(.thinking)
                plan = try await callPlan(instructions: instructions, prompt: prompt)
                break
            } catch let error as RescueModelError {
                if case .exceededContextWindowSize = error, attempt == 0 {
                    budget = budget.halved
                    continue
                }
                return modelOutcome(error, host: host, request: request)
            } catch {
                return .failed(.other(error))
            }
        }
        guard let plan else { return .unrescuable }
        log("plan kind=\(plan.kind) host=\(host)", request)

        // (6) Validate → (optionally) one intermediate round → directive.
        let resolution = validator.validate(
            plan: plan, request: request, digest: digest,
            supportsArticlePayload: supportsArticle)

        let directive: RescueDirective
        var method: RescueMethod?
        switch resolution {
        case .failure(let rejection):
            log("reject reason=\(rejection) host=\(host)", request)
            return .unrescuable
        case .success(.directive(let d)):
            directive = d
        case .success(.needsArticlePayload):
            onProgress(.reading)
            guard let payloadDirective = await requestArticlePayload(
                request: request, digest: digest, host: host) else {
                return .unrescuable
            }
            directive = payloadDirective
        case .success(.needsSearch(let query)):
            guard let selected = await runSearchRound(
                query: query, request: request, host: host,
                supportsArticle: supportsArticle, onProgress: onProgress) else {
                return .unrescuable
            }
            directive = selected
            method = .search
        case .success(.needsInspection(let inspectURL)):
            guard let inspected = await runInspectRound(
                inspectURL: inspectURL, request: request, host: host, budget: budget,
                trace: trace, supportsArticle: supportsArticle, onProgress: onProgress) else {
                return .unrescuable
            }
            directive = inspected
        }

        // (7) Apply.
        onProgress(.applying)
        let outcome = await applier.apply(directive, request: request, method: method)
        log("apply outcome=\(outcomeLabel(outcome)) host=\(host)", request)

        // (8) On a successful reroute/webJS, learn a rule.
        if outcome.succeeded, let rule = derivedRule(from: directive, request: request) {
            ruleStore.store(rule)
            log("rule stored host=\(host)", request)
        }
        return outcome
    }

    // MARK: - Intermediate rounds
    //
    // Both consume the ONE intermediate round the engine allows: their follow-up
    // call is validated with `allowsIntermediate: false`, so a model that answers
    // "search" to a search round, or "inspect_url" to an inspection, is rejected
    // rather than looping. The cap lives here, in code — never in the prompt.

    /// The search leg. The engine runs the query, filters the live results
    /// through `RescueSearchCandidates`, and asks the model to SELECT one; the
    /// validator then relaxes its host rule for exactly those URLs. The model
    /// never supplies a URL of its own at any point.
    private func runSearchRound(
        query: String, request: RescueRequest, host: String,
        supportsArticle: Bool, onProgress: @escaping (RescueStage) -> Void
    ) async -> RescueDirective? {
        let results = await search.searchResults(forQuery: query)
        let candidates = RescueSearchCandidates.filter(
            results, request: request, registrableDomain: { validator.registrableDomain($0) })
        log("search results=\(results.count) candidates=\(candidates.count) host=\(host)", request)
        guard !candidates.isEmpty else { return nil }

        let allowed = Set(candidates.map(\.url.absoluteString))
        let prompt = RescuePrompts.searchPrompt(
            url: request.url, title: request.pageTitle, results: candidates)
        onProgress(.thinking)
        let plan: RescuePlanResponse
        do {
            plan = try await callPlan(instructions: RescuePrompts.searchInstructions, prompt: prompt)
        } catch let error as RescueModelError {
            log("search round failed host=\(host) error=\(error.logToken)", request)
            return nil
        } catch {
            return nil
        }
        switch validator.validate(
            plan: plan, request: request, digest: "", supportsArticlePayload: supportsArticle,
            candidates: allowed, allowsIntermediate: false
        ) {
        case .success(.directive(let directive)):
            log("search picked host=\(host)", request)
            return directive
        case .success, .failure:
            log("search selection rejected host=\(host)", request)
            return nil
        }
    }

    /// The inspect leg: digest ONE more page at half budget and ask again.
    private func runInspectRound(
        inspectURL: URL, request: RescueRequest, host: String,
        budget: RescueDigestBudget, trace: String?, supportsArticle: Bool,
        onProgress: @escaping (RescueStage) -> Void
    ) async -> RescueDirective? {
        onProgress(.fetching)
        guard let html = try? await fetcher.fetchHTML(from: inspectURL), !html.isEmpty else {
            log("inspect fetch failed host=\(inspectURL.host ?? "?")", request)
            return nil
        }
        onProgress(.digesting)
        let split = Self.split(budget: budget.halved, hasEvidence: trace != nil)
        let digest = digestBuilder.buildDigest(
            url: inspectURL, html: html, hint: request.hint, budget: split.digest)
        let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: split.evidence)
        let prompt = RescuePrompts.inspectPrompt(
            originalURL: request.url, inspectedURL: inspectURL,
            digest: digest, evidence: evidence)
        let instructions = RescuePrompts.inspectInstructions(
            hint: request.hint, allowsArticlePayload: supportsArticle)
        onProgress(.thinking)
        let plan: RescuePlanResponse
        do {
            plan = try await callPlan(instructions: instructions, prompt: prompt)
        } catch let error as RescueModelError {
            log("inspect round failed host=\(host) error=\(error.logToken)", request)
            return nil
        } catch {
            return nil
        }
        log("inspect plan kind=\(plan.kind) host=\(host)", request)
        switch validator.validate(
            plan: plan, request: request, digest: digest,
            supportsArticlePayload: supportsArticle, allowsIntermediate: false
        ) {
        case .success(.directive(let directive)):
            return directive
        case .success, .failure(_):
            log("inspect selection rejected host=\(host)", request)
            return nil
        }
    }

    // MARK: - LLM calls (each time-boxed)

    private func callPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        try await withThrowingTimeout(seconds: Self.llmCallTimeout) {
            try await self.session.requestPlan(instructions: instructions, prompt: prompt)
        }
    }

    private func requestArticlePayload(request: RescueRequest, digest: String, host: String) async -> RescueDirective? {
        let prompt = RescuePrompts.articlePrompt(url: request.url, digest: digest)
        do {
            let response = try await withThrowingTimeout(seconds: Self.llmCallTimeout) {
                try await self.session.requestArticlePayload(
                    instructions: RescuePrompts.articleInstructions, prompt: prompt)
            }
            switch validator.validateArticlePayload(response, digest: digest) {
            case .success(let directive): return directive
            case .failure(let rejection):
                log("article reject reason=\(rejection) host=\(host)", request)
                return nil
            }
        } catch {
            log("article call failed host=\(host)", request)
            return nil
        }
    }

    /// Every model error gets its own log line and its own verdict; none fall
    /// through to `.other` by default.
    private func modelOutcome(
        _ error: RescueModelError, host: String, request: RescueRequest
    ) -> RescueOutcome {
        log("model error=\(error.logToken) host=\(host)", request)
        switch error {
        case .guardrailViolation, .refusal:
            // Permanent for this URL: the prompt is derived from the page.
            return .failed(.guardrailViolation)
        case .quotaLimitReached:
            return .quotaExhausted
        case .rateLimited:
            return .failed(.rateLimited)
        case .networkFailure:
            return .failed(.networkFailure)
        case .serviceUnavailable:
            return .failed(.serviceUnavailable)
        case .modelUnavailable:
            return .unavailable
        case .assetsUnavailable, .concurrentRequests:
            return .failed(.transientModel(token: error.logToken))
        case .exceededContextWindowSize:
            return .failed(.exceededContextWindowSize)
        case .decodingFailure, .unsupportedSchemaOrLocale:
            return .unrescuable
        case .other(let underlying):
            return .failed(.other(underlying))
        }
    }

    // MARK: - Budgets

    /// Splits a character budget between the page digest and the failure
    /// evidence. With no trace the digest keeps the whole budget, so a rescue
    /// on a device that never recorded one gets the plain digest-only prompt.
    static func split(
        budget: RescueDigestBudget, hasEvidence: Bool
    ) -> (digest: RescueDigestBudget, evidence: Int) {
        guard hasEvidence else { return (budget, 0) }
        let evidence = Int(Double(budget.maxCharacters) * evidenceShare)
        return (RescueDigestBudget(maxCharacters: budget.maxCharacters - evidence), evidence)
    }

    // MARK: - Learned rules

    private func derivedRule(from directive: RescueDirective, request: RescueRequest) -> RescueLearnedRule? {
        let host = HostMatching.normalizedHost(request.url.host ?? "")
        guard !host.isEmpty else { return nil }
        let stamp = now()
        switch directive {
        case let .reroute(reroute):
            guard let rewrite = Self.rewrite(from: request.url, to: reroute.url) else { return nil }
            return RescueLearnedRule(
                host: host, hint: request.hintKey, rewrite: rewrite,
                refererString: reroute.headers.referer?.absoluteString,
                acceptLanguage: reroute.headers.acceptLanguage,
                xForwardedFor: reroute.headers.xForwardedFor,
                createdAt: stamp, lastSuccessAt: stamp)
        case let .webJS(script):
            let rewrite = Self.rewrite(from: request.url, to: script.pageURL) ?? .none
            return RescueLearnedRule(
                host: host, hint: request.hintKey, rewrite: rewrite,
                refererString: script.headers.referer?.absoluteString,
                acceptLanguage: script.headers.acceptLanguage,
                xForwardedFor: script.headers.xForwardedFor,
                javascript: script.javascript, scriptResultKind: script.resultKind.rawValue,
                createdAt: stamp, lastSuccessAt: stamp)
        default:
            return nil   // payloads / media URLs don't generalize to a host rule
        }
    }

    /// Diff original → applied into a generalizable rewrite shape, or nil.
    static func rewrite(from original: URL, to applied: URL) -> RescueLearnedRule.URLRewrite? {
        if original.absoluteString == applied.absoluteString { return RescueLearnedRule.URLRewrite.none }
        // host-only change?
        if let oHost = original.host, let aHost = applied.host, oHost != aHost,
           original.path == applied.path, original.query == applied.query {
            return .hostReplace(aHost)
        }
        // path suffix appended?
        if original.host == applied.host, original.query == applied.query,
           applied.path.hasPrefix(original.path), applied.path.count > original.path.count {
            return .pathSuffix(String(applied.path.dropFirst(original.path.count)))
        }
        // query item appended?
        if original.host == applied.host, original.path == applied.path,
           let aQuery = applied.query, aQuery != (original.query ?? "") {
            let appended: String
            if let oQuery = original.query, aQuery.hasPrefix(oQuery + "&") {
                appended = String(aQuery.dropFirst(oQuery.count + 1))
            } else if original.query == nil {
                appended = aQuery
            } else {
                return nil
            }
            return .queryAppend(appended)
        }
        return nil
    }

    /// Rebuild a directive from a learned rule, re-validating through the same
    /// host policy so a stale/corrupt rule can't do what a live directive couldn't.
    private func directiveFromRule(_ rule: RescueLearnedRule, request: RescueRequest) -> RescueDirective? {
        guard let url = Self.applyRewrite(rule.rewrite, to: request.url) else { return nil }
        var headers = RescueHeaders()
        headers.userAgent = rule.userAgentToken.flatMap { RescueDirectiveValidator.userAgent(fromToken: $0) }
        headers.referer = rule.refererString.flatMap { URL(string: $0) }
        headers.acceptLanguage = rule.acceptLanguage
        headers.xForwardedFor = rule.xForwardedFor

        if let js = rule.javascript {
            guard js.utf8.count <= RescueDirectiveValidator.maxJavaScriptBytes else { return nil }
            let kind = RescueScript.ResultKind(rawValue: rule.scriptResultKind ?? "html") ?? .html
            return .webJS(RescueScript(pageURL: url, headers: headers, javascript: js, resultKind: kind))
        }
        // A reroute rule: re-check host policy against the rewritten URL.
        guard url.scheme?.lowercased() == "https",
              validator.isAllowedRerouteHost(candidate: url, original: request.url) else { return nil }
        return .reroute(RescueReroute(url: url, headers: headers))
    }

    static func applyRewrite(_ rewrite: RescueLearnedRule.URLRewrite, to url: URL) -> URL? {
        switch rewrite {
        case .none:
            return url
        case .hostReplace(let host):
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.host = host
            return comps.url
        case .pathSuffix(let suffix):
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.path += suffix
            return comps.url
        case .queryAppend(let item):
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.percentEncodedQuery = [comps.percentEncodedQuery, item].compactMap { $0 }.joined(separator: "&")
            return comps.url
        }
    }

    // MARK: - Diagnostics + timeouts

    /// Writes to the general stream AND, when the rescue is for a known item, to
    /// that item's own save trace — so the file a failed card exports explains
    /// what the rescue decided, not just what the first pass saw. Model OUTPUT is
    /// summarized (kinds, hosts, lengths) rather than quoted verbatim.
    private func log(_ message: String, _ request: RescueRequest? = nil) {
        SharedDiagnosticLog.record(message, category: "rescue")
        guard let itemID = request?.itemID else { return }
        traceStore.appendLine(
            "\(Self.traceTimestamps.string(from: now())) [rescue] \(message)", for: itemID)
    }

    private static let traceTimestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func recordStats(for outcome: RescueOutcome) {
        switch outcome {
        case .rescued(_, let method): stats.record(.rescued, method: method.rawValue)
        case .rescuedMedia(_, let method): stats.record(.rescued, method: method.rawValue)
        case .needsBrowser: stats.record(.browserHandoff, method: RescueMethod.browserHandoff.rawValue)
        case .unrescuable: stats.record(.unrescuable)
        case .unavailable: stats.record(.modelUnavailable)
        case .quotaExhausted: stats.record(.modelError)
        case .failed(let error):
            switch error {
            case .guardrailViolation: stats.record(.guardrailed)
            case .timedOut: stats.record(.timedOut)
            default: stats.record(.modelError)
            }
        }
    }

    /// A short, host-safe token for why a refetch failed — never the error's
    /// localized description, which can quote a server's own message.
    static func fetchFailureToken(_ error: Error) -> String {
        if let fetchError = error as? ArticleFetcher.FetchError {
            switch fetchError {
            case .badResponse(let status):
                return status.map { "http \($0)" } ?? "bad response"
            case .notHTML: return "not HTML"
            case .tooLarge: return "too large"
            case .subscribeRedirect(let landedOn):
                return "redirected to \(landedOn.absoluteString)"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorNotConnectedToInternet: return "offline"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "host not found"
            default: return "network error \(nsError.code)"
            }
        }
        return "fetch error"
    }

    static func reasonToken(_ reason: SaveFailureReason?) -> String {
        guard let reason else { return "unknown" }
        if case let .httpStatus(code) = reason { return "http\(code)" }
        return String(describing: reason)
    }

    /// Re-tag a successful outcome's method (used to mark a cache-hit rescue
    /// `.cachedRule` even though the applier labeled it by directive kind).
    static func relabel(_ outcome: RescueOutcome, as method: RescueMethod) -> RescueOutcome {
        switch outcome {
        case .rescued(let result, _): return .rescued(result, method: method)
        case .rescuedMedia(let assets, _): return .rescuedMedia(assets, method: method)
        default: return outcome
        }
    }

    private func outcomeLabel(_ outcome: RescueOutcome) -> String {
        switch outcome {
        case .rescued(_, let m): return "rescued(\(m.rawValue))"
        case .rescuedMedia(_, let m): return "rescuedMedia(\(m.rawValue))"
        case .needsBrowser: return "needsBrowser"
        case .unrescuable: return "unrescuable"
        case .unavailable: return "unavailable"
        case .quotaExhausted: return "quotaExhausted"
        case .failed: return "failed"
        }
    }

    /// Races `work` against `seconds` on UNSTRUCTURED tasks, resuming on
    /// whichever finishes first; nil means the timeout won.
    ///
    /// Deliberately NOT a task group. A group does not return until every child
    /// has finished, and `cancelAll()` only REQUESTS cancellation — so a single
    /// cancellation-deaf child hangs the group and, with it, the very timeout
    /// meant to bound it. A `LanguageModelSession.respond` that never comes back
    /// is exactly such a child, which is what left the failed-save card stuck on
    /// "Asking Apple Intelligence" forever instead of giving up after 90 s. Same
    /// reasoning and the same shape as `IntentIngestHelper.savePressRacingTimeout`,
    /// which carries this warning for the same reason.
    private func raceAgainstTimeout<T>(
        seconds: TimeInterval, _ work: @escaping () async -> T
    ) async -> T? {
        let resumeLatch = OneShotLatch()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: T?) {
                if resumeLatch.claim() { continuation.resume(returning: value) }
            }
            Task { finish(await work()) }
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                finish(nil)
            }
        }
    }

    private func withTimeout(seconds: TimeInterval, fallback: RescueOutcome, _ work: @escaping () async -> RescueOutcome) async -> RescueOutcome {
        await raceAgainstTimeout(seconds: seconds, work) ?? fallback
    }

    private func withThrowingTimeout<T>(seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
        let outcome = await raceAgainstTimeout(seconds: seconds) { () -> Result<T, Error> in
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        guard let outcome else { throw URLRescueError.timedOut }
        return try outcome.get()
    }
}

/// The media-less default resolver: apps that don't handle media (Reader,
/// Price Tracker) build the rescue engine without a real resolver, so a media
/// directive resolves no assets and the rescue stays unrescuable — matching
/// the surface split. Media apps inject `LunaMediaDownload.SocialMediaResolver`
/// through `URLRescueWiring.mediaResolver`.
public struct NoMediaResolver: SocialMediaResolving {
    public init() {}
    public func resolveAssets(for url: URL) async -> [MediaAsset] { [] }
}
