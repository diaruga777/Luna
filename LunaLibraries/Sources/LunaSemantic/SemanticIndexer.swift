//
//  SemanticIndexer.swift
//  LunaSemantic
//

import LunaStorage
import LunaModels
import Foundation

/// Builds the semantic index that powers semantic SEARCH over all saved content.
///
/// - `scheduleRun()` — MAIN APP ONLY. A background pass that embeds saved items
///   lacking vectors. A no-op when nothing needs embedding, so it doesn't load
///   the model unnecessarily.
///
/// Each item is embedded as several PARAGRAPH CHUNKS (title + lead paragraphs),
/// and two items match on their closest chunk pair. Logs to the shared
/// diagnostic log (category "semantic").
public final class SemanticIndexer {

    public static let shared = SemanticIndexer()

    private static let embedLimit = 20
    private static let maxChunks = 8
    private static let maxChunkChars = 800

    private let queue = DispatchQueue(label: "com.hsanabria.luna.semanticindexer", qos: .utility)
    private let index = SemanticIndexStore.shared
    private let runLock = NSLock()
    private var isRunQueuedOrRunning = false

    private func log(_ message: String) {
        SharedDiagnosticLog.record(message, category: "semantic")
    }

    // MARK: - Background indexing (main app)

    /// Embeds saved items lacking vectors, powering semantic search. A no-op when
    /// nothing needs embedding.
    public func scheduleRun() {
        runLock.lock()
        guard !isRunQueuedOrRunning else {
            runLock.unlock()
            return
        }
        isRunQueuedOrRunning = true
        runLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.runLock.lock()
                self.isRunQueuedOrRunning = false
                self.runLock.unlock()
            }
            self.buildMissingVectors()
        }
    }

    private func buildMissingVectors() {
        let allItemIDs = ReadingListStore.shared.items().map(\.id)
        let needed = index.itemIDsNeedingVectors(amongAll: allItemIDs, limit: Self.embedLimit)
        log("index pass: \(needed.count) item(s) to embed; \(index.indexedItemCount()) indexed")
        guard !needed.isEmpty else { return }
        let embedder = SemanticEmbedder()
        defer { embedder.release() }
        for itemID in needed {
            embedAndStore(itemID, embedder: embedder)
        }
    }

    /// Embeds an item's chunks and stores them (empty = tombstone).
    @discardableResult
    private func embedAndStore(_ itemID: UUID, embedder: SemanticEmbedder) -> Int {
        guard let item = ReadingListStore.shared.item(withID: itemID) else {
            index.setVectors([], forItemID: itemID)
            log("embed: item \(itemID.uuidString.prefix(8)) gone — tombstoned")
            return 0
        }
        let chunks = embeddingChunks(for: item)
        let vectors = chunks.compactMap { embedder.embed($0) }
        index.setVectors(vectors, forItemID: itemID)
        log("embed: \"\(item.title ?? item.urlString)\" → \(vectors.count) chunk vector(s) (dim \(vectors.first?.count ?? 0))")
        return vectors.count
    }

    // MARK: - Chunking

    /// Paragraph chunks for an item: a head built from the item's CONTENT metadata
    /// (title, channel, media creator/title) — never the URL — then lead article
    /// blocks. Media items thus get embedded on their real content, so they surface
    /// in semantic search.
    private func embeddingChunks(for item: ReadingListItem) -> [String] {
        var chunks: [String] = []
        let headParts = [
            item.title, item.channelName, item.mediaCreatorName, item.mediaItemTitle,
        ].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let head = headParts.joined(separator: ". ")
        if !head.isEmpty { chunks.append(head) }
        if let content = ReadingListStore.shared.content(for: item) {
            for block in content.blocks where !block.text.trimmingCharacters(in: .whitespaces).isEmpty {
                chunks.append(String(block.text.prefix(Self.maxChunkChars)))
                if chunks.count >= Self.maxChunks { break }
            }
        }
        return chunks
    }
}
