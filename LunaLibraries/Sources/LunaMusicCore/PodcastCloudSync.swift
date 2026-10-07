import CloudKit
import Foundation
import LunaPodcastCore

/// A private iCloud record, with an asset for the growing library and optimistic
/// conflict retries. Media files and this device's transport queue stay local.
@MainActor public final class PodcastCloudSync {
    public static let shared = PodcastCloudSync()
    public private(set) var lastError: String?
    private var inFlight = false
    private init() {}
    public func synchronize() async throws {
        let library = PodcastLibraryController.shared
        guard library.state.settings.syncEnabled, !inFlight else { return }
        inFlight = true; defer { inFlight = false }
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "LunaICloudContainerID") as? String, !identifier.isEmpty else { throw PodcastError("iCloud is not configured for this build.") }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw PodcastError("Sign in to iCloud in Settings to sync your podcast library.") }
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "LunaMusicPodcastsLibrary")
        for attempt in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "LunaPodcastLibrary", recordID: id) }
            let current = try library.requireStore().state
            var merged = current
            if let asset = record["library"] as? CKAsset, let url = asset.fileURL {
                let remote = try JSONDecoder().decode(PodcastLibraryState.self, from: Data(contentsOf: url))
                merged = PodcastLibraryMerge.merge(local: current, remote: remote)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-sync-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try JSONEncoder().encode(merged).write(to: file, options: [.atomic])
            record["library"] = CKAsset(fileURL: file)
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                _ = try result.saveResults[id]?.get()
                // A user may have edited or listened while the upload was in flight.
                try library.edit { $0 = PodcastLibraryMerge.merge(local: $0, remote: merged) }
                lastError = nil; return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
            catch { lastError = error.localizedDescription; throw error }
        }
    }
}
