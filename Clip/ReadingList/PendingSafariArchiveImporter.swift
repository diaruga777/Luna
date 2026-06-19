//
//  PendingSafariArchiveImporter.swift
//  Clip
//

import Foundation

/// Ingests archive-harvest hand-offs written by the Safari extension
/// (`PendingSafariArchive` in ClipSafari) into the reading list. Called on launch
/// and foreground. Each hand-off is one JSON file in the shared App Group; we
/// extract its article, save it as a ready reading-list item, and delete the file.
protocol PendingSafariArchiveImporting {
    /// Imports and clears all pending Safari archive hand-offs. Safe to call repeatedly.
    func importPending() async
}

final class PendingSafariArchiveImporter: PendingSafariArchiveImporting {
    static let shared = PendingSafariArchiveImporter()

    private static let appGroupID = "group.com.hpiddy.clip"
    private static let directoryName = "PendingSafariArchives"
    private let store: ReadingListStore
    private let directory: URL?
    private let extractor = ArticleExtractor()

    /// `directory` defaults to the shared App Group's `PendingSafariArchives/`
    /// (where the Safari extension writes); tests inject a scratch directory.
    init(store: ReadingListStore = .shared, directory: URL? = nil) {
        self.store = store
        self.directory = directory ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func importPending() async {
        guard let directory else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil), !files.isEmpty else { return }

        var importedAny = false
        for file in files where file.pathExtension == "json" {
            // Always remove the hand-off file, even on a parse miss, so a single bad
            // capture can't wedge the queue.
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = json["url"] as? String, let url = URL(string: urlString)
            else { continue }

            let title = json["title"] as? String
            let content = articleContent(from: json, url: url, fallbackTitle: title)
            guard let content else { continue }

            let item = store.add(urlString: urlString)
            _ = store.saveContent(content, for: item)
            importedAny = true
        }

        if importedAny {
            await MainActor.run {
                NotificationCenter.default.post(name: .readingListChanged, object: nil)
            }
        }
    }

    /// Builds article content from a hand-off: the stripped HTML via the shared
    /// extractor (preferred — keeps headings/links/images), else the plain-text
    /// fallback split into paragraphs.
    private func articleContent(
        from json: [String: Any], url: URL, fallbackTitle: String?
    ) -> ArticleContent? {
        if let html = json["html"] as? String, !html.isEmpty,
           let extracted = try? extractor.extract(html: html, baseURL: url),
           extracted.hasReadableBody {
            return extracted
        }
        if let text = json["text"] as? String, !text.isEmpty {
            return Self.content(fromPlainText: text, title: fallbackTitle)
        }
        return nil
    }

    /// Plain-text fallback: each non-empty line becomes a paragraph block.
    private static func content(fromPlainText text: String, title: String?) -> ArticleContent {
        let blocks = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ArticleContent.Block(kind: .paragraph, text: $0, links: []) }
        return ArticleContent(
            title: (title?.isEmpty == false ? title! : "Saved Article"),
            blocks: blocks.isEmpty
                ? [ArticleContent.Block(kind: .paragraph, text: text, links: [])]
                : blocks)
    }
}
