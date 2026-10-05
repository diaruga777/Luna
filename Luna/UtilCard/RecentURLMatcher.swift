//
//  RecentURLMatcher.swift
//  Luna
//

import LunaAppConfig
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaSaves
import LunaSavesUI
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
        resolvedAppGroupDefaults(appGroupID: AppConfig.appGroupID, testOverride: Self.testDefaultsOverride)
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
        let savedURLs = Set(SavesStore.shared.items().map(\.urlString))
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

    /// Applies the saves half of recent-row publication, and collapses the
    /// candidates against EACH OTHER. Keeping this a pure operation makes the
    /// save/delete symmetry explicit: a committed save removes its cached Safari
    /// preview, and deleting that save reveals the same preview again without
    /// re-fetching or reclassifying the URL.
    ///
    /// The trail holds raw URL strings, deduplicated exactly by whichever Safari
    /// extension wrote them — but two distinct raw strings routinely name one page
    /// (a share link and its canonical form, `?utm_…`, a trailing slash, `www.`,
    /// a fragment), and the pipeline resolves them to the same preview. Collapsing
    /// happens BEFORE the row cap in `publish`, so five duplicates of one article
    /// can no longer fill the block; the FIRST occurrence wins, and the trail is
    /// newest-first, so the survivor is the most recent visit.
    static func deduplicated(
        _ candidates: [RecentURLPreview], savedURLStrings: Set<String>
    ) -> [RecentURLPreview] {
        let savedKeys = Set(savedURLStrings.map(identityKey(for:)))
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = identityKey(for: candidate.urlString)
            guard !savedKeys.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
    }

    /// The "same page" key two recent rows are compared by.
    ///
    /// The fragment and the tracking params come off through
    /// `URLCanonicalizer.strip` rather than through a list of this screen's own:
    /// that is THE place that decision lives, and a row that disagreed with it
    /// would be offering a second save of a page the store already considers the
    /// first one. What is added on top is the three cosmetic differences a raw
    /// Safari trail carries and a canonical URL does not — scheme, a `www.`, a
    /// trailing slash — plus case-folding the host. Everything the canonicaliser
    /// KEPT is kept: a real query is what distinguishes one video or product
    /// from the next.
    static func identityKey(for urlString: String) -> String {
        if URLBehaviorPolicy.pluginsOnly { return urlString }
        guard let url = URL(string: urlString),
              let components = URLComponents(
                url: URLCanonicalizer.strip(url), resolvingAgainstBaseURL: false)
        else { return urlString.lowercased() }
        let host = (components.host ?? "").lowercased()
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let query = components.query.map { "?\($0)" } ?? ""
        return "\(host)\(path)\(query)"
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
        guard !URLBehaviorPolicy.pluginsOnly else { return false }
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
        case .link: return nil
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
        case let .transcription(request):
            guard surface.handlesArticles else { return nil }
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: request.title, subtitle: result.url.host,
                kind: .article, imageData: await faviconData(for: result.url))
        case let .social(platform, itemID), let .video(platform, itemID):
            guard surface.handlesMedia else { return nil }
            let metadata = await PasteboardSuggester.platformPreviewArt?.preview(
                platform: platform, itemID: itemID,
                urlString: result.url.absoluteString)
            let fetchedTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RecentURLPreview(
                urlString: result.url.absoluteString,
                title: fetchedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? platform.displayName,
                subtitle: result.url.host,
                kind: .media, imageData: compressedData(metadata?.image))
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
        case .failed, .unsupported, .locked:
            // A locked save has no title or image yet, so the util card has
            // nothing to preview; the URL still pastes normally.
            return nil
        }
    }

    /// The site's icon, resolved the way every other surface in Luna resolves
    /// it — `FaviconFetcher`, which is what `SiteIconCache` puts behind a saved
    /// card's source badge.
    ///
    /// Plain `<scheme>://<host>/favicon.ico` is the one candidate a site is
    /// least likely to have: a WordPress install with no site icon set
    /// redirects that path to WordPress's own blue "W", and a site declaring
    /// its icon only through `<link rel="icon">` has no icon at that path at
    /// all. The fetcher tries the well-known apple-touch icon first, then the
    /// icons the homepage declares, and only then `/favicon.ico` — so a row
    /// shows the same mark the card shows once the link is saved.
    private static func faviconData(for url: URL) async -> Data? {
        guard !URLBehaviorPolicy.pluginsOnly else { return nil }
        guard let data = await FaviconFetcher().fetchIconData(forPageURL: url) else { return nil }
        return compressedData(UIImage(data: data))
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

    /// Downscales for the row's 52pt thumbnail and encodes.
    ///
    /// JPEG for photographs, PNG for anything with an alpha channel: a site
    /// icon is routinely a dark mark on transparency, and JPEG has no alpha to
    /// keep — flattened, it composites onto black and disappears into the row it
    /// is drawn on. Exposed for `RecentURLMatcherTests`, which pins exactly that.
    static func compressedData(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let longest: CGFloat = 220
        let scale = min(1, longest / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = !hasAlpha(image)
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return format.opaque ? resized.jpegData(compressionQuality: 0.72) : resized.pngData()
    }

    /// Whether the image's own pixel format carries transparency.
    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        switch alpha {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
