//
//  PluginBrowserRequestStore.swift
//  LunaStorage
//

import Foundation

/// One `luna.browser.open` call a process could not present.
///
/// `requestJSON` and `resultJSON` are opaque here on purpose: the shapes belong
/// to the bridge that wrote them, and this tier only has to hand the same bytes
/// back. `resultJSON` nil means the save is still locked.
public struct PluginBrowserRequestRecord: Equatable, Sendable {
    public let saveID: UUID
    public let pluginID: String
    public let requestJSON: String
    public let resultJSON: String?
    public let createdAt: Date
    public let completedAt: Date?

    public init(
        saveID: UUID, pluginID: String, requestJSON: String, resultJSON: String? = nil,
        createdAt: Date = Date(), completedAt: Date? = nil
    ) {
        self.saveID = saveID
        self.pluginID = pluginID
        self.requestJSON = requestJSON
        self.resultJSON = resultJSON
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// The `plugin_browser_requests` table (`claudedocs/plans/plugin-platform.md`
/// §8.1).
///
/// An extension and the Safari world both defer a browser request: they write
/// the row, lock the save, and the app presents the modal later and writes the
/// result back. The row cascades away with its save.
///
/// It lives here rather than in LunaPluginKit because the rows are in
/// `saves.sqlite`, and one process opens one connection to that file. Going
/// through `SavesStore` shares that connection instead of opening a second.
public final class PluginBrowserRequestStore {
    public static let shared = PluginBrowserRequestStore()

    private let saves: SavesStore

    public init(saves: SavesStore = .shared) {
        self.saves = saves
    }

    /// Records a deferred request, replacing any earlier one for the same save.
    /// The replacement drops a stale result too: a new request is a new question.
    public func put(saveID: UUID, pluginID: String, requestJSON: String, now: Date = Date()) {
        saves.pluginSidecar { db in
            try db.run(
                """
                INSERT INTO plugin_browser_requests
                    (save_id, plugin_id, request_json, result_json, created_at, completed_at)
                VALUES (?, ?, ?, NULL, ?, NULL)
                ON CONFLICT(save_id) DO UPDATE SET
                    plugin_id = excluded.plugin_id,
                    request_json = excluded.request_json,
                    result_json = NULL,
                    created_at = excluded.created_at,
                    completed_at = NULL
                """
            ) { row in
                try row.bind(1, uuid: saveID)
                try row.bind(2, pluginID)
                try row.bind(3, requestJSON)
                try row.bind(4, date: now)
            }
        }
    }

    /// The request still waiting for a browser step, or nil when there is none
    /// or one already completed.
    public func pending(for saveID: UUID) -> PluginBrowserRequestRecord? {
        guard let record = record(for: saveID) else { return nil }
        return record.resultJSON == nil ? record : nil
    }

    /// The row as stored, completed or not.
    public func record(for saveID: UUID) -> PluginBrowserRequestRecord? {
        saves.pluginSidecar { db in
            var found: PluginBrowserRequestRecord?
            try db.query(
                """
                SELECT save_id, plugin_id, request_json, result_json, created_at, completed_at
                FROM plugin_browser_requests WHERE save_id = ?
                """,
                { try $0.bind(1, uuid: saveID) }
            ) { row in
                guard let idText = row.string(0), let id = UUID(uuidString: idText),
                      let pluginID = row.string(1), let requestJSON = row.string(2)
                else { return }
                found = PluginBrowserRequestRecord(
                    saveID: id, pluginID: pluginID, requestJSON: requestJSON,
                    resultJSON: row.string(3),
                    createdAt: row.date(4) ?? Date(),
                    completedAt: row.date(5))
            }
            return found
        } ?? nil
    }

    /// Writes the browser's answer. The save stays locked until something takes
    /// the result and re-runs the plugin.
    public func complete(saveID: UUID, resultJSON: String, now: Date = Date()) {
        saves.pluginSidecar { db in
            try db.run(
                """
                UPDATE plugin_browser_requests
                SET result_json = ?, completed_at = ? WHERE save_id = ?
                """
            ) { row in
                try row.bind(1, resultJSON)
                try row.bind(2, date: now)
                try row.bind(3, uuid: saveID)
            }
        }
    }

    /// Single use: returns the stored result and clears it, so a plugin that
    /// asks for the same browser step twice presents the modal the second time
    /// rather than replaying an old answer.
    public func takeResult(saveID: UUID) -> String? {
        let result = record(for: saveID)?.resultJSON
        if result != nil { clear(saveID: saveID) }
        return result
    }

    public func clear(saveID: UUID) {
        saves.pluginSidecar { db in
            try db.run("DELETE FROM plugin_browser_requests WHERE save_id = ?") {
                try $0.bind(1, uuid: saveID)
            }
        }
    }
}
