//
//  PreloadCoordinator.swift
//  Clip
//

import ClipIngest
import ClipModels
import UIKit

/// Background engine that preloads the links on a saved article (recursively to
/// `ReaderSettings.preloadDepth`) into the shared `PreloadStore`, so the inline link
/// viewer opens instantly. Runs entirely off the main UI path via the UI-free
/// `IngestPipeline` (no WKWebView / CAPTCHA), dedupes by URL across trees, and never
/// blocks a save's completion. Main-app only; the action extension just saves, and
/// the main app resumes preloading on foreground / background-refresh.
final class PreloadCoordinator {
    static let shared = PreloadCoordinator()

    private let store: PreloadStore
    private let readingListStore: ReadingListStore
    /// Roots currently being preloaded, so a foreground resume can't double-run one.
    private var runningRoots: Set<UUID> = []
    private let lock = NSLock()

    /// Safety cap on pages crawled per root run, so a hub page with hundreds of
    /// links can't crawl unbounded.
    private static let maxPagesPerRun = 80
    /// Per-link pipeline budget — shorter than the interactive 28s so a slow link
    /// doesn't stall the whole crawl.
    private static let perLinkTimeout: TimeInterval = 15

    init(store: PreloadStore = .shared, readingListStore: ReadingListStore = .shared) {
        self.store = store
        self.readingListStore = readingListStore
    }

    // MARK: - Public entry points

    /// Preload the links of one freshly-saved (or to-be-resumed) root article. Returns
    /// immediately; the crawl runs detached.
    func preload(rootID: UUID) {
        guard ReaderSettings.preloadDepth > 0 else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.run(rootID: rootID)
        }
    }

    /// Resume preloading for every ready article whose tree may be incomplete. Called
    /// on foreground and from the background-refresh task. Cheap when everything is
    /// already cached (each URL short-circuits on the loaded entry).
    func resumeIncomplete() {
        guard ReaderSettings.preloadDepth > 0 else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for item in self.readingListStore.items()
            where item.state == .ready && item.contentFileName != nil {
                await self.run(rootID: item.id)
            }
        }
    }

    // MARK: - Crawl

    private func claim(_ rootID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !runningRoots.contains(rootID) else { return false }
        runningRoots.insert(rootID)
        return true
    }

    private func unclaim(_ rootID: UUID) {
        lock.lock(); defer { lock.unlock() }
        runningRoots.remove(rootID)
    }

    private func run(rootID: UUID) async {
        guard claim(rootID) else { return }
        defer { unclaim(rootID) }

        guard let item = readingListStore.item(withID: rootID),
              let content = readingListStore.content(for: item) else { return }
        let depth = ReaderSettings.preloadDepth
        guard depth > 0 else { return }

        // A brief background window so a crawl started on save survives a short
        // backgrounding (e.g. the user leaves right after saving).
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "preload-\(rootID)")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        var queue: [(url: URL, levelsLeft: Int)] = Self.outboundURLs(from: content).map { ($0, depth) }
        var visitedThisRun = Set<String>()
        var pagesProcessed = 0

        while !queue.isEmpty, pagesProcessed < Self.maxPagesPerRun {
            let job = queue.removeFirst()
            let key = PreloadStore.key(for: job.url)
            guard visitedThisRun.insert(key).inserted else { continue }

            // Dedup: an already-loaded entry (this tree or another save's) just gains
            // this root as an owner across its whole cached subtree — no refetch.
            if let existing = store.entry(for: job.url), existing.state == .loaded {
                claimCachedSubtree(rootID: rootID, fromKey: key, visited: &visitedThisRun)
                continue
            }

            pagesProcessed += 1
            let childURLs = await loadAndRecord(url: job.url, rootID: rootID, levelsLeft: job.levelsLeft)
            if job.levelsLeft > 1 {
                for child in childURLs { queue.append((child, job.levelsLeft - 1)) }
            }
        }
    }

    /// Runs the UI-free pipeline for `url`, records the result owned by `rootID`, and
    /// returns the outbound links to crawl next (only for article results).
    private func loadAndRecord(url: URL, rootID: UUID, levelsLeft: Int) async -> [URL] {
        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .manual), timeout: Self.perLinkTimeout)
        switch outcome {
        case let .article(content, _):
            // Download the article's images now (into the shared Articles cache, keyed
            // by image-URL hash) and cache the enriched content, so a preloaded link
            // opens with its images already local — no spinner-then-image-pop.
            let enriched = await ArticleImageDownloader.download(
                content, itemID: rootID, store: readingListStore, refererURL: url)
            let children = Self.outboundURLs(from: enriched)
            store.record(url: url, rootID: rootID, kind: .article, depthRemaining: levelsLeft,
                         content: enriched, children: children)
            return children
        case let .social(platform, itemID), let .video(platform, itemID):
            store.record(url: url, rootID: rootID, kind: .platform, depthRemaining: levelsLeft,
                         platform: PreloadPlatform(platform: platform.rawValue, itemID: itemID))
            return []
        case let .audio(platform, _, itemID):
            store.record(url: url, rootID: rootID, kind: .platform, depthRemaining: levelsLeft,
                         platform: PreloadPlatform(platform: platform.rawValue, itemID: itemID))
            return []
        case .product, .needsArchive, .document, .failed:
            // No reader content to cache: a product page (live tap handles its UI), a
            // paywall the silent bypass couldn't crack, a document, or a failure. Record
            // as unrepresentable so we don't re-crawl and the viewer falls back to a
            // live load. (Web-archive snapshotting is deferred — see preload-plan.md.)
            store.record(url: url, rootID: rootID, kind: .unrepresentable, depthRemaining: levelsLeft)
            return []
        }
    }

    /// Walks an already-cached subtree adding `rootID` as an owner of every entry,
    /// without refetching (dedup ownership extension).
    private func claimCachedSubtree(rootID: UUID, fromKey: String, visited: inout Set<String>) {
        var stack = [fromKey]
        var guardCount = 0
        while let key = stack.popLast(), guardCount < Self.maxPagesPerRun {
            guardCount += 1
            guard let entry = store.addOwner(rootID, toKey: key) else { continue }
            for child in entry.children where visited.insert(child).inserted {
                stack.append(child)
            }
        }
    }

    // MARK: - Helpers

    /// The de-duplicated set of absolute http(s) outbound links on an article, in
    /// document order.
    static func outboundURLs(from content: ArticleContent) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for block in content.blocks {
            for link in block.links {
                guard seen.insert(link.urlString).inserted,
                      let url = URL(string: link.urlString),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { continue }
                result.append(url)
            }
        }
        return result
    }
}
