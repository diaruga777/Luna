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

    private var refreshTask: Task<Void, Never>?
    private(set) var matches: [RecentURLPreview] = []

    private var surface: AppSurface { AppSurfaceConfig.current }
    private var cacheKey: String {
        "recentURLChecks.\(surface.storageIdentifier).v1"
    }
    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
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
        let next = history.compactMap { cache[$0]?.match?.preview }
            .filter { !savedURLs.contains($0.urlString) }
            .prefix(5)
            .map { $0 }
        guard next != matches else { return }
        matches = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func loadCache() -> [String: CacheEntry] {
        guard let data = defaults.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.urlString, $0) })
    }

    private func saveCache(_ cache: [String: CacheEntry]) {
        let history = SafariRecentHistoryStore.shared.URLs
        let entries = history.compactMap { cache[$0] }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private static func evaluate(
        urlString: String, surface: AppSurface
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
        case .document, .failed, .unsupported:
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
