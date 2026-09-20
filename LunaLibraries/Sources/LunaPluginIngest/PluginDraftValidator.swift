//
//  PluginDraftValidator.swift
//  LunaPluginIngest
//

import Foundation
import LunaPluginKit
import LunaPluginRuntime

/// Validates generated ingest source in a temporary store/runtime. Nothing is
/// written to the installed-plugin tree, saves database, Keychain, or user
/// files. Network reads are available only through the ordinary bounded fetch
/// bridge, which applies Luna's live-network and redirect policy.
public enum PluginDraftValidator {
    /// The capabilities the disposable runtime serves for real. A draft may
    /// DECLARE any capability — the review screen is where the user reads what
    /// it asked for — and every other namespace resolves to the standard
    /// unavailable proxy, so the test exercises the plugin's own logic rather
    /// than refusing it for a grant it will hold once installed.
    public static let servedCapabilities: Set<PluginCapabilityName> = [.fetch, .html]

    /// Runs the draft. With no `recoveryCase` and no `targetURL` the draft is
    /// only loaded: the manifest, the registration and the hook set are
    /// checked, and the report passes with a warning saying it never met a
    /// page.
    public static func validate(
        sourceText: String, recoveryCase: PluginRecoveryCase? = nil, targetURL: URL? = nil
    ) async -> PluginValidationReport {
        let source: String
        do {
            source = try PluginDraftSource.normalize(sourceText)
        } catch {
            return failed(error.localizedDescription, phase: "source")
        }

        let manifest: PluginManifest
        switch PluginManifestParser.parse(source: source) {
        case .failure(let error):
            return failed(error.message, phase: "manifest")
        case .success(let parsed):
            manifest = parsed
        }
        guard manifest.isIngestPlugin else {
            return failed(
                "The manifest must declare classify and ingest hooks by declaring a produces kind.",
                phase: "manifest")
        }
        if let host = recoveryCase?.host, !host.isEmpty,
           !manifest.summary(hooks: [.classify, .ingest], isBundled: false).matches(host: host) {
            return failed("The plugin does not match the host \(host).", phase: "host")
        }
        let target = targetURL ?? recoveryCase.flatMap { URL(string: $0.canonicalURL) }

        let untested = Set(manifest.capabilities).subtracting(servedCapabilities)
        var warnings: [String] = []
        if !untested.isEmpty {
            warnings.append(
                "This test serves only fetch and html. Not tested: "
                    + untested.map(\.rawValue).sorted().joined(separator: ", ") + ".")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "luna-plugin-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(rootURL: root)
        do {
            _ = try store.install(source: source, manifest: manifest, origin: .paste)
        } catch {
            return failed(error.localizedDescription, phase: "staging", warnings: warnings)
        }

        let registry = PluginCapabilityRegistry()
        let scratch = PluginScratchStore(rootURL: store.scratchRootURL)
        let runtime = PluginRuntime(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store),
            capabilities: registry, processContext: PluginProcessContext(kind: .app),
            scratch: scratch)
        let allowedHosts = Set([target?.host, recoveryCase?.host]
            .compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        let networkViolations = DraftNetworkViolations()
        let fetcher = PluginFetchService(allowedHosts: allowedHosts)
        fetcher.networkRefusalObserver = { networkViolations.record($0) }
        fetcher.idle = runtime
        fetcher.fileWriter = scratch
        registry.register(PluginFetchBridge(fetcher: fetcher, scheduler: runtime, files: scratch))
        registry.register(PluginHTMLBridge(scheduler: runtime))

        do {
            try await runtime.activateAsync(pluginID: manifest.id)
        } catch {
            return failed(describe(error), phase: "load", warnings: warnings)
        }
        let registered = runtime.loaded.first { $0.id == manifest.id }
            .map { Array($0.summary.hooks) } ?? []

        var attempts = [PluginRecoveryAttempt(
            phase: "load", result: "passed", message: "Manifest and registration loaded.")]
        guard let target else {
            // Nothing names a page to try, so the draft is judged on what it
            // declares and registers. The warning is what stops a green
            // result from reading as "it worked on the site".
            warnings.append("The draft was not run against a page.")
            return PluginValidationReport(
                passed: true, warnings: warnings, attempts: attempts,
                registeredHooks: registered)
        }

        let classify = await runtime.invoke(
            .classify, pluginID: manifest.id,
            argument: PluginClassifyInput(url: target.absoluteString, page: nil, context: .app),
            timeout: PluginIngestStage.classifyTimeout, decode: PluginClassifyVerdict.self)
        let claim: PluginIngestClaim
        switch classify {
        case .failure(let error):
            return failed(
                describe(error), phase: "classify", attempts: attempts, warnings: warnings,
                registeredHooks: registered)
        case .success(.declined):
            return failed(
                "classify declined the target URL; it must claim this page.",
                phase: "classify", attempts: attempts, warnings: warnings,
                registeredHooks: registered)
        case let .success(.claimed(kind, itemID, _)):
            guard manifest.produces.contains(kind) else {
                return failed(
                    "classify claimed \(kind.rawValue), which is absent from produces.",
                    phase: "classify", attempts: attempts, warnings: warnings,
                    registeredHooks: registered)
            }
            claim = PluginIngestClaim(kind: kind, itemID: itemID)
            attempts.append(PluginRecoveryAttempt(
                phase: "classify", result: "passed", message: "Claimed \(kind.rawValue)."))
        }

        let ingest = await runtime.invoke(
            .ingest, pluginID: manifest.id,
            argument: PluginIngestHookInput(
                url: target.absoluteString, claim: claim, page: nil,
                reason: .rescue, context: .app),
            timeout: PluginIngestStage.ingestTimeout, decode: PluginIngestAnswer.self)
        switch ingest {
        case .failure(let error):
            return failed(
                describe(error), phase: "ingest", attempts: attempts, warnings: warnings,
                registeredHooks: registered)
        case .success(.declined):
            return failed(
                "ingest returned null for the target URL; it must produce a valid Model.",
                phase: "ingest", attempts: attempts, warnings: warnings,
                registeredHooks: registered)
        case .success(.model(let model)):
            if let host = networkViolations.firstHost {
                return failed(
                    "The draft tried to contact \(host). Validation permits only the page's own site.",
                    phase: "network", attempts: attempts, warnings: warnings,
                    registeredHooks: registered)
            }
            guard manifest.produces.contains(model.kind) else {
                return failed(
                    "ingest returned \(model.kind.rawValue), which is absent from produces.",
                    phase: "ingest", attempts: attempts, warnings: warnings,
                    registeredHooks: registered)
            }
            attempts.append(PluginRecoveryAttempt(
                phase: "ingest", result: "passed",
                message: "Returned a valid \(model.kind.rawValue) Model."))
            return PluginValidationReport(
                passed: true, warnings: warnings, attempts: attempts,
                modelKind: model.kind.rawValue, registeredHooks: registered)
        }
    }

    private static func failed(
        _ message: String, phase: String, attempts: [PluginRecoveryAttempt] = [],
        warnings: [String] = [], registeredHooks: [PluginHook] = []
    ) -> PluginValidationReport {
        PluginValidationReport(
            passed: false, errors: [message], warnings: warnings,
            attempts: attempts + [PluginRecoveryAttempt(
                phase: phase, result: "failed", message: message)],
            registeredHooks: registeredHooks)
    }

    private static func describe(_ error: Error) -> String {
        if let activation = error as? PluginActivationError {
            return describe(activation.failure)
        }
        return error.localizedDescription
    }

    private static func describe(_ failure: PluginInvocationFailure) -> String {
        switch failure {
        case .notLoaded: return "The draft did not load."
        case .missingHook: return "The draft did not register the required hook."
        case .timedOut: return "The draft did not finish before the validation deadline."
        case .wedged: return "The draft's JavaScript runtime stopped responding."
        case .browserDeferred: return "The draft requested an interactive browser step."
        case .exception(let message, _), .malformedResult(let message), .runtime(let message):
            return message
        }
    }
}

private final class DraftNetworkViolations: @unchecked Sendable {
    private let lock = NSLock()
    private var host: String?

    var firstHost: String? {
        lock.lock(); defer { lock.unlock() }
        return host
    }

    func record(_ url: URL) {
        lock.lock()
        if host == nil { host = url.host ?? url.absoluteString }
        lock.unlock()
    }
}
