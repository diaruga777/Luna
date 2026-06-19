//
//  PendingSafariArchive.swift
//  ClipSafari
//

import Foundation

/// Writes an archive-harvest hand-off (one JSON file per capture) into the shared
/// App Group, for the main app to ingest into the reading list on next launch.
/// Kept self-contained in the extension target (the extension and app don't share
/// a framework — same reason `SharedSafariURL` is duplicated). A file (not a
/// defaults value) because the captured HTML can be hundreds of KB.
enum PendingSafariArchive {
    static let appGroupID = "group.com.hpiddy.clip"
    static let directoryName = "PendingSafariArchives"

    /// Persists a `{type:"archiveContent", url, title, html?, text?}` message from
    /// the extension's background script. Requires a usable http(s) URL; ignores
    /// anything else. `html` is preferred (the native extractor parses it); `text`
    /// is the fallback the content script sends when the stripped HTML is too large.
    static func write(message: [String: Any]) {
        guard let urlString = message["url"] as? String, urlString.hasPrefix("http"),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        var record: [String: Any] = [
            "url": urlString,
            "date": Date().timeIntervalSince1970,
        ]
        if let title = message["title"] as? String, !title.isEmpty { record["title"] = title }
        if let html = message["html"] as? String, !html.isEmpty { record["html"] = html }
        if let text = message["text"] as? String, !text.isEmpty { record["text"] = text }
        guard record["html"] != nil || record["text"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: record)
        else { return }

        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        try? data.write(to: file, options: .atomic)
    }
}
