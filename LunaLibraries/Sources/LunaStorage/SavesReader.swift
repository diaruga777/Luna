//
//  SavesReader.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// The queries `ReadingListStore` reads through. Each one names the store call it
/// serves; the indexes it relies on are listed in `SavesSchema`.
///
/// A save is assembled from up to five tables, so every read here runs a fixed
/// number of statements whatever the list's length — the child rows are collected
/// once and stitched onto the saves in memory rather than queried per save.
enum SavesReader {

    /// The whole list in its own order — `items()`.
    static func allItems(in db: SavesDatabase) throws -> [ReadingListItem] {
        var saves: [StoredSave] = []
        try db.query("SELECT \(SaveRow.columns) FROM saves ORDER BY seq DESC, id ASC") { row in
            guard let item = SaveRow.item(from: row) else { return }
            saves.append(StoredSave(item: item, seq: row.int64(1)))
        }
        try hydrate(&saves, saveID: nil, in: db)
        return saves.map(\.item)
    }

    /// One save by id — the read every targeted mutation starts from.
    static func item(id: UUID, in db: SavesDatabase) throws -> StoredSave? {
        var saves: [StoredSave] = []
        try db.query("SELECT \(SaveRow.columns) FROM saves WHERE id = ?", { statement in
            try statement.bind(1, uuid: id)
        }) { row in
            guard let item = SaveRow.item(from: row) else { return }
            saves.append(StoredSave(item: item, seq: row.int64(1)))
        }
        try hydrate(&saves, saveID: id, in: db)
        return saves.first
    }

    /// The save holding this URL, frontmost first — the insert paths' dedup.
    static func item(forURLString urlString: String, in db: SavesDatabase) throws -> StoredSave? {
        var saves: [StoredSave] = []
        try db.query(
            "SELECT \(SaveRow.columns) FROM saves WHERE url_string = ? ORDER BY seq DESC LIMIT 1",
            { statement in try statement.bind(1, urlString) }
        ) { row in
            guard let item = SaveRow.item(from: row) else { return }
            saves.append(StoredSave(item: item, seq: row.int64(1)))
        }
        guard let first = saves.first else { return nil }
        try hydrate(&saves, saveID: first.item.id, in: db)
        return saves.first
    }

    /// Whether some OTHER save already holds this URL — `updateURL`'s duplicate
    /// test.
    static func urlIsTaken(_ urlString: String, excluding itemID: UUID, in db: SavesDatabase) throws -> Bool {
        var found = false
        try db.query(
            "SELECT 1 FROM saves WHERE url_string = ? AND id != ? LIMIT 1",
            { statement in
                try statement.bind(1, urlString)
                try statement.bind(2, uuid: itemID)
            }
        ) { _ in found = true }
        return found
    }

    /// The reader-completed saves waiting for the next lifecycle boundary —
    /// `archivePendingFinishedItems`.
    static func itemsWithPendingArchive(in db: SavesDatabase) throws -> [StoredSave] {
        var saves: [StoredSave] = []
        try db.query(
            "SELECT \(SaveRow.columns) FROM saves WHERE pending_archive_at IS NOT NULL"
        ) { row in
            guard let item = SaveRow.item(from: row) else { return }
            saves.append(StoredSave(item: item, seq: row.int64(1)))
        }
        // These rows only need their own columns rewritten, so the child tables
        // are read per save rather than in bulk — the set is small (the saves
        // finished in one foreground session).
        for index in saves.indices {
            var one = [saves[index]]
            try hydrate(&one, saveID: saves[index].item.id, in: db)
            saves[index] = one[0]
        }
        return saves
    }

    /// The saves whose tracker already watches this seller page —
    /// `priceTracker(containingStoreURL:)`.
    static func saveIDs(trackingStoreURL urlString: String, in db: SavesDatabase) throws -> [UUID] {
        var ids: [UUID] = []
        try db.query(
            "SELECT save_id FROM tracker_stores WHERE url_string = ?",
            { statement in try statement.bind(1, urlString) }
        ) { row in
            if let id = row.string(0).flatMap(UUID.init(uuidString:)) { ids.append(id) }
        }
        return ids
    }

    /// The rowid of one stored seller listing, so its price points can reference it.
    static func storeID(saveID: UUID, urlString: String, in db: SavesDatabase) throws -> Int64? {
        var found: Int64?
        try db.query(
            "SELECT id FROM tracker_stores WHERE save_id = ? AND url_string = ?",
            { statement in
                try statement.bind(1, uuid: saveID)
                try statement.bind(2, urlString)
            }
        ) { row in
            if found == nil { found = row.int64(0) }
        }
        return found
    }

    /// The highest list position in use (0 for an empty list).
    static func maxSeq(in db: SavesDatabase) throws -> Int64 {
        try db.scalarInt("SELECT COALESCE(MAX(seq), 0) FROM saves") ?? 0
    }

    /// The position a save moving to the front takes.
    static func nextSeq(in db: SavesDatabase) throws -> Int64 {
        try maxSeq(in: db) + 1
    }

    // MARK: - Child rows

    /// Fills in the send bookkeeping and the price tracker for `saves`. `saveID`
    /// narrows every child query to one save; nil reads the child tables whole,
    /// which is what makes a full list read a fixed five statements.
    private static func hydrate(
        _ saves: inout [StoredSave], saveID: UUID?, in db: SavesDatabase
    ) throws {
        guard !saves.isEmpty else { return }
        var indexByID: [UUID: Int] = [:]
        for (index, save) in saves.enumerated() { indexByID[save.item.id] = index }
        let filter = saveID == nil ? "" : " WHERE save_id = ?"
        let bindSaveID: (SavesStatement) throws -> Void = { statement in
            if let saveID { try statement.bind(1, uuid: saveID) }
        }

        try db.query("SELECT \(SaveRow.sendStateColumns) FROM send_states\(filter)", bindSaveID) { row in
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)),
                  let index = indexByID[id] else { return }
            SaveRow.applySendState(from: row, to: &saves[index].item)
        }

        // Price points first: each seller listing carries its own day buckets,
        // oldest-first, which is the order the graph and the merge logic expect.
        var pointsByStore: [Int64: [PriceDaySnapshot]] = [:]
        let pointsSQL = saveID == nil
            ? "SELECT \(SaveRow.pricePointColumns) FROM tracker_price_points ORDER BY store_id, day"
            : """
              SELECT \(SaveRow.pricePointColumns) FROM tracker_price_points
              WHERE store_id IN (SELECT id FROM tracker_stores WHERE save_id = ?)
              ORDER BY store_id, day
              """
        try db.query(pointsSQL, bindSaveID) { row in
            guard let point = SaveRow.pricePoint(from: row) else { return }
            pointsByStore[row.int64(0), default: []].append(point)
        }

        var storesBySave: [UUID: [PriceTrackerStore]] = [:]
        try db.query(
            "SELECT \(SaveRow.storeColumns) FROM tracker_stores\(filter) ORDER BY save_id, position",
            bindSaveID
        ) { row in
            guard let id = row.string(1).flatMap(UUID.init(uuidString:)) else { return }
            let store = SaveRow.store(from: row, priceHistory: pointsByStore[row.int64(0)] ?? [])
            storesBySave[id, default: []].append(store)
        }

        var rejectedBySave: [UUID: [String]] = [:]
        try db.query("SELECT save_id, host FROM tracker_rejected_sellers\(filter)", bindSaveID) { row in
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)),
                  let host = row.string(1) else { return }
            rejectedBySave[id, default: []].append(host)
        }

        try db.query("SELECT \(SaveRow.trackerColumns) FROM price_trackers\(filter)", bindSaveID) { row in
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)),
                  let index = indexByID[id] else { return }
            saves[index].item.priceTracker = SaveRow.tracker(
                from: row, stores: storesBySave[id] ?? [], rejectedHosts: rejectedBySave[id] ?? [])
        }
    }
}
