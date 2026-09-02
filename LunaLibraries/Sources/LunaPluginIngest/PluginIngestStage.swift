//
//  PluginIngestStage.swift
//  LunaPluginIngest
//

import Foundation
import LunaFetch
import LunaIngest
import LunaModels
import LunaPluginKit

/// The plugin classify + ingest walk, run before the Swift classifier
/// (`claudedocs/plans/plugin-platform.md` §7.4).
///
/// Plugins matched on the URL's host are tried in the runtime's order — host
/// matches first, then priority, then id. The first `classify` claim wins and
/// the walk calls that plugin's `ingest`. Anything short of a Model — a decline,
/// a timeout, an exception, a Model of an undeclared kind — falls through to the
/// next matched plugin and finally to the Swift classifier, which is the floor.
/// A broken plugin must never fail a save Swift could have made.
///
/// Every step writes a `SaveDiagnostics` line under the `plugin` category, so a
/// save's exported trace shows which plugins were asked and what each answered.
public final class PluginIngestStage: PluginIngestStaging {

    /// §7.5. `classify` is bounded by wall clock; `ingest` rides the pipeline's
    /// own 30s idle watchdog, which every bridge call touches.
    public static let classifyTimeout: TimeInterval = 8
    public static let ingestTimeout: TimeInterval = 30

    private let invoker: any PluginHookInvoking
    private let processKind: PluginProcessKind

    public init(invoker: any PluginHookInvoking, processKind: PluginProcessKind) {
        self.invoker = invoker
        self.processKind = processKind
    }

    public func run(_ input: IngestInput, fetcher: HTMLFetching) async -> PluginIngestVerdict {
        guard let host = input.url.host?.lowercased(), !host.isEmpty else { return .passed }
        let matched = invoker.matchedPlugins(forHost: host)
        guard !matched.isEmpty else { return .passed }
        SaveDiagnostics.record(
            "plugins: \(matched.count) matched \(host) — \(matched.map(\.id).joined(separator: ", "))",
            category: "plugin")

        let snapshot = Self.snapshot(of: input)
        for plugin in matched {
            switch await claim(plugin, url: input.url, page: snapshot) {
            case .none:
                continue
            case let .some(claim):
                switch await ingest(plugin, claim: claim, input: input, page: snapshot) {
                case .continueWalk:
                    continue
                case let .locked(pluginID):
                    return .locked(pluginID: pluginID)
                case let .produced(outcome):
                    return .outcome(outcome, pluginID: plugin.id)
                }
            }
        }
        SaveDiagnostics.record(
            "plugins: every matched plugin passed — the Swift classifier decides",
            category: "plugin")
        return .passed
    }

    // MARK: - classify

    /// This plugin's claim, or nil when it declined, broke, or claimed a kind it
    /// cannot serve here.
    private func claim(
        _ plugin: PluginSummary, url: URL, page: PluginPageSnapshot?
    ) async -> PluginIngestClaim? {
        guard plugin.hooks.contains(.classify) else { return nil }
        let argument = PluginClassifyInput(
            url: url.absoluteString, page: page, context: processKind)
        let result = await invoker.invoke(
            .classify, pluginID: plugin.id, argument: argument,
            timeout: Self.classifyTimeout, decode: PluginClassifyVerdict.self)

        switch result {
        case let .failure(failure):
            SaveDiagnostics.record(
                "plugin \(plugin.id): classify failed — \(Self.describe(failure))",
                category: "plugin")
            return nil
        case .success(.declined):
            SaveDiagnostics.record("plugin \(plugin.id): classify declined", category: "plugin")
            return nil
        case let .success(.claimed(kind, itemID, _)):
            guard plugin.produces.contains(kind) else {
                SaveDiagnostics.record(
                    "plugin \(plugin.id): claimed \(kind.rawValue), which it does not declare "
                        + "in produces — skipped",
                    category: "plugin")
                return nil
            }
            SaveDiagnostics.record(
                "plugin \(plugin.id): claimed \(kind.rawValue)"
                    + (itemID.map { " item \($0)" } ?? ""),
                category: "plugin")
            return PluginIngestClaim(kind: kind, itemID: itemID)
        }
    }

    // MARK: - ingest

    private enum IngestStep {
        case continueWalk
        case locked(pluginID: String)
        case produced(Outcome)
    }

    private func ingest(
        _ plugin: PluginSummary, claim: PluginIngestClaim, input: IngestInput,
        page: PluginPageSnapshot?
    ) async -> IngestStep {
        guard plugin.hooks.contains(.ingest) else { return .continueWalk }
        // The save's own id, which the trace is already correlated by. The
        // browser bridge writes its deferred request against it, and reads back
        // the result the app's modal wrote (§8.1).
        let saveID = SaveDiagnostics.recorder?.itemID
        // A save holding a completed browser result is being resumed, whether
        // the app asked for that or a launch sweep did.
        let reason: PluginIngestReason =
            saveID.map { PluginBrowserDeferral.witness?.hasCompletedResult(saveID: $0) ?? false }
                ?? false ? .resume : .save
        let argument = PluginIngestHookInput(
            url: input.url.absoluteString, claim: claim, page: page,
            reason: reason, context: processKind, saveID: saveID?.uuidString)
        let result = await PluginIngestScope.run(saveID: saveID, reason: reason) {
            await invoker.invoke(
                .ingest, pluginID: plugin.id, argument: argument,
                timeout: Self.ingestTimeout, decode: PluginIngestAnswer.self)
        }

        switch result {
        case .failure(.browserDeferred):
            SaveDiagnostics.record(
                "plugin \(plugin.id): asked for a browser this process cannot show — locking "
                    + "the save",
                category: "plugin")
            return .locked(pluginID: plugin.id)
        case let .failure(failure):
            SaveDiagnostics.record(
                "plugin \(plugin.id): ingest failed — \(Self.describe(failure))",
                category: "plugin")
            return .continueWalk
        case .success(.declined):
            SaveDiagnostics.record(
                "plugin \(plugin.id): ingest declined after reading the page", category: "plugin")
            return .continueWalk
        case let .success(.model(model)):
            return await adopt(model, claim: claim, plugin: plugin, input: input)
        }
    }

    // MARK: - adoption

    private func adopt(
        _ raw: PluginModel, claim: PluginIngestClaim, plugin: PluginSummary,
        input: IngestInput
    ) async -> IngestStep {
        guard plugin.produces.contains(raw.kind) else {
            SaveDiagnostics.record(
                "plugin \(plugin.id): returned a \(raw.kind.rawValue) Model it does not declare "
                    + "in produces — refused",
                category: "plugin")
            return .continueWalk
        }
        guard PluginModelAdopters.hasAdopter(for: raw.kind) else {
            SaveDiagnostics.record(
                "plugin \(plugin.id): no \(raw.kind.rawValue) adopter in this app — skipped",
                category: "plugin")
            return .continueWalk
        }

        // A plugin may write a path. Every URL is made absolute against the
        // save's own URL before any kind module sees the Model.
        let model = raw.resolvingRelativeURLs(against: input.url)
        let adopted: PluginAdoptedOutcome
        switch model {
        case let .media(media):
            guard let adopter = PluginModelAdopters.media else { return .continueWalk }
            // A plugin that named the item in `classify` need not repeat it in
            // the Model: it is the same item, and the card reads the id.
            let identified = media.itemID == nil && claim.itemID != nil
                ? MediaModel(
                    title: media.title, author: media.author,
                    thumbnailURL: media.thumbnailURL, platform: media.platform,
                    itemID: claim.itemID, assets: media.assets, expiresAt: media.expiresAt)
                : media
            adopted = await adopter.adopt(identified, url: input.url, pluginID: plugin.id)
        case let .article(article):
            guard let adopter = PluginModelAdopters.article else { return .continueWalk }
            adopted = await adopter.adopt(
                article, url: input.url, page: input.page, pluginID: plugin.id)
        case let .product(product):
            guard let adopter = PluginModelAdopters.product else { return .continueWalk }
            adopted = await adopter.adopt(product, url: input.url, pluginID: plugin.id)
        }

        switch adopted {
        case .declined:
            SaveDiagnostics.record(
                "plugin \(plugin.id): the \(model.kind.rawValue) adopter kept nothing",
                category: "plugin")
            return .continueWalk
        case let .failed(reason):
            SaveDiagnostics.record(
                "plugin \(plugin.id): adoption failed", category: "plugin")
            return .produced(.failed(reason))
        case let .media(assets, platform, itemID, _, _):
            SaveDiagnostics.record(
                "plugin \(plugin.id): adopted \(assets.count) media asset(s)", category: "plugin")
            // The same two outcomes the Swift platform path produces, so the
            // media card, the Live Activity and the auto-download policy see no
            // difference. `PluginMediaResolver` re-runs the plugin to hand the
            // download engine these assets.
            let hasTimeline = assets.contains { $0.kind == .video || $0.kind == .audio }
            return .produced(
                hasTimeline
                    ? .video(platform ?? .web, itemID: itemID)
                    : .social(platform ?? .web, itemID: itemID))
        case let .article(content, sourceHTML):
            SaveDiagnostics.record(
                "plugin \(plugin.id): adopted an article, \(content.bodyTextLength)ch",
                category: "plugin")
            return .produced(.article(content, html: sourceHTML ?? ""))
        case let .product(productModel, imageURL):
            let info = PluginProductInfoBuilder.make(from: productModel, imageURL: imageURL)
            SaveDiagnostics.record(
                "plugin \(plugin.id): adopted a product, \(info.sellers.count) seller(s)",
                category: "plugin")
            return .produced(.product(info, html: ""))
        }
    }

    // MARK: - Helpers

    /// The page the surface already has, as the hooks see it. A capture the
    /// pipeline made itself and a Safari hand-off both arrive as `fetch` here;
    /// only the Safari world names itself, and it builds its own snapshot.
    private static func snapshot(of input: IngestInput) -> PluginPageSnapshot? {
        guard let html = input.page.html else { return nil }
        return PluginPageSnapshot(url: input.url.absoluteString, html: html, source: "fetch")
    }

    private static func describe(_ failure: PluginInvocationFailure) -> String {
        switch failure {
        case .notLoaded: return "not loaded"
        case .missingHook: return "no such hook"
        case .timedOut: return "timed out"
        case .wedged: return "the runtime is wedged"
        case let .exception(message, _): return "threw: \(SaveDiagnostics.snippet(message))"
        case let .malformedResult(detail): return "malformed result: \(SaveDiagnostics.snippet(detail))"
        case .browserDeferred: return "browser deferred"
        case let .runtime(detail): return "runtime: \(SaveDiagnostics.snippet(detail))"
        }
    }
}
