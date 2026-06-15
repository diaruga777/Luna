//
//  MessageTransport.swift
//  Clip
//

import Foundation

/// One undelivered message sitting in the shared database.
struct InboxRecord {
    /// Opaque server-side identifier used to delete the record after processing.
    let recordID: String
    let senderUUID: UUID
    /// The sealed (encrypted + signed) envelope.
    let payload: Data
}

/// Whether messaging is currently possible (maps CloudKit account status).
enum MessagingAvailability {
    case available
    /// User isn't signed into iCloud (or restricted) — sends/receives fail.
    case unavailable(reason: String)
}

/// Moves sealed payloads between users. The production implementation is the
/// CloudKit public database; tests use an in-memory mock.
protocol MessageTransport {
    /// Writes one message addressed to `recipientUUID`.
    func send(payload: Data, to recipientUUID: UUID, from senderUUID: UUID) async throws
    /// All undelivered messages addressed to `recipientUUID`.
    func fetchInbox(for recipientUUID: UUID) async throws -> [InboxRecord]
    /// Removes a processed message. Implementations treat "already gone" as
    /// success (another device may have processed it first).
    func delete(recordID: String) async throws
    /// Installs the server-side subscription that pings this client when a
    /// message arrives for `recipientUUID`. Safe to call on every launch.
    func ensureSubscription(for recipientUUID: UUID) async throws
    /// Reconstructs an inbox record from a push payload when the subscription
    /// carried the record's fields along (no fetch needed). Returns nil if the
    /// push didn't include them — the caller should fall back to `fetchInbox`.
    func inboxRecord(fromPush userInfo: [AnyHashable: Any]) -> InboxRecord?
    /// Current account availability for messaging.
    func availability() async -> MessagingAvailability
}

/// In-memory transport for tests: records live in an array, sends are
/// captured, deletes are idempotent.
final class InMemoryMessageTransport: MessageTransport {
    struct StoredMessage {
        let recordID: String
        let recipientUUID: UUID
        let senderUUID: UUID
        let payload: Data
    }

    private(set) var messages: [StoredMessage] = []
    private(set) var deletedRecordIDs: [String] = []
    private(set) var subscribedUUIDs: [UUID] = []
    var sendError: Error?
    /// Simulates the public DB query-index lag a push can outrun: the next
    /// this-many `fetchInbox` calls return empty before stored messages become
    /// visible.
    var emptyFetchesBeforeVisible = 0
    private(set) var fetchInboxCallCount = 0
    /// When set, `inboxRecord(fromPush:)` returns this — simulating a push that
    /// carried the record's fields.
    var pushRecord: InboxRecord?

    func send(payload: Data, to recipientUUID: UUID, from senderUUID: UUID) async throws {
        if let sendError { throw sendError }
        messages.append(StoredMessage(
            recordID: UUID().uuidString, recipientUUID: recipientUUID,
            senderUUID: senderUUID, payload: payload))
    }

    func fetchInbox(for recipientUUID: UUID) async throws -> [InboxRecord] {
        fetchInboxCallCount += 1
        if emptyFetchesBeforeVisible > 0 {
            emptyFetchesBeforeVisible -= 1
            return []
        }
        return messages
            .filter { $0.recipientUUID == recipientUUID }
            .map { InboxRecord(recordID: $0.recordID, senderUUID: $0.senderUUID, payload: $0.payload) }
    }

    func delete(recordID: String) async throws {
        deletedRecordIDs.append(recordID)
        messages.removeAll { $0.recordID == recordID }
    }

    func ensureSubscription(for recipientUUID: UUID) async throws {
        subscribedUUIDs.append(recipientUUID)
    }

    func inboxRecord(fromPush userInfo: [AnyHashable: Any]) -> InboxRecord? { pushRecord }

    func availability() async -> MessagingAvailability { .available }
}
