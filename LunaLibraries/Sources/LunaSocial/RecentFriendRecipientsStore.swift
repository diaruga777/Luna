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

    private let store: AppGroupJSONStore<Recipient>

    public init(containerURL: URL? = nil) {
        store = AppGroupJSONStore(
            filename: "recentFriendRecipients.json",
            changeNotification: .recentFriendRecipientsChanged, containerURL: containerURL)
    }

    /// Newest recipients first.
    public func items(limit: Int? = nil) -> [Recipient] {
        let sorted = store.load().sorted { $0.lastSentAt > $1.lastSentAt }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    public func recordSent(to emails: [String], now: Date = Date()) {
        let normalized = emails
            .map(Friend.normalize)
            .filter(Friend.isValidEmail)
        guard !normalized.isEmpty else { return }

        store.mutate { all in
            // Assignment also repairs any duplicate rows written by legacy
            // builds; `Dictionary(uniqueKeysWithValues:)` would trap on them.
            var byEmail: [String: Recipient] = [:]
            for recipient in all {
                if let existing = byEmail[recipient.email],
                   existing.lastSentAt >= recipient.lastSentAt {
                    continue
                }
                byEmail[recipient.email] = recipient
            }
            for email in normalized {
                byEmail[email] = Recipient(email: email, lastSentAt: now)
            }
            all = Array(byEmail.values)
            return ((), true)
        }
    }
}
