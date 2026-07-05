//
//  RecentFriendRecipientsStore.swift
//  LunaSocial
//

import LunaStorage
import Foundation

public extension Notification.Name {
    /// Posted whenever the recently-used friend recipients list changes.
    static let recentFriendRecipientsChanged = Notification.Name("recentFriendRecipientsChanged")
}

/// Persists the email addresses that Luna has successfully sent friend shares
/// to, newest first. This is separate from `FriendsStore`: every sent recipient
/// is still a friend, but this list preserves send recency for the quick-send UI.
public final class RecentFriendRecipientsStore {

    public static let shared = RecentFriendRecipientsStore()

    public struct Recipient: Codable, Equatable {
        public var email: String
        public var lastSentAt: Date

        public init(email: String, lastSentAt: Date = Date()) {
            self.email = Friend.normalize(email)
            self.lastSentAt = lastSentAt
        }
    }

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let mutationLock = NSLock()

    public init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    private var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        let url = container.appendingPathComponent("recentFriendRecipients.json")
        BackupPolicy.includeInBackups(url)
        return url
    }

    /// Newest recipients first.
    public func items(limit: Int? = nil) -> [Recipient] {
        guard let data = try? Data(contentsOf: fileURL),
              let recipients = try? JSONDecoder().decode([Recipient].self, from: data)
        else { return [] }
        let sorted = recipients.sorted { $0.lastSentAt > $1.lastSentAt }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    public func recordSent(to emails: [String], now: Date = Date()) {
        let normalized = emails
            .map(Friend.normalize)
            .filter(Friend.isValidEmail)
        guard !normalized.isEmpty else { return }

        mutationLock.lock()
        defer { mutationLock.unlock() }

        var byEmail: [String: Recipient] = [:]
        for recipient in items() {
            byEmail[recipient.email] = recipient
        }
        for email in normalized {
            byEmail[email] = Recipient(email: email, lastSentAt: now)
        }
        save(Array(byEmail.values))
    }

    private func save(_ recipients: [Recipient]) {
        if let data = try? JSONEncoder().encode(recipients) {
            let url = fileURL
            try? data.write(to: url, options: .atomic)
            BackupPolicy.includeInBackups(url)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .recentFriendRecipientsChanged, object: nil)
        }
    }
}
