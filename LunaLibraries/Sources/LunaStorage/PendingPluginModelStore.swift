//
//  PendingPluginModelStore.swift
//  LunaStorage
//

import Foundation

/// A Model the Safari content script produced, waiting for the app to adopt it
/// (`claudedocs/plans/plugin-platform.md` §12, §13.1).
///
/// Safari can neither write a save nor start a download, so it hands the Model
/// over and deep-links the app, which drains this table. `modelJSON` is the
/// Model exactly as the plugin returned it, decoded by the app.
public struct PendingPluginModel: Equatable, Sendable {
    public let id: String
    public let urlString: String
    public let originalURLString: String?
    public let modelJSON: String
    public let pluginID: String
    public let createdAt: Date
    /// How long the app may bounce back to Safari after draining this row.
    public let returnToSourceUntil: Date?

    public init(
        id: String = UUID().uuidString, urlString: String, modelJSON: String,
        pluginID: String, createdAt: Date = Date(), returnToSourceUntil: Date? = nil,
        originalURLString: String? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.originalURLString = originalURLString
        self.modelJSON = modelJSON
        self.pluginID = pluginID
        self.createdAt = createdAt
        self.returnToSourceUntil = returnToSourceUntil
    }
}

/// The `pending_plugin_models` table. Take-semantics: draining removes the rows,
/// so the app adopts each Model once however many times it is foregrounded.
///
/// It lives in LunaStorage rather than LunaPluginKit for the same reason
/// `PluginBrowserRequestStore` does — the rows are in `saves.sqlite`, and one
/// process opens one connection to that file.
public final class PendingPluginModelStore {
    public static let shared = PendingPluginModelStore()

    /// A Safari hand-off the user never returns for is scratch. CDN URLs inside
    /// a media Model die within hours anyway.
    public static let lifetime: TimeInterval = 60 * 60

    private let saves: SavesStore

    public init(saves: SavesStore = .shared) {
        self.saves = saves
    }

    public func put(_ model: PendingPluginModel) {
        saves.pluginSidecar { db in
            try db.run(
                """
                INSERT OR REPLACE INTO pending_plugin_models
                    (id, url, model_json, plugin_id, created_at, return_to_source_until, original_url)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            ) { row in
                try row.bind(1, model.id)
                try row.bind(2, model.urlString)
                try row.bind(3, model.modelJSON)
                try row.bind(4, model.pluginID)
                try row.bind(5, date: model.createdAt)
                try row.bind(6, date: model.returnToSourceUntil)
                try row.bind(7, model.originalURLString)
            }
        }
    }

    /// Every unexpired row, oldest first, removing all of them. Expired rows are
    /// dropped in passing.
    public func takeAll(now: Date = Date()) -> [PendingPluginModel] {
        let rows = peek(now: now)
        saves.pluginSidecar { db in try db.run("DELETE FROM pending_plugin_models") }
        return rows
    }

    /// Non-destructive read, for diagnostics and tests.
    public func peek(now: Date = Date()) -> [PendingPluginModel] {
        saves.pluginSidecar { db in
            var rows: [PendingPluginModel] = []
            try db.query(
                """
                SELECT id, url, model_json, plugin_id, created_at, return_to_source_until, original_url
                FROM pending_plugin_models ORDER BY created_at
                """
            ) { row in
                guard let id = row.string(0), let url = row.string(1),
                      let json = row.string(2), let pluginID = row.string(3)
                else { return }
                let createdAt = row.date(4) ?? now
                guard now.timeIntervalSince(createdAt) < Self.lifetime else { return }
                rows.append(PendingPluginModel(
                    id: id, urlString: url, modelJSON: json, pluginID: pluginID,
                    createdAt: createdAt, returnToSourceUntil: row.date(5), originalURLString: row.string(6)))
            }
            return rows
        } ?? []
    }

    public func clear() {
        saves.pluginSidecar { db in try db.run("DELETE FROM pending_plugin_models") }
    }
}
