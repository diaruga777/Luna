//
//  SaveRow.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// Rows ↔ `SavedItem`: the only place that knows which column holds which
/// field.
///
/// Reads are TOLERANT of a value this binary does not recognise, because four
/// independently-updated apps write this one file: an unknown state reads as
/// `.pending` (the item is re-ingested rather than mislabelled ready), an unknown
/// read state as `.unopened`, and an unknown reader mode / platform / capture
/// source / send state as absent. A row whose id is not a UUID is skipped and
/// logged — it is the one field nothing can be reconstructed without.
enum SaveRow {

    // MARK: - saves

    /// The column list every read of `saves` uses, so the indexes below line up
    /// with one another.
    static let columns = """
        id, seq, url_string, title, date_added, archived_at, pending_archive_at, \
        bump_date, state, read_state, last_reader_mode, content_file_name, \
        original_archive_file_name, thumbnail_file_name, document_type, \
        last_word_index, last_scroll_offset, last_original_scroll_offset, \
        last_spoken_word_index, word_count, reading_progress, sender_name, \
        incoming_sender_email, shared_by_username, last_save_attempt_date, \
        platform, platform_item_id, capture_source, plugin_id, original_url_string
        """

    /// One `saves` row as an item, with its send states and price tracker still
    /// empty — `SavesStore` fills those from the child tables.
    static func item(from row: SavesStatement) -> SavedItem? {
        guard let rawID = row.string(0), let id = UUID(uuidString: rawID) else {
            SharedDiagnosticLog.record("skipped a save row with an unreadable id", category: "store")
            return nil
        }
        var item = SavedItem(urlString: row.string(2) ?? "", id: id)
        item.title = row.string(3)
        item.dateAdded = row.date(4) ?? Date(timeIntervalSinceReferenceDate: 0)
        item.archivedAt = row.date(5)
        item.pendingArchiveAt = row.date(6)
        item.bumpDate = row.date(7)
        item.state = row.string(8).flatMap(SavedItem.State.init(rawValue:)) ?? .pending
        item.readState = row.string(9).flatMap(SavedItem.ReadState.init(rawValue:)) ?? .unopened
        item.lastReaderMode = row.string(10).flatMap(SavedItem.ReaderMode.init(rawValue:))
        item.contentFileName = row.string(11)
        item.originalArchiveFileName = row.string(12)
        item.thumbnailFileName = row.string(13)
        item.documentType = row.string(14)
        item.lastWordIndex = row.int(15)
        item.lastScrollOffset = row.double(16)
        item.lastOriginalScrollOffset = row.double(17)
        item.lastSpokenWordIndex = row.int(18)
        item.wordCount = row.int(19)
        item.readingProgress = row.double(20)
        item.senderName = row.string(21)
        item.incomingSenderEmail = row.string(22)
        item.sharedByUsername = row.string(23)
        item.lastSaveAttemptDate = row.date(24)
        item.platform = row.string(25).flatMap(ContentPlatform.init(rawValue:))
        item.platformItemID = row.string(26)
        item.captureSource = row.string(27).flatMap(CaptureSource.init(rawValue:))
        item.pluginID = row.string(28)
        item.originalURLString = row.string(29)
        return item
    }

    /// Inserts the save, or replaces every column of the row already under its id.
    static let upsertSQL = """
        INSERT INTO saves (\(columns)) VALUES (\(Array(repeating: "?", count: 30).joined(separator: ", ")))
        ON CONFLICT(id) DO UPDATE SET
            seq = excluded.seq,
            url_string = excluded.url_string,
            title = excluded.title,
            date_added = excluded.date_added,
            archived_at = excluded.archived_at,
            pending_archive_at = excluded.pending_archive_at,
            bump_date = excluded.bump_date,
            state = excluded.state,
            read_state = excluded.read_state,
            last_reader_mode = excluded.last_reader_mode,
            content_file_name = excluded.content_file_name,
            original_archive_file_name = excluded.original_archive_file_name,
            thumbnail_file_name = excluded.thumbnail_file_name,
            document_type = excluded.document_type,
            last_word_index = excluded.last_word_index,
            last_scroll_offset = excluded.last_scroll_offset,
            last_original_scroll_offset = excluded.last_original_scroll_offset,
            last_spoken_word_index = excluded.last_spoken_word_index,
            word_count = excluded.word_count,
            reading_progress = excluded.reading_progress,
            sender_name = excluded.sender_name,
            incoming_sender_email = excluded.incoming_sender_email,
            shared_by_username = excluded.shared_by_username,
            last_save_attempt_date = excluded.last_save_attempt_date,
            platform = excluded.platform,
            platform_item_id = excluded.platform_item_id,
            capture_source = excluded.capture_source,
            plugin_id = excluded.plugin_id,
            original_url_string = excluded.original_url_string
        """

    static func bind(_ item: SavedItem, seq: Int64, to row: SavesStatement) throws {
        try row.bind(1, uuid: item.id)
        try row.bind(2, seq)
        try row.bind(3, item.urlString)
        try row.bind(4, item.title)
        try row.bind(5, date: item.dateAdded)
        try row.bind(6, date: item.archivedAt)
        try row.bind(7, date: item.pendingArchiveAt)
        try row.bind(8, date: item.bumpDate)
        try row.bind(9, item.state.rawValue)
        try row.bind(10, item.readState.rawValue)
        try row.bind(11, item.lastReaderMode?.rawValue)
        try row.bind(12, item.contentFileName)
        try row.bind(13, item.originalArchiveFileName)
        try row.bind(14, item.thumbnailFileName)
        try row.bind(15, item.documentType)
        try row.bind(16, item.lastWordIndex)
        try row.bind(17, item.lastScrollOffset)
        try row.bind(18, item.lastOriginalScrollOffset)
        try row.bind(19, item.lastSpokenWordIndex)
        try row.bind(20, item.wordCount)
        try row.bind(21, item.readingProgress)
        try row.bind(22, item.senderName)
        try row.bind(23, item.incomingSenderEmail)
        try row.bind(24, item.sharedByUsername)
        try row.bind(25, date: item.lastSaveAttemptDate)
        try row.bind(26, item.platform?.rawValue)
        try row.bind(27, item.platformItemID)
        try row.bind(28, item.captureSource?.rawValue)
        try row.bind(29, item.pluginID)
        try row.bind(30, item.originalURLString)
    }

    // MARK: - send_states

    static let sendStateColumns =
        "save_id, destination, state, date_sent, failure_count, next_attempt_date, last_error, " +
        "queued_while_read, remote_name, remote_status"

    static let insertSendStateSQL = """
        INSERT INTO send_states (\(sendStateColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    /// Folds one `send_states` row into the dictionaries the model exposes.
    /// A raw value this binary does not know (a state, or `remote_status`)
    /// leaves that one dictionary entry alone — the destination's other
    /// bookkeeping still reads.
    static func applySendState(from row: SavesStatement, to item: inout SavedItem) {
        guard let destination = row.string(1) else { return }
        if let state = row.string(2).flatMap(SavedItem.SendState.init(rawValue:)) {
            item.sendStates[destination] = state
        }
        if let dateSent = row.date(3) { item.datesSent[destination] = dateSent }
        if let failureCount = row.int(4) { item.sendFailureCounts[destination] = failureCount }
        if let nextAttempt = row.date(5) { item.sendNextAttemptDates[destination] = nextAttempt }
        if let lastError = row.string(6) { item.sendLastErrors[destination] = lastError }
        if let queuedWhileRead = row.int(7) { item.sendQueuedWhileRead[destination] = queuedWhileRead != 0 }
        if let remoteName = row.string(8) { item.sendRemoteNames[destination] = remoteName }
        if let remoteStatus = row.string(9).flatMap(SavedItem.RemoteDeleteStatus.init(rawValue:)) {
            item.sendRemoteStatuses[destination] = remoteStatus
        }
    }

    /// Every destination the save has any send bookkeeping for.
    static func sendDestinations(of item: SavedItem) -> [String] {
        var destinations = Set(item.sendStates.keys)
        destinations.formUnion(item.datesSent.keys)
        destinations.formUnion(item.sendFailureCounts.keys)
        destinations.formUnion(item.sendNextAttemptDates.keys)
        destinations.formUnion(item.sendLastErrors.keys)
        destinations.formUnion(item.sendQueuedWhileRead.keys)
        destinations.formUnion(item.sendRemoteNames.keys)
        destinations.formUnion(item.sendRemoteStatuses.keys)
        return destinations.sorted()
    }

    static func bindSendState(
        _ item: SavedItem, destination: String, to row: SavesStatement
    ) throws {
        try row.bind(1, uuid: item.id)
        try row.bind(2, destination)
        try row.bind(3, item.sendStates[destination]?.rawValue)
        try row.bind(4, date: item.datesSent[destination])
        try row.bind(5, item.sendFailureCounts[destination])
        try row.bind(6, date: item.sendNextAttemptDates[destination])
        try row.bind(7, item.sendLastErrors[destination])
        try row.bind(8, item.sendQueuedWhileRead[destination].map { $0 ? 1 : 0 })
        try row.bind(9, item.sendRemoteNames[destination])
        try row.bind(10, item.sendRemoteStatuses[destination]?.rawValue)
    }

    // MARK: - price_trackers

    static let trackerColumns = """
        save_id, product_name, brand, product_id, identifier_gtin, identifier_mpn, \
        identifier_sku, identifier_brand, image_file_name, initial_price, \
        initial_currency, alert_threshold_fraction, is_archived, alert_acknowledged_at, \
        pending_comparison_source_url, pending_comparison_started_at, \
        pending_comparison_threshold_at_start
        """

    static let insertTrackerSQL = """
        INSERT INTO price_trackers (\(trackerColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static func bindTracker(
        _ tracker: PriceTracker, saveID: UUID, to row: SavesStatement
    ) throws {
        try row.bind(1, uuid: saveID)
        try row.bind(2, tracker.productName)
        try row.bind(3, tracker.brand)
        try row.bind(4, tracker.productID)
        try row.bind(5, tracker.identifiers.gtin)
        try row.bind(6, tracker.identifiers.mpn)
        try row.bind(7, tracker.identifiers.sku)
        try row.bind(8, tracker.identifiers.brand)
        try row.bind(9, tracker.imageFileName)
        try row.bind(10, decimal: tracker.initialPrice)
        try row.bind(11, tracker.initialCurrency)
        try row.bind(12, tracker.alertThresholdFraction)
        try row.bind(13, tracker.isArchived)
        try row.bind(14, date: tracker.alertAcknowledgedAt)
        try row.bind(15, tracker.pendingComparison?.sourceURLString)
        try row.bind(16, date: tracker.pendingComparison?.startedAt)
        try row.bind(17, tracker.pendingComparison?.thresholdFractionAtStart)
    }

    /// A `price_trackers` row plus the stores already read for it. `stores` is
    /// empty only for a malformed row; the model repairs that invariant itself.
    static func tracker(
        from row: SavesStatement, stores: [PriceTrackerStore], rejectedHosts: [String]
    ) -> PriceTracker {
        var pending: PriceTracker.PendingSellerComparison?
        if let sourceURL = row.string(14), let startedAt = row.date(15) {
            pending = PriceTracker.PendingSellerComparison(
                sourceURLString: sourceURL, startedAt: startedAt,
                thresholdFractionAtStart: row.double(16))
        }
        return PriceTracker.stored(
            productName: row.string(1) ?? "",
            stores: stores,
            brand: row.string(2),
            productID: row.string(3),
            identifiers: ProductIdentifiers(
                gtin: row.string(4), mpn: row.string(5),
                sku: row.string(6), brand: row.string(7)),
            imageFileName: row.string(8),
            initialPrice: row.decimal(9) ?? 0,
            initialCurrency: row.string(10) ?? "USD",
            alertThresholdFraction: row.double(11),
            isArchived: row.bool(12),
            alertAcknowledgedAt: row.date(13),
            pendingComparison: pending,
            rejectedSellerHosts: rejectedHosts)
    }

    // MARK: - tracker_stores / tracker_price_points

    static let storeColumns =
        "id, save_id, position, url_string, last_price, currency, last_refreshed, plugin_id"

    static let insertStoreSQL = """
        INSERT INTO tracker_stores
            (save_id, position, url_string, last_price, currency, last_refreshed, plugin_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """

    static func bindStore(
        _ store: PriceTrackerStore, saveID: UUID, position: Int, to row: SavesStatement
    ) throws {
        try row.bind(1, uuid: saveID)
        try row.bind(2, position)
        try row.bind(3, store.urlString)
        try row.bind(4, decimal: store.lastPrice)
        try row.bind(5, store.currency)
        try row.bind(6, date: store.lastRefreshed)
        try row.bind(7, store.pluginID)
    }

    static func store(from row: SavesStatement, priceHistory: [PriceDaySnapshot]) -> PriceTrackerStore {
        PriceTrackerStore(
            urlString: row.string(3) ?? "",
            lastPrice: row.decimal(4),
            currency: row.string(5) ?? "USD",
            lastRefreshed: row.date(6),
            priceHistory: priceHistory,
            pluginID: row.string(7))
    }

    static let pricePointColumns = "store_id, day, lowest_price, currency, fx_rate"

    static let insertPricePointSQL = """
        INSERT INTO tracker_price_points (\(pricePointColumns)) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(store_id, day) DO UPDATE SET
            lowest_price = excluded.lowest_price,
            currency = excluded.currency,
            fx_rate = excluded.fx_rate
        """

    static func bindPricePoint(
        _ point: PriceDaySnapshot, storeID: Int64, to row: SavesStatement
    ) throws {
        try row.bind(1, storeID)
        try row.bind(2, date: point.dayStart)
        try row.bind(3, decimal: point.lowestPrice)
        try row.bind(4, point.currency)
        try row.bind(5, decimal: point.fxRate)
    }

    static func pricePoint(from row: SavesStatement) -> PriceDaySnapshot? {
        guard let day = row.date(1), let lowest = row.decimal(2) else { return nil }
        return PriceDaySnapshot(
            dayStart: day, lowestPrice: lowest,
            currency: row.string(3) ?? "USD", fxRate: row.decimal(4))
    }
}
