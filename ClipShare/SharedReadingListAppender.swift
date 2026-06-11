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
    }

    static func append(urlString: String) {
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
        guard !items.contains(where: { $0.urlString == urlString }) else { return }

        items.insert(
            Item(id: UUID(), urlString: urlString, title: nil, dateAdded: Date(),
                 state: "pending", contentFileName: nil, lastWordIndex: nil,
                 readState: "unopened", lastReaderMode: nil,
                 lastScrollOffset: nil, lastSpokenWordIndex: nil,
                 eyeTrackedWordIndex: nil, wordCount: nil, readingProgress: nil),
            at: 0)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
