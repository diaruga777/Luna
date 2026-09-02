//
//  PluginBrowserRequestStore.swift
//  LunaPluginKit
//

import Foundation

/// A `luna.browser.open` call the calling process could not present (§8.1).
///
/// An extension and the Safari world both defer: the save locks, and the app
/// presents the modal later and writes the result back. The request and the
/// result cross as JSON, because the shape belongs to the plugin's own
/// `BrowserRequest`, which the storage tier has no reason to model.
public struct PluginBrowserRequestRecord: Equatable, Sendable {
    public let saveID: String
    public let pluginID: String
    public let requestJSON: String
    public let resultJSON: String?
    public let createdAt: Date
    public let completedAt: Date?

    public init(
        saveID: String, pluginID: String, requestJSON: String, resultJSON: String?,
        createdAt: Date, completedAt: Date?
    ) {
        self.saveID = saveID
        self.pluginID = pluginID
        self.requestJSON = requestJSON
        self.resultJSON = resultJSON
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    /// True while the save is still waiting for the modal.
    public var isPending: Bool { resultJSON == nil }
}

/// The `plugin_browser_requests` table.
public final class PluginBrowserRequestStore: @unchecked Sendable {

    public static let shared = PluginBrowserRequestStore()

    private let fileURL: URL?
    private let openLock = NSLock()
    private var openedDatabase: PluginDatabase?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PluginDatabase.sharedFileURL()
    }

    private func database() -> PluginDatabase? {
        openLock.lock()
        defer { openLock.unlock() }
        if let openedDatabase { return openedDatabase }
        guard let fileURL, let database = PluginDatabase(fileURL: fileURL) else { return nil }
        openedDatabase = database
        return database
    }

    /// Records the request a save is now locked on. A second request for the
    /// same save replaces the first: only the newest one can be answered.
    @discardableResult
    public func put(
        saveID: String, pluginID: String, requestJSON: String, now: Date = Date()
    ) -> Bool {
        database()?.run(
            """
            INSERT INTO plugin_browser_requests
                (save_id, plugin_id, request_json, result_json, created_at, completed_at)
                VALUES (?, ?, ?, NULL, ?, NULL)
            ON CONFLICT(save_id) DO UPDATE SET
                plugin_id = excluded.plugin_id, request_json = excluded.request_json,
                result_json = NULL, created_at = excluded.created_at, completed_at = NULL
            """,
            [
                .text(saveID), .text(pluginID), .text(requestJSON),
                .double(now.timeIntervalSince1970),
            ]) ?? false
    }

    public func record(saveID: String) -> PluginBrowserRequestRecord? {
        database()?.query(
            "SELECT save_id, plugin_id, request_json, result_json, created_at, completed_at "
                + "FROM plugin_browser_requests WHERE save_id = ?",
            [.text(saveID)]
        ) { statement in
            PluginBrowserRequestRecord(
                saveID: PluginSQLRow.text(statement, 0) ?? "",
                pluginID: PluginSQLRow.text(statement, 1) ?? "",
                requestJSON: PluginSQLRow.text(statement, 2) ?? "{}",
                resultJSON: PluginSQLRow.text(statement, 3),
                createdAt: Date(timeIntervalSince1970: PluginSQLRow.double(statement, 4)),
                completedAt: PluginSQLRow.isNull(statement, 5)
                    ? nil
                    : Date(timeIntervalSince1970: PluginSQLRow.double(statement, 5)))
        }.first
    }

    /// The request a save still waits on, or nil when it was answered.
    public func pending(saveID: String) -> String? {
        guard let record = record(saveID: saveID), record.isPending else { return nil }
        return record.requestJSON
    }

    @discardableResult
    public func complete(saveID: String, resultJSON: String, now: Date = Date()) -> Bool {
        database()?.run(
            "UPDATE plugin_browser_requests SET result_json = ?, completed_at = ? "
                + "WHERE save_id = ?",
            [.text(resultJSON), .double(now.timeIntervalSince1970), .text(saveID)]) ?? false
    }

    /// The result, once and only once: the resume run reads it in place of
    /// presenting the modal again, and a later run must present rather than
    /// replay a stale page.
    public func takeResult(saveID: String) -> String? {
        guard let result = record(saveID: saveID)?.resultJSON else { return nil }
        clear(saveID: saveID)
        return result
    }

    @discardableResult
    public func clear(saveID: String) -> Bool {
        database()?.run(
            "DELETE FROM plugin_browser_requests WHERE save_id = ?", [.text(saveID)]) ?? false
    }
}
