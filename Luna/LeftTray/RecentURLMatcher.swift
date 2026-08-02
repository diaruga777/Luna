//
//  RecentURLMatcher.swift
//  Luna
//

import LunaAppConfig
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import UIKit

struct RecentURLPreview: Equatable {
    enum Kind: String, Codable {
        case article
        case media
        case product
    }

    let urlString: String
    let title: String
    let subtitle: String?
    let kind: Kind
    let imageData: Data?

    var image: UIImage? { imageData.flatMap(UIImage.init(data:)) }
}

/// Per-app incremental evaluator for Safari's shared 20-URL trail.
///
/// Positive and negative results are persisted by surface, so foregrounding an
/// app with the same trail performs no network work. Reordering/revisiting an
/// existing URL also reuses its cached result while presentation follows the
/// trail's newest-first order.
@MainActor
final class RecentURLMatcher {
    static let shared = RecentURLMatcher()
    static let didChange = Notification.Name("lunaRecentURLMatchesDidChange")

    private struct CachedPreview: Codable {
        let urlString: String
        let title: String
        let subtitle: String?
        let kind: RecentURLPreview.Kind
        let imageData: Data?

        var preview: RecentURLPreview {
            RecentURLPreview(
                urlString: urlString, title: title, subtitle: subtitle,
                kind: kind, imageData: imageData)
        }
    }

    private struct CacheEntry: Codable {
        let urlString: String
        /// nil is a deliberately cached non-match, not "not checked".
        let match: CachedPreview?
    }

    /// The persisted cache plus the app version that produced it.
    ///
    /// Every entry is a verdict DERIVED by `IngestPipeline`, so when the pipeline
    /// changes the stored verdicts are simply wrong — and `refresh` only evaluates
    /// URLs *missing* from the cache, so nothing would ever re-derive them. That is
    /// how a Google search page kept its row after the classifier learned to reject
    /// search-results URLs: the tray was replaying a verdict recorded by an older
    /// build. Tying the cache to `AppConfig.appVersion` (short version *and* build,
    /// the same key `SaveFailureRecord.aiAttemptVersion` uses for the same "new
    /// build, new code" reasoning) makes every classifier change self-healing —
    /// there is no bump to remember, and the cost is re-checking at most 20 URLs
    /// once per install.
    private struct CachePayload: Codable {
        let version: String
        let entries: [CacheEntry]
    }

    private var refreshTask: Task<Void, Never>?
    private(set) var matches: [RecentURLPreview] = []

    private var surface: LunaApp { LunaApp.current }
    private var cacheKey: String {
        "recentURLChecks.\(surface.storageIdentifier).v1"
    }
    /// Test-only container override — mirrors `SafariURLStore.testDefaultsOverride`,
    /// so the cache's version discipline is assertable without the real App Group.
    static var testDefaultsOverride: UserDefaults?

    private var defaults: UserDefaults {
        Self.testDefaultsOverride
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    /// The persisted verdicts for the current surface, or empty when the cache was
    /// written by a different build. Exposed for `RecentURLMatcherTests`.
    func cachedVerdictCount() -> Int { loadCache().count }

    /// Writes `entries` under `version`, so a test can plant a cache from an
    /// "older build" and assert it is discarded rather than replayed.
    func writeCacheForTesting(urlStrings: [String], version: String) {
        let payload = CachePayload(
            version: version,
            entries: urlStrings.map { CacheEntry(urlString: $0, match: nil) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    func refresh() {
        let history = SafariRecentHistoryStore.shared.URLs
        let existing = loadCache()
        publish(history: history, cache: existing)
        let missing = history.filter { existing[$0] == nil }
        guard !missing.isEmpty else { return }

        refreshTask?.cancel()
        let currentSurface = surface
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var updated = existing
            // Four concurrent checks keep a cold 20-item trail bounded without
            // launching twenty simultaneous HTML/product requests.
            for start in stride(from: 0, to: missing.count, by: 4) {
                guard !Task.isCancelled else { return }
                let end = min(start + 4, missing.count)
                let batch = Array(missing[start..<end])
                let evaluated = await withTaskGroup(
                    of: (String, RecentURLPreview?).self,
                    returning: [(String, RecentURLPreview?)].self
                ) { group in
                    for urlString in batch {
                        group.addTask {
                            (urlString, await Self.evaluate(
                                urlString: urlString, surface: currentSurface))
                        }
                    }
                    var results: [(String, RecentURLPreview?)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for (urlString, preview) in evaluated {
                    updated[urlString] = CacheEntry(
                        urlString: urlString,
                        match: preview.map {
                            CachedPreview(
                                urlString: $0.urlString, title: $0.title,
                                subtitle: $0.subtitle, kind: $0.kind,
                                imageData: $0.imageData)
                        })
                }
                let liveHistory = SafariRecentHistoryStore.shared.URLs
                updated = updated.filter { liveHistory.contains($0.key) }
                saveCache(updated)
                publish(history: liveHistory, cache: updated)
            }
        }
    }

    private func publish(history: [String], cache: [String: CacheEntry]) {
        let savedURLs = Set(ReadingListStore.shared.items().map(\.urlString))
        let candidates = history
            .compactMap { key -> RecentURLPreview? in
                guard let preview = cache[key]?.match?.preview else { return nil }
                return Self.isObviouslyNonContent(preview: preview, historyKey: key)
                    ? nil : preview
            }
        let next = Self.deduplicated(
            candidates, savedURLStrings: savedURLs)
            .prefix(5)
            .map { $0 }
        guard next != matches else { return }
        matches = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Applies the reading-list half of recent-row publication. Keeping this a
    /// pure operation makes the save/delete symmetry explicit: a committed save
    /// removes its cached Safari preview, and deleting that save reveals the
    /// same preview again without re-fetching or reclassifying the URL.
    static func deduplicated(
        _ candidates: [RecentURLPreview], savedURLStrings: Set<String>
    ) -> [RecentURLPreview] {
        candidates.filter { !savedURLStrings.contains($0.urlString) }
    }

    /// The URL-only half of the pipeline's non-content veto, re-applied to a CACHED
    /// verdict on the way to the screen.
    ///
    /// The version stamp above already discards the whole cache after an update, so
    /// this is a second line rather than the fix — but it costs nothing (no HTML, no
    /// network) and it closes the window inside a single build, where a URL saved
    /// before a mid-session change would otherwise keep its row. It re-checks the
    /// canonical URL the preview would SAVE as well as the raw trail key, since the
    /// two differ once a URL is unwrapped.
    static func isObviouslyNonContent(
        preview: RecentURLPreview, historyKey: String
    ) -> Bool {
        let urls = [preview.urlString, historyKey].compactMap(URL.init(string:))
        return urls.contains { url in
            if ListingPage.isNonContentPage(url: url, html: nil) { return true }
            // Mirrors `IngestPipeline`: a commerce search / browse grid is a listing
            // only for a page the shop-host table already claimed as a product.
            return preview.kind == .product
                && ProductPageDetector.urlIsMultiProductListing(url)
        }
    }

    private func loadCache() -> [String: CacheEntry] {
        guard let data = defaults.data(forKey: cacheKey),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == AppConfig.appVersion
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: payload.entries.map { ($0.urlString, $0) })
    }

    private func saveCache(_ cache: [String: CacheEntry]) {
        let history = SafariRecentHistoryStore.shared.URLs
        let payload = CachePayload(
            version: AppConfig.appVersion, entries: history.compactMap { cache[$0] })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    static func evaluate(
        urlString: String, surface: LunaApp
    ) async -> RecentURLPreview? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let result = await IngestPipeline.processResolved(
            IngestInput(url: url, source: .manual))

        switch result.outcome {
        case let .article(content, _):
            guard surface.handlesArticles else { return nil }
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: content.title, subtitle: result.url.host,
                kind: .article, imageData: await faviconData(for: result.url))
        case let .needsArchive(title):
            guard surface.handlesArticles else { return nil }
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: title, subtitle: result.url.host,
                kind: .article, imageData: await faviconData(for: result.url))
        case let .social(platform, itemID), let .video(platform, itemID):
            guard surface.handlesMedia else { return nil }
            let image = await PasteboardSuggester.platformPreviewArt?(
                platform, itemID, result.url.absoluteString)
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: platform.displayName, subtitle: result.url.host,
                kind: .media, imageData: compressedData(image))
        case let .product(product, _):
            guard surface.handlesProducts else { return nil }
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: product.name, subtitle: product.brand ?? result.url.host,
                kind: .product, imageData: await imageData(at: product.imageURL))
        case let .document(type):
            guard surface.handlesArticles else { return nil }
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: result.url.lastPathComponent.removingPercentEncoding
                    ?? result.url.lastPathComponent,
                subtitle: type.uppercased(),
                kind: .article, imageData: nil)
        case .failed, .unsupported:
            return nil
        }
    }

    private static func faviconData(for url: URL) async -> Data? {
        guard let host = url.host,
              let favicon = URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico")
        else { return nil }
        return await imageData(at: favicon)
    }

    private static func imageData(at url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data)
        else { return nil }
        return compressedData(image)
    }

    private static func compressedData(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let longest: CGFloat = 220
        let scale = min(1, longest / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.72)
    }
}
