//
//  WeeklyCloudDatabase.swift
//  LunaWeekly
//

import CloudKit
import Foundation
import LunaAppConfig
import LunaStorage

/// The whole CloudKit surface of this feature, behind one protocol.
///
/// Everything above this line is testable without a container, and the app is
/// free to run with no iCloud account, no network, and — until the portal step
/// in `claudedocs/save-of-the-week.md` — no container at all: every caller
/// reduces a thrown error to a no-op plus a `DiagnosticLog` line.
public protocol WeeklyCloudDatabase: Sendable {
    /// The current entry for each requested kind. A kind with no record is
    /// simply absent from the result.
    func fetchWeeklySaves(for kinds: [WeeklySaveKind]) async throws -> [WeeklySave]
    /// Writes (or overwrites) a kind's single record. Key-holder only.
    func saveWeekly(_ save: WeeklySave) async throws
    func fetchProposals() async throws -> [WeeklyProposal]
    func createProposal(_ proposal: WeeklyProposal) async throws
    func deleteProposal(recordName: String) async throws
    /// Whether an iCloud account is available — the one precondition a
    /// proposer can actually fix.
    func accountStatus() async throws -> Bool
}

/// Record type / field names. Written once so the dashboard schema in
/// `claudedocs/save-of-the-week.md` has exactly one source to match.
enum WeeklyCloudSchema {
    static let saveRecordType = "WeeklySave"
    static let proposalRecordType = "WeeklySaveProposal"
    static let kindField = "kind"
    static let urlField = "url"
    static let dateField = "date"
    static let signatureField = "signature"
}

/// The real client. Its `CKContainer` is created lazily on FIRST USE: building
/// one for a container the app isn't entitled to is fatal, and a unit test must
/// never reach this type at all (it injects a fake instead).
public final class CKWeeklyCloudDatabase: WeeklyCloudDatabase, @unchecked Sendable {
    public static let shared = CKWeeklyCloudDatabase()

    private let containerID: String
    private let lock = NSLock()
    private var cachedDatabase: CKDatabase?

    public init(containerID: String = AppConfig.cloudKitContainerID) {
        self.containerID = containerID
    }

    private var database: CKDatabase {
        lock.lock(); defer { lock.unlock() }
        if let cachedDatabase { return cachedDatabase }
        let database = CKContainer(identifier: containerID).publicCloudDatabase
        cachedDatabase = database
        return database
    }

    // MARK: - Weekly saves

    public func fetchWeeklySaves(for kinds: [WeeklySaveKind]) async throws -> [WeeklySave] {
        // One batched operation, not a round-trip per kind: the util card is
        // waiting on this at launch, so the kinds travel together and the
        // request is explicitly user-initiated — the convenience API's default
        // configuration is discretionary-eligible, which is exactly the "a
        // couple of seconds on good internet" the row used to sit out.
        let ids = kinds.map { CKRecord.ID(recordName: $0.recordName) }
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        operation.configuration.qualityOfService = .userInitiated
        let database = database
        return try await withCheckedThrowingContinuation { continuation in
            var results: [WeeklySave] = []
            var recordError: Error?
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    if let save = Self.weeklySave(from: record) { results.append(save) }
                case .failure(let error as CKError) where error.code == .unknownItem:
                    break   // no entry for this kind — not an error
                case .failure(let error):
                    recordError = error
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if let recordError {
                    continuation.resume(throwing: recordError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error as CKError) where error.code == .partialFailure:
                    // Only per-record failures, and every one of those was
                    // an unknownItem swallowed above.
                    continuation.resume(returning: results)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    public func saveWeekly(_ save: WeeklySave) async throws {
        let recordID = CKRecord.ID(recordName: save.kind.recordName)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(
                recordType: WeeklyCloudSchema.saveRecordType, recordID: recordID)
        }
        record[WeeklyCloudSchema.kindField] = save.kind.rawValue as CKRecordValue
        record[WeeklyCloudSchema.urlField] = save.urlString as CKRecordValue
        record[WeeklyCloudSchema.dateField] = save.date as CKRecordValue
        record[WeeklyCloudSchema.signatureField] = save.signature as CKRecordValue
        _ = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    // MARK: - Proposals

    public func fetchProposals() async throws -> [WeeklyProposal] {
        let query = CKQuery(
            recordType: WeeklyCloudSchema.proposalRecordType,
            predicate: NSPredicate(value: true))
        query.sortDescriptors = [
            NSSortDescriptor(key: WeeklyCloudSchema.dateField, ascending: false),
        ]
        let (matches, _) = try await database.records(matching: query)
        return matches.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return Self.proposal(from: record)
        }
    }

    public func createProposal(_ proposal: WeeklyProposal) async throws {
        let recordID = CKRecord.ID(recordName: proposal.recordName)
        let record = CKRecord(
            recordType: WeeklyCloudSchema.proposalRecordType, recordID: recordID)
        record[WeeklyCloudSchema.kindField] = proposal.kind.rawValue as CKRecordValue
        record[WeeklyCloudSchema.urlField] = proposal.urlString as CKRecordValue
        record[WeeklyCloudSchema.dateField] = proposal.date as CKRecordValue
        do {
            _ = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Same URL proposed again. The record name IS the dedup, so the
            // proposal already exists and there is nothing left to do.
            return
        }
    }

    public func deleteProposal(recordName: String) async throws {
        do {
            _ = try await database.modifyRecords(
                saving: [], deleting: [CKRecord.ID(recordName: recordName)])
        } catch let error as CKError where error.code == .unknownItem {
            return   // already gone
        }
    }

    public func accountStatus() async throws -> Bool {
        try await CKContainer(identifier: containerID).accountStatus() == .available
    }

    // MARK: - Record mapping

    static func weeklySave(from record: CKRecord) -> WeeklySave? {
        guard let rawKind = record[WeeklyCloudSchema.kindField] as? String,
              let kind = WeeklySaveKind(rawValue: rawKind),
              let url = record[WeeklyCloudSchema.urlField] as? String,
              let date = record[WeeklyCloudSchema.dateField] as? Date,
              let signature = record[WeeklyCloudSchema.signatureField] as? Data
        else { return nil }
        return WeeklySave(kind: kind, urlString: url, date: date, signature: signature)
    }

    static func proposal(from record: CKRecord) -> WeeklyProposal? {
        guard let rawKind = record[WeeklyCloudSchema.kindField] as? String,
              let kind = WeeklySaveKind(rawValue: rawKind),
              let url = record[WeeklyCloudSchema.urlField] as? String
        else { return nil }
        let date = record[WeeklyCloudSchema.dateField] as? Date ?? Date()
        return WeeklyProposal(
            recordName: record.recordID.recordName, kind: kind, urlString: url, date: date)
    }
}

/// Whether a thrown CloudKit error means "you are not signed into iCloud" —
/// the only failure a person can act on, so the only one worth an alert.
public func weeklyCloudErrorIsNotAuthenticated(_ error: Error) -> Bool {
    (error as? CKError)?.code == .notAuthenticated
}

/// Every CK call site funnels through here: log it, swallow it, carry on.
public func weeklyCloudLog(_ message: String) {
    DiagnosticLog.shared.record(message, category: "weekly")
}
