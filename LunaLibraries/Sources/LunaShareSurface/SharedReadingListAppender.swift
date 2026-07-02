//
//  SharedReadingListAppender.swift
//  LunaShare
//

import LunaAppConfig
import LunaURLClassification
import LunaModels
import LunaStorage
import Foundation

/// Appends a pending item to the reading-list JSON in the App Group container.
///
/// The extension can't link the app's `ReadingListItem` type, so it writes raw
/// JSON dictionaries via `JSONSerialization` and — crucially — preserves every
/// EXISTING item verbatim. (Decoding the whole list into a schema-locked mirror
/// struct and re-encoding it used to silently drop any field the mirror didn't
/// know about — e.g. `platform`/`sendStates` — corrupting other items.)
public enum SharedReadingListAppender {
    public static let appGroupID = AppConfig.appGroupID

    public static func append(urlString: String) {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return }
        let urlString = url.absoluteString
        insertIfNew(dedupeURLString: urlString) {
            newItemDict(id: UUID(), urlString: urlString, title: nil, documentType: nil)
        }
    }

    /// Copies an imported document into the App Group and appends a pending item
    /// referencing it (`Articles/<id>-source.<ext>`).
    public static func appendDocument(sourceURL: URL) {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        let id = UUID()
        // Restrict the extension to alphanumerics so it can't smuggle path
        // separators into the `<id>-source.<ext>` filename.
        let rawExt = sourceURL.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let ext = rawExt.isEmpty ? "txt" : String(rawExt.prefix(8))
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let articlesDir = container.appendingPathComponent("Articles", isDirectory: true)
        try? fileManager.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        let destination = articlesDir.appendingPathComponent("\(id.uuidString)-source.\(ext)")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            return
        }

        insertIfNew(dedupeURLString: nil) {
            newItemDict(
                id: id, urlString: "lunadoc://\(id.uuidString)",
                title: title.isEmpty ? "Document" : title, documentType: ext)
        }
    }

    /// The minimal fields a new pending item needs. Dates use the default
    /// `JSONEncoder` representation (`timeIntervalSinceReferenceDate`) so the main
    /// app's `JSONDecoder` reads them back; absent fields use the model defaults.
    private static func newItemDict(
        id: UUID, urlString: String, title: String?, documentType: String?
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "urlString": urlString,
            "dateAdded": Date().timeIntervalSinceReferenceDate,
            "state": "pending",
            "readState": "unopened",
            // Everything appended here arrived via the iOS share sheet. Raw
            // string (not the `CaptureSource` enum) to avoid linking ReaderKit
            // into the extension — must match `CaptureSource.shareSheet`.
            "captureSource": "shareSheet",
        ]
        if let title { dict["title"] = title }
        if let documentType { dict["documentType"] = documentType }
        return dict
    }

    /// Reads the list as raw dictionaries (preserving unknown fields), prepends
    /// the new item unless `dedupeURLString` already exists, and writes it back.
    private static func insertIfNew(dedupeURLString: String?, makeItem: () -> [String: Any]) {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }
        let fileURL = container.appendingPathComponent("readingList.json")

        // Coordinate the whole read-modify-write so a concurrent write from the
        // main app / SaveLink intent (which use NSFileCoordinator too) can't clobber
        // this append or vice-versa.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordError) { url in
            var array: [[String: Any]] = []
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                array = decoded
            }
            if let dedupeURLString,
               array.contains(where: { ($0["urlString"] as? String) == dedupeURLString }) {
                return
            }
            array.insert(makeItem(), at: 0) // newest first
            if let data = try? JSONSerialization.data(withJSONObject: array) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if let coordError {
            // A failed coordination silently drops the user's share — leave a trace.
            SharedDiagnosticLog.record(
                "share append coordination failed: \(coordError.localizedDescription)",
                category: "share")
        }
    }
}
