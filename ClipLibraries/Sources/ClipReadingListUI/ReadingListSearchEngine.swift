//
//  ReadingListSearchEngine.swift
//  Clip
//

import ClipSemantic
import ClipStorage
import ClipModels
import Foundation

/// Searches the saved reading list two ways in parallel:
/// 1. **String matching** over an in-memory, pre-lowercased haystack of every
///    item's title/metadata + extracted body — instant per keystroke.
/// 2. **Semantic** nearest-neighbour over the `SemanticIndexStore` vectors, by
///    embedding the query — finds items that are *about* the query even with no
///    shared words, across articles AND media.
///
/// The haystack is built once per search session (off the main thread) and reused
/// for every keystroke, so string search is a pure in-memory scan.
public protocol ReadingListSearching: AnyObject {
    /// Builds the in-memory haystack (reads each item's content). Call when search
    /// opens and whenever the list changes mid-session. Off-main.
    func prepare()
    /// Whether `prepare()` has finished building the haystack at least once.
    var isReady: Bool { get }
    /// String matches for `query`, title/metadata hits first then body hits.
    /// Instant, synchronous, main-thread-safe.
    func stringMatches(for query: String) -> [ReadingListItem]
    /// Semantically nearest items to `query` (excluding `excluded`), best first.
    /// Embeds the query (loads the model lazily); call off the main thread.
    func semanticMatches(for query: String, excluding: Set<UUID>) -> [ReadingListItem]
    /// Frees the embedding model. Call when search closes.
    func release()
}

/// One pre-lowercased searchable record. Split title/metadata vs body so a title
/// hit can rank above a body-only hit.
public struct SearchEntry {
    public let item: ReadingListItem
    /// Lowercased title + channel + creator + media title + host + sharer.
    public let titleText: String
    /// Lowercased extracted body (+ content title), empty for media/no-content.
    public let bodyText: String

    public init(item: ReadingListItem, titleText: String, bodyText: String) {
        self.item = item
        self.titleText = titleText
        self.bodyText = bodyText
    }
}

public final class ReadingListSearchEngine: ReadingListSearching {

    /// Query→content cosine runs lower than the item→item sharing threshold, so
    /// search uses its own (tunable) cutoff. Below this is noise.
    public static let semanticThreshold: Float = 0.45
    public static let semanticLimit = 40

    private let store: ReadingListStore
    private let index: SemanticIndexStore
    private let embedder = SemanticEmbedder()

    private let lock = NSLock()
    private var entries: [SearchEntry] = []
    private var ready = false

    public init(store: ReadingListStore = .shared, index: SemanticIndexStore = .shared) {
        self.store = store
        self.index = index
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    public func prepare() {
        let built = store.items().map { item -> SearchEntry in
            let titleText = [
                item.title, item.channelName, item.mediaCreatorName,
                item.mediaItemTitle, item.url?.host, item.sharedByUsername,
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            var bodyText = ""
            if let content = store.content(for: item) {
                bodyText = (content.title + " " + content.wholeText).lowercased()
            }
            return SearchEntry(item: item, titleText: titleText, bodyText: bodyText)
        }
        lock.lock()
        entries = built
        ready = true
        lock.unlock()
    }

    public func stringMatches(for query: String) -> [ReadingListItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        lock.lock(); let snapshot = entries; lock.unlock()
        return Self.rank(needle: needle, in: snapshot)
    }

    /// Pure ranking (title/metadata hits first, then body-only hits), unit-tested.
    public static func rank(needle: String, in entries: [SearchEntry]) -> [ReadingListItem] {
        var titleHits: [ReadingListItem] = []
        var bodyHits: [ReadingListItem] = []
        for entry in entries {
            if entry.titleText.contains(needle) {
                titleHits.append(entry.item)
            } else if entry.bodyText.contains(needle) {
                bodyHits.append(entry.item)
            }
        }
        return titleHits + bodyHits
    }

    public func semanticMatches(for query: String, excluding: Set<UUID>) -> [ReadingListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let vector = embedder.embed(trimmed) else { return [] }
        let hits = index.nearestItems(
            toVectors: [vector], threshold: Self.semanticThreshold,
            excluding: excluding, limit: Self.semanticLimit)
        // Map ids → items from the in-memory haystack (no disk reads).
        lock.lock(); let byID = Dictionary(entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { a, _ in a }); lock.unlock()
        return hits.compactMap { byID[$0.itemID] }
    }

    public func release() { embedder.release() }
}
