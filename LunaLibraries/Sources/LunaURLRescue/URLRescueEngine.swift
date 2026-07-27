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
/// The "no second LLM pass" guarantee is structural: the applier's `runPipeline`
/// closure defaults to the raw `IngestPipeline.processResolved`, so a
/// rescue-triggered re-run can never recurse into rescue.
public final class URLRescueEngine {
    /// Hard ceiling on a whole rescue attempt.
    public static let totalBudget: TimeInterval = 90
    /// Per model round-trip.
    public static let llmCallTimeout: TimeInterval = 30

    private let session: RescueModelSession
    private let digestBuilder: RescueDigestBuilder
    private let validator: RescueDirectiveValidator
    private let applier: RescueDirectiveApplier
    private let ruleStore: RescueRuleStoring
    private let fetcher: HTMLFetching
    private let now: () -> Date

    public init(
        session: RescueModelSession = RescueModelSessionFactory.makeDefault(),
        scriptRunner: RescueScriptRunning = RescueWebScriptRunner(),
        ruleStore: RescueRuleStoring = RescueRuleStore.shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        mediaResolver: SocialMediaResolving = NoMediaResolver(),
        runPipeline: @escaping (IngestInput) async -> IngestResult
            = { await IngestPipeline.processResolved($0) },
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
        log("start host=\(host) hint=\(request.hintKey)")
        onProgress(.queued)

        // Bound the whole attempt.
        let outcome = await withTimeout(seconds: Self.totalBudget, fallback: .failed(.timedOut)) {
            await self.runRescue(request, host: host, onProgress: onProgress)
        }
        onProgress(.finished)
        return outcome
    }

    private func runRescue(
        _ request: RescueRequest, host: String,
        onProgress: @escaping (RescueStage) -> Void
    ) async -> RescueOutcome {
        // This engine outlives every attempt, so the model session must not:
        // start from a clean one rather than inheriting the previous rescue's
        // transcript (or a response our own timeout cancelled mid-flight).
        session.beginAttempt()

        // (1) Learned rule — deterministic, before any LLM.
        if let cached = ruleStore.rule(forHost: host, hint: request.hint) {
            log("cachedRule hit host=\(host)")
            if let directive = directiveFromRule(cached, request: request) {
                onProgress(.replayingRule)
                let outcome = await applier.apply(directive, request: request)
                if outcome.succeeded {
                    ruleStore.recordSuccess(cached)
                    log("cachedRule success host=\(host)")
                    return Self.relabel(outcome, as: .cachedRule)
                }
                ruleStore.recordFailure(forHost: host, hint: request.hint)
                log("cachedRule fail host=\(host)")
            }
        }

        // (2) Model availability.
        guard session.isAvailable else { log("unavailable host=\(host)"); return .unavailable }

        // (3) HTML → digest (best-effort refetch when the caller didn't hand us HTML).
        let html: String?
        if let prefetched = request.fetchedHTML {
            html = prefetched
        } else {
            onProgress(.fetching)
            html = try? await fetcher.fetchHTML(from: request.url)
        }
        guard let html, !html.isEmpty else {
            log("no-html host=\(host)")
            return .unrescuable
        }
        let supportsArticle = session.supportsArticlePayload
        var budget: RescueDigestBudget = supportsArticle ? .privateCloud : .onDevice

        // (4) Plan call, with one digest-halving retry on context overflow.
        let instructions = RescuePrompts.planInstructions(hint: request.hint, allowsArticlePayload: supportsArticle)
        session.prewarm(instructions: instructions)

        var plan: RescuePlanResponse?
        for attempt in 0..<2 {
            onProgress(.digesting)
            let digest = digestBuilder.buildDigest(url: request.url, html: html, hint: request.hint, budget: budget)
            log("digest chars=\(digest.count) est-tokens=\(RescueDigestBudget.estimatedTokens(forCharacters: digest.count)) attempt=\(attempt)")
            let prompt = RescuePrompts.planPrompt(
                url: request.url, hint: request.hint,
                failureKind: request.failureKind, digest: digest)
            do {
                onProgress(.thinking)
                plan = try await callPlan(instructions: instructions, prompt: prompt)
                break
            } catch let error as RescueModelError {
                switch error {
                case .exceededContextWindowSize where attempt == 0:
                    budget = budget.halved
                    continue
                case .guardrailViolation:
                    log("guardrail host=\(host)")
                    return .unrescuable
                case .quotaLimitReached:
                    log("quota host=\(host)")
                    return .quotaExhausted
                case .rateLimited:
                    return .failed(.rateLimited)
                case .networkFailure:
                    return .failed(.networkFailure)
                case .serviceUnavailable:
                    return .failed(.serviceUnavailable)
                case .modelUnavailable:
                    return .unavailable
                case .exceededContextWindowSize:
                    return .failed(.exceededContextWindowSize)
                case .other(let underlying):
                    return .failed(.other(underlying))
                }
            } catch {
                return .failed(.other(error))
            }
        }
        guard let plan else { return .unrescuable }
        log("plan kind=\(plan.kind) host=\(host)")

        // (5) Validate → resolve → (optionally) article-payload follow-up.
        let digestForValidation = digestBuilder.buildDigest(
            url: request.url, html: html, hint: request.hint, budget: budget)
        let resolution = validator.validate(
            plan: plan, request: request, digest: digestForValidation, supportsArticlePayload: supportsArticle)

        let directive: RescueDirective
        switch resolution {
        case .failure(let rejection):
            log("reject reason=\(rejection) host=\(host)")
            return .unrescuable
        case .success(.directive(let d)):
            directive = d
        case .success(.needsArticlePayload):
            onProgress(.reading)
            guard let payloadDirective = await requestArticlePayload(
                request: request, digest: digestForValidation, host: host) else {
                return .unrescuable
            }
            directive = payloadDirective
        }

        // (6) Apply.
        onProgress(.applying)
        let outcome = await applier.apply(directive, request: request)
        log("apply outcome=\(outcomeLabel(outcome)) host=\(host)")

        // (7) On a successful reroute/webJS, learn a rule.
        if outcome.succeeded, let rule = derivedRule(from: directive, request: request) {
            ruleStore.store(rule)
            log("rule stored host=\(host)")
        }
        return outcome
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
                log("article reject reason=\(rejection) host=\(host)")
                return nil
            }
        } catch {
            log("article call failed host=\(host)")
            return nil
        }
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

    private func log(_ message: String) {
        SharedDiagnosticLog.record(message, category: "rescue")
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
        let resumeLock = NSLock()
        var resumed = false
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: T?) {
                resumeLock.lock()
                let first = !resumed
                resumed = true
                resumeLock.unlock()
                if first { continuation.resume(returning: value) }
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
/// through `URLRescueWiring.mediaResolverFactory`.
public struct NoMediaResolver: SocialMediaResolving {
    public init() {}
    public func resolveAssets(for url: URL) async -> [MediaAsset] { [] }
}
