//
//  PluginRecoveryProbe.swift
//  LunaPluginIngest
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPluginKit
import LunaURLRescue

/// The result of diagnosing a URL without creating or changing a saved item.
public struct PluginRecoveryProbeResult: Sendable {
    public let recoveryCase: PluginRecoveryCase
    public let ingestResult: IngestResult

    public init(recoveryCase: PluginRecoveryCase, ingestResult: IngestResult) {
        self.recoveryCase = recoveryCase
        self.ingestResult = ingestResult
    }
}

/// Runs the native floor for an arbitrary URL while collecting the same bounded
/// attempt trace a failed save would export.  Plugins are intentionally skipped
/// during the probe: a probe must not run plugin adoption, browser UI, downloads,
/// or any plugin-side write.  Matching installed plugins are reported as data so
/// the authoring prompt can tell an LLM what it must improve or avoid.
public enum PluginRecoveryProbe {
    public static let defaultDigestBudget = RescueDigestBudget.onDevice
    public static let defaultAppVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    public static let defaultLocale = Locale.current.identifier
    public static let defaultLanguages = Locale.preferredLanguages

    public static func run(
        url: URL,
        source: CaptureSource = .manual,
        page: CapturedPage = .none,
        timeout: TimeInterval = IngestPipeline.processTimeout,
        session: URLSession = .shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        articleProcessor: ArticleIngestProcessing? = IngestKindProcessors.article,
        productProcessor: ProductIngestProcessing? = IngestKindProcessors.product,
        socialTextProcessor: SocialTextIngestProcessing? = IngestKindProcessors.socialText,
        invoker: (any PluginHookInvoking)? = PluginPlatformServices.invoker,
        digestBudget: RescueDigestBudget = defaultDigestBudget,
        appVersion: String = defaultAppVersion,
        locale: String = defaultLocale,
        languages: [String] = defaultLanguages,
        caseID: UUID = UUID()
    ) async -> PluginRecoveryProbeResult {
        let recorder = SaveDiagnosticsRecorder(itemID: caseID)
        let recordingFetcher = ProbeHTMLFetcher(base: fetcher)
        let result = await SaveDiagnostics.$recorder.withValue(recorder) {
            await IngestPipeline.processResolved(
                IngestInput(url: url, source: source, page: page), timeout: timeout,
                session: session, fetcher: page.html == nil ? recordingFetcher : fetcher,
                productDetector: productDetector, articleProcessor: articleProcessor,
                productProcessor: productProcessor, socialTextProcessor: socialTextProcessor,
                mode: .nativeProbe)
        }

        let html = page.html ?? recordingFetcher.html
        let digest: String?
        if let html {
            digest = RescueDigestBuilder().buildDigest(
                url: result.url, html: html, hint: nil, budget: digestBudget)
        } else {
            digest = nil
        }
        let trace = PluginRecoveryTraceParser.parse(recorder.drainLines())
        let matchedPlugins = invoker?.matchedPlugins(forHost: result.url.host ?? "") ?? []
        let matching = matchedPlugins.map {
            PluginRecoveryPlugin(
                id: $0.id, version: $0.version, status: "enabled",
                hooks: $0.hooks.map(\.rawValue).sorted())
        }
        let outcome = outcomeName(result.outcome)
        let reason = failureReason(result.outcome)
        let recoveryCase = PluginRecoveryCase(
            caseID: caseID, originalURL: url.absoluteString,
            canonicalURL: result.url.absoluteString, source: source,
            appVersion: appVersion, locale: locale, languages: languages,
            outcome: outcome, failureReason: reason,
            attempts: trace.attempts, attemptsDropped: trace.dropped, matchingPlugins: matching,
            matchingPluginsDropped: max(0, matchedPlugins.count - matching.count),
            pageDigest: digest, redactions: html == nil ? ["page HTML unavailable"] : [],
            evidenceTruncated: digest.map { $0.count >= digestBudget.maxCharacters } ?? false)
        return PluginRecoveryProbeResult(recoveryCase: recoveryCase, ingestResult: result)
    }

    private static func outcomeName(_ outcome: Outcome) -> String {
        switch outcome {
        case .article: return "article"
        case .product: return "product"
        case .social: return "social"
        case .video: return "video"
        case .document: return "document"
        case .needsArchive: return "needsArchive"
        case .failed: return "failed"
        case .unsupported: return "unsupported"
        case .locked: return "locked"
        case .transcription: return "transcription"
        }
    }

    private static func failureReason(_ outcome: Outcome) -> String? {
        guard case let .failed(reason) = outcome else { return nil }
        return reason.map(\.headline)
    }

}

private final class ProbeHTMLFetcher: HTMLFetching, @unchecked Sendable {
    let base: HTMLFetching
    private let lock = NSLock()
    private var capturedHTML: String?

    var html: String? {
        lock.lock(); defer { lock.unlock() }
        return capturedHTML
    }

    init(base: HTMLFetching) { self.base = base }

    func fetchHTML(from url: URL) async throws -> String {
        let value = try await base.fetchHTML(from: url)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        let value = try await base.fetchHTML(from: url, userAgent: userAgent, xForwardedFor: xForwardedFor)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchHTML(from url: URL, referer: String) async throws -> String {
        let value = try await base.fetchHTML(from: url, referer: referer)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        let value = try await base.fetchHTMLWithoutCookies(from: url)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchWaybackRawHTML(for url: URL) async throws -> String {
        let value = try await base.fetchWaybackRawHTML(for: url)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchWaybackPrePaywallHTML(for url: URL) async throws -> String {
        let value = try await base.fetchWaybackPrePaywallHTML(for: url)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }

    func fetchJinaReader(for url: URL) async throws -> String {
        let value = try await base.fetchJinaReader(for: url)
        lock.lock(); capturedHTML = value; lock.unlock()
        return value
    }
}
