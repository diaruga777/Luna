//
//  SharedReadingListAppender.swift
//  ClipShare
//

import Foundation

/// Appends a pending item to the reading-list JSON in the App Group container.
/// The item shape mirrors the app's `ReadingListItem` (kept as a copy — no
/// shared framework in this small project; keep field names in sync).
enum SharedReadingListAppender {
    static let appGroupID = "group.com.hpiddy.clip"

    private struct Item: Codable {
        var id: UUID
        var urlString: String
        var title: String?
        var dateAdded: Date
        var state: String
        var contentFileName: String?
        var lastWordIndex: Int?
        var readState: String?
        var lastReaderMode: String?
        var lastScrollOffset: Double?
        var lastSpokenWordIndex: Int?
        var eyeTrackedWordIndex: Int?
        var wordCount: Int?
        var readingProgress: Double?
        var youtubeVideoID: String?
        var channelName: String?
        var thumbnailFileName: String?
        var sharedByUsername: String?
        var documentType: String?
        var sendState: String?
        var dateSent: Date?
        var lastSaveAttemptDate: Date?
    }

    static func append(urlString: String) {
        guard !urlString.isEmpty else { return }
        insertIfNew { items in
            guard !items.contains(where: { $0.urlString == urlString }) else { return nil }
            return makeItem(id: UUID(), urlString: urlString, title: nil, documentType: nil)
        }
    }

    /// Copies an imported document into the App Group and appends a pending
    /// item referencing it (`Articles/<id>-source.<ext>`). The main app parses
    /// it into article content on next launch.
    static func appendDocument(sourceURL: URL) {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension.lowercased()
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let articlesDir = container.appendingPathComponent("Articles", isDirectory: true)
        try? fileManager.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        let destination = articlesDir.appendingPathComponent("\(id.uuidString)-source.\(ext)")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            return
        }

        insertIfNew { _ in
            makeItem(
                id: id,
                urlString: "clipdoc://\(id.uuidString)",
                title: title.isEmpty ? "Document" : title,
                documentType: ext)
        }
    }

    private static func makeItem(
        id: UUID, urlString: String, title: String?, documentType: String?
    ) -> Item {
        Item(id: id, urlString: urlString, title: title, dateAdded: Date(),
             state: "pending", contentFileName: nil, lastWordIndex: nil,
             readState: "unopened", lastReaderMode: nil,
             lastScrollOffset: nil, lastSpokenWordIndex: nil,
             eyeTrackedWordIndex: nil, wordCount: nil, readingProgress: nil,
             youtubeVideoID: nil, channelName: nil, thumbnailFileName: nil,
             sharedByUsername: nil, documentType: documentType,
             sendState: nil, dateSent: nil, lastSaveAttemptDate: nil)
    }

    /// Loads the list, lets `build` produce an item to prepend (or nil to skip
    /// on dedupe), and writes it back.
    private static func insertIfNew(_ build: ([Item]) -> Item?) {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }
        let fileURL = container.appendingPathComponent("readingList.json")

        var items: [Item] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        }
        guard let item = build(items) else { return }
        items.append(item) // FIFO: newest at the end
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
