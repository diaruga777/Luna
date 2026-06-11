//
//  ReadingListIngestor.swift
//  Clip
//

import Foundation

/// Downloads and extracts content for reading-list items: the immediate step
/// after a link is saved, plus a retry pass for anything still pending.
final class ReadingListIngestor {
    static let shared = ReadingListIngestor()

    private let store = ReadingListStore.shared
    private let fetcher = ArticleFetcher()
    private let extractor = ArticleExtractor()

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    /// Fetches and extracts content for one item. Safe to call repeatedly.
    func ingest(_ item: ReadingListItem) async {
        guard item.state != .ready, let url = item.url else { return }

        lock.lock()
        let alreadyRunning = inFlight.contains(item.id)
        if !alreadyRunning { inFlight.insert(item.id) }
        lock.unlock()
        guard !alreadyRunning else { return }
        defer {
            lock.lock()
            inFlight.remove(item.id)
            lock.unlock()
        }

        do {
            let html = try await fetcher.fetchHTML(from: url)
            var content = try extractor.extract(html: html, baseURL: url)
            content = await downloadImages(for: content, itemID: item.id)
            _ = store.saveContent(content, for: item)
        } catch {
            store.markFailed(item.id)
        }
    }

    /// Downloads up to `maxImages` article images to the Articles directory and
    /// rewrites their blocks to point at the local files. Image blocks that
    /// fail to download are dropped so the reader never shows broken slots.
    private func downloadImages(for content: ArticleContent, itemID: UUID) async -> ArticleContent {
        let maxImages = 8
        let maxBytes = 5 * 1024 * 1024
        var downloaded = 0
        var blocks: [ArticleContent.Block] = []

        for var block in content.blocks {
            guard block.kind == .image else {
                blocks.append(block)
                continue
            }
            guard downloaded < maxImages,
                  let urlString = block.imageURLString,
                  let url = URL(string: urlString)
            else { continue }

            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count > 1024, data.count <= maxBytes
                else { continue }

                let fileExtension = url.pathExtension.isEmpty ? "img" : url.pathExtension
                let fileName = "\(itemID.uuidString)-img\(downloaded).\(fileExtension)"
                try data.write(
                    to: store.articlesDirectory.appendingPathComponent(fileName),
                    options: .atomic)
                block.imageFileName = fileName
                blocks.append(block)
                downloaded += 1
            } catch {
                continue
            }
        }

        var updated = content
        updated.blocks = blocks
        return updated
    }

    /// Kicks off ingestion for everything not yet ready (app launch / foreground).
    func ingestAllPending() {
        for item in store.items() where item.state != .ready {
            Task { await self.ingest(item) }
        }
    }

    /// Saves a URL and immediately starts ingesting it.
    @discardableResult
    func saveAndIngest(urlString: String) -> ReadingListItem {
        let item = store.add(urlString: urlString)
        Task { await self.ingest(item) }
        return item
    }
}
