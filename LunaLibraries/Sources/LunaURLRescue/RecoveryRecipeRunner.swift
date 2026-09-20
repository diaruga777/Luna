//
//  RecoveryRecipeRunner.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
import LunaIngest
import LunaModels
import LunaStorage
import LunaURLClassification

/// Replays the recipe a recovery Luna file carries, and learns from it.
///
/// This is the half of a recovery file that is worth more than its content: a
/// route Luna can take ITSELF. Replayed once and it becomes a
/// `RescueRuleStore` rule, so the next failure on that site is fixed
/// deterministically, without a model and without asking the user again.
///
/// It runs no model. The one thing it shares with `URLRescueEngine` is the
/// machinery below the model: the same validator's host policy, the same
/// directive applier (and so the same raw-pipeline re-entry, which is what
/// keeps a replay from triggering a rescue), and the same rule store.
public struct RecoveryRecipeRunner {

    /// A replay is a fetch plus at most one page script, not a model call.
    public static let budget: TimeInterval = 30

    private let validator = RescueRecipeValidator()
    private let applier: RescueDirectiveApplier
    private let ruleStore: RescueRuleStoring
    private let timeout: TimeInterval
    private let now: () -> Date

    public init(
        scriptRunner: RescueScriptRunning = RescueWebScriptRunner(),
        fetcher: HTMLFetching = ArticleFetcher(),
        mediaResolver: SocialMediaResolving = NoMediaResolver(),
        ruleStore: RescueRuleStoring = RescueRuleStore.shared,
        runPipeline: any RescuePipelineReentering = RawIngestPipelineReentry(),
        timeout: TimeInterval = RecoveryRecipeRunner.budget,
        now: @escaping () -> Date = Date.init
    ) {
        self.applier = RescueDirectiveApplier(
            fetcher: fetcher, scriptRunner: scriptRunner,
            mediaResolver: mediaResolver, runPipeline: runPipeline)
        self.ruleStore = ruleStore
        self.timeout = timeout
        self.now = now
    }

    /// Replays `recipe` and answers what the pipeline made of it, or nil when
    /// the recipe was refused, timed out, or produced nothing usable. A usable
    /// result also stores a host rule.
    public func run(
        _ recipe: LunaRecoveryRecipe, pageURL: URL, source: CaptureSource = .manual
    ) async -> IngestResult? {
        let directive: RescueDirective
        switch validator.directive(for: recipe, pageURL: pageURL) {
        case .success(let value):
            directive = value
        case .failure(let rejection):
            SharedDiagnosticLog.record(
                "recipe refused (\(rejection)) host=\(pageURL.host ?? "?")", category: "rescue")
            return nil
        }

        let request = RescueRequest(url: pageURL, source: source, failureKind: .articleFailed)
        let outcome = await raceAgainstTimeout(seconds: timeout) {
            await applier.apply(directive, request: request)
        } ?? .unrescuable
        guard case .rescued(let result, _) = outcome else {
            SharedDiagnosticLog.record(
                "recipe replay produced nothing host=\(pageURL.host ?? "?")", category: "rescue")
            return nil
        }
        learnRule(from: directive, pageURL: pageURL)
        return result
    }

    /// The rule the next failure on this host replays. Derived from the SAME
    /// directive shapes `URLRescueEngine` derives one from, so a rule learned
    /// from a chat reply and a rule learned from a model plan are one kind of
    /// row.
    private func learnRule(from directive: RescueDirective, pageURL: URL) {
        let host = HostMatching.normalizedHost(pageURL.host ?? "")
        guard !host.isEmpty else { return }
        let stamp = now()
        switch directive {
        case let .reroute(reroute):
            guard let rewrite = URLRescueEngine.rewrite(from: pageURL, to: reroute.url) else { return }
            ruleStore.store(RescueLearnedRule(
                host: host, rewrite: rewrite,
                refererString: reroute.headers.referer?.absoluteString,
                acceptLanguage: reroute.headers.acceptLanguage,
                createdAt: stamp, lastSuccessAt: stamp))
        case let .webJS(script):
            let rewrite = URLRescueEngine.rewrite(from: pageURL, to: script.pageURL) ?? .none
            ruleStore.store(RescueLearnedRule(
                host: host, rewrite: rewrite,
                refererString: script.headers.referer?.absoluteString,
                acceptLanguage: script.headers.acceptLanguage,
                javascript: script.javascript, scriptResultKind: script.resultKind.rawValue,
                createdAt: stamp, lastSuccessAt: stamp))
        default:
            return
        }
    }
}
