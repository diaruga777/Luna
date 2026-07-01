//
//  MessageTransport.swift
//  Luna
//

import Foundation

/// One undelivered message sitting in the shared database.
public struct InboxRecord {
    /// Opaque server-side identifier used to delete the record after processing.
    public let recordID: String
    public let senderUUID: UUID
    /// The sealed (encrypted + signed) envelope.
    public let payload: Data
}

/// Whether messaging is currently possible (maps CloudKit account status).
public enum MessagingAvailability {
    case available
    /// User isn't signed into iCloud (or restricted) — sends/receives fail.
    case unavailable(reason: String)
}

/// Moves sealed payloads between users. The production implementation is the
/// CloudKit public database; tests use an in-memory mock.
public protocol MessageTransport {
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
    /// The record name the push notification referenced, if any (lets the
    /// client fetch that exact record by ID — strongly consistent — instead of
    /// querying the eventually-consistent index).
    func recordID(fromPush userInfo: [AnyHashable: Any]) -> String?
    /// Strongly-consistent fetch of one record by its name. nil if it's gone or
    /// missing required fields.
    func fetchRecord(recordID: String) async throws -> InboxRecord?
    /// Current account availability for messaging.
    func availability() async -> MessagingAvailability
}

/// In-memory transport for tests: records live in an array, sends are
/// captured, deletes are idempotent.
public final class InMemoryMessageTransport: MessageTransport {
    public struct StoredMessage {
        public let recordID: String
        public let recipientUUID: UUID
        public let senderUUID: UUID
        public let payload: Data
    }

    public init() {}

    public private(set) var messages: [StoredMessage] = []
    public private(set) var deletedRecordIDs: [String] = []
    public private(set) var subscribedUUIDs: [UUID] = []
    public var sendError: Error?
    /// Simulates the public DB query-index lag a push can outrun: the next
    /// this-many `fetchInbox` calls return empty before stored messages become
    /// visible.
    public var emptyFetchesBeforeVisible = 0
    public private(set) var fetchInboxCallCount = 0
    /// `recordID(fromPush:)` returns this; `fetchRecord` returns the matching
    /// stored message (simulating the strongly-consistent fetch-by-ID).
    public var pushRecordID: String?

    public func send(payload: Data, to recipientUUID: UUID, from senderUUID: UUID) async throws {
        if let sendError { throw sendError }
        messages.append(StoredMessage(
            recordID: UUID().uuidString, recipientUUID: recipientUUID,
            senderUUID: senderUUID, payload: payload))
    }

    public func fetchInbox(for recipientUUID: UUID) async throws -> [InboxRecord] {
        fetchInboxCallCount += 1
        if emptyFetchesBeforeVisible > 0 {
            emptyFetchesBeforeVisible -= 1
            return []
        }
        return messages
            .filter { $0.recipientUUID == recipientUUID }
            .map { InboxRecord(recordID: $0.recordID, senderUUID: $0.senderUUID, payload: $0.payload) }
    }

    public func delete(recordID: String) async throws {
        deletedRecordIDs.append(recordID)
        messages.removeAll { $0.recordID == recordID }
    }

    public func ensureSubscription(for recipientUUID: UUID) async throws {
        subscribedUUIDs.append(recipientUUID)
    }

    public func recordID(fromPush userInfo: [AnyHashable: Any]) -> String? { pushRecordID }

    public func fetchRecord(recordID: String) async throws -> InboxRecord? {
        messages.first { $0.recordID == recordID }
            .map { InboxRecord(recordID: $0.recordID, senderUUID: $0.senderUUID, payload: $0.payload) }
    }

    public func availability() async -> MessagingAvailability { .available }
}
