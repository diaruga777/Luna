//
//  CloudKitMessageTransport.swift
//  Clip
//

import CloudKit
import Foundation

/// MessageTransport over the CloudKit PUBLIC database.
///
/// Record type `Message`: `recipientUUID` (String, queryable), `senderUUID`
/// (String), `payload` (Bytes). Recipients query for their UUID and delete
/// records after processing — this requires the `_icloud` security role to be
/// granted Create + Write on `Message` in the CloudKit Console (defaults only
/// let the creator modify). Schema must be deployed to Production before
/// TestFlight builds can use it.
final class CloudKitMessageTransport: MessageTransport {

    static let containerID = "iCloud.com.hpiddy.clip"
    static let recordType = "Message"

    private let container = CKContainer(identifier: CloudKitMessageTransport.containerID)
    private var database: CKDatabase { container.publicCloudDatabase }

    func send(payload: Data, to recipientUUID: UUID, from senderUUID: UUID) async throws {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString))
        record["recipientUUID"] = recipientUUID.uuidString
        record["senderUUID"] = senderUUID.uuidString
        record["payload"] = payload
        _ = try await database.save(record)
    }

    func fetchInbox(for recipientUUID: UUID) async throws -> [InboxRecord] {
        let query = CKQuery(
            recordType: Self.recordType,
            predicate: NSPredicate(format: "recipientUUID == %@", recipientUUID.uuidString))
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)

        return results.compactMap { recordID, result in
            guard let record = try? result.get(),
                  let senderString = record["senderUUID"] as? String,
                  let senderUUID = UUID(uuidString: senderString),
                  let payload = record["payload"] as? Data
            else { return nil }
            return InboxRecord(
                recordID: recordID.recordName, senderUUID: senderUUID, payload: payload)
        }
    }

    func delete(recordID: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            // Another device sharing this identity already processed it.
        }
    }

    func ensureSubscription(for recipientUUID: UUID) async throws {
        let subscriptionID = "inbox-\(recipientUUID.uuidString)"
        // CloudKit's `save` only CREATES — it rejects an existing subscription
        // ID rather than updating it. So delete any prior subscription first,
        // guaranteeing the live one matches the current config (an older or
        // half-saved subscription would otherwise squat on this ID forever).
        do {
            _ = try await database.deleteSubscription(withID: subscriptionID)
        } catch let error as CKError where error.code == .unknownItem {
            // No prior subscription — expected on first run.
        }
        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(format: "recipientUUID == %@", recipientUUID.uuidString),
            subscriptionID: subscriptionID,
            options: .firesOnRecordCreation)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        // Ride the record's fields along in the push so the client can process
        // without a follow-up query (which lags behind push delivery on the
        // public DB). CloudKit drops these if the payload exceeds the APNs size
        // limit, in which case we fall back to fetching.
        info.desiredKeys = ["senderUUID", "payload"]
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    func inboxRecord(fromPush userInfo: [AnyHashable: Any]) -> InboxRecord? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
                as? CKQueryNotification,
              let recordID = notification.recordID,
              let fields = notification.recordFields,
              let senderString = fields["senderUUID"] as? String,
              let senderUUID = UUID(uuidString: senderString),
              let payload = fields["payload"] as? Data
        else { return nil }
        return InboxRecord(recordID: recordID.recordName, senderUUID: senderUUID, payload: payload)
    }

    func availability() async -> MessagingAvailability {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .unavailable(reason: "Sign in to iCloud in Settings to share with friends.")
            case .restricted, .temporarilyUnavailable, .couldNotDetermine:
                return .unavailable(reason: "iCloud isn't available right now.")
            @unknown default:
                return .unavailable(reason: "iCloud isn't available right now.")
            }
        } catch {
            return .unavailable(reason: "iCloud isn't available right now.")
        }
    }
}
