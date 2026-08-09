//
//  FriendsStore.swift
//  LunaSocial
//

import LunaStorage
import Foundation

public extension Notification.Name {
    /// Posted whenever the friends list changes (add/update/remove).
    static let friendsListChanged = Notification.Name("friendsListChanged")
    /// Posted whenever the pending-requests list changes.
    static let pendingRequestsChanged = Notification.Name("pendingRequestsChanged")
}

/// A person the user shares with — identified solely by email address. A
/// display name (from Contacts, an in-app nickname, or the address local part)
/// is used everywhere the friend is shown.
public struct Friend: Codable, Equatable {
    /// Lowercased email address — the stable identifier.
    public var email: String
    /// Optional nickname / contact name.
    public var name: String?
    public var dateAdded: Date
    /// When true, notify on every accepted share; otherwise only the first one.
    public var notifyOnEveryShare: Bool
    /// Whether an accepted share from this friend has ever been received (so the
    /// first one can always notify).
    public var hasReceivedShare: Bool
    /// Blocked contacts remain visible in a separate list but their incoming
    /// mail is ignored and they are omitted from recipient pickers.
    public var isBlocked: Bool

    public init(email: String, name: String? = nil, dateAdded: Date = Date(),
                notifyOnEveryShare: Bool = false, hasReceivedShare: Bool = false,
                isBlocked: Bool = false) {
        self.email = Friend.normalize(email)
        self.name = name
        self.dateAdded = dateAdded
        self.notifyOnEveryShare = notifyOnEveryShare
        self.hasReceivedShare = hasReceivedShare
        self.isBlocked = isBlocked
    }

    private enum CodingKeys: String, CodingKey {
        case email, name, dateAdded, notifyOnEveryShare, hasReceivedShare, isBlocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = Friend.normalize(try container.decode(String.self, forKey: .email))
        name = try container.decodeIfPresent(String.self, forKey: .name)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        notifyOnEveryShare = try container.decodeIfPresent(
            Bool.self, forKey: .notifyOnEveryShare) ?? false
        hasReceivedShare = try container.decodeIfPresent(
            Bool.self, forKey: .hasReceivedShare) ?? false
        isBlocked = try container.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
    }

    /// User-facing name: the nickname, else the address local part.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return Friend.localPart(email)
    }

    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func localPart(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    /// Loose validity check for an address the user typed or picked.
    public static func isValidEmail(_ raw: String) -> Bool {
        let email = normalize(raw)
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
        let domain = email[email.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !email.contains(" ")
    }
}

/// Persists the friends list as JSON in the App Group container (shared by all
/// three apps), mirroring the `ReadingListStore` pattern: fresh disk reads,
/// cross-process coordinated mutations, change notification.
public final class FriendsStore {

    public static let shared = FriendsStore()

    private let store: AppGroupJSONStore<Friend>

    public init(containerURL: URL? = nil) {
        store = AppGroupJSONStore(
            filename: "friends.json", changeNotification: .friendsListChanged,
            containerURL: containerURL)
    }

    /// All friends, newest first.
    public func items() -> [Friend] {
        store.load().sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Contacts available for sharing and incoming-email import.
    public func activeItems() -> [Friend] { items().filter { !$0.isBlocked } }

    /// Contacts whose incoming messages are ignored.
    public func blockedItems() -> [Friend] { items().filter(\.isBlocked) }

    public func friend(withEmail email: String) -> Friend? {
        let normalized = Friend.normalize(email)
        return items().first { $0.email == normalized }
    }

    public func isBlocked(_ email: String) -> Bool { friend(withEmail: email)?.isBlocked == true }

    /// Adds a friend (or updates the name of an existing one). Returns the
    /// resulting friend.
    @discardableResult
    public func add(email: String, name: String? = nil) -> Friend {
        let normalized = Friend.normalize(email)
        return store.mutate { all in
            if let index = all.firstIndex(where: { $0.email == normalized }) {
                guard let name, !name.isEmpty, all[index].name != name else {
                    return (all[index], false)
                }
                all[index].name = name
                return (all[index], true)
            }
            let friend = Friend(email: normalized, name: name)
            all.append(friend)
            return (friend, true)
        }
    }

    /// Persists a full friend record (used to flip toggles / flags).
    public func update(_ friend: Friend) {
        store.mutate { all in
            guard let index = all.firstIndex(where: { $0.email == friend.email }),
                  all[index] != friend
            else { return ((), false) }
            all[index] = friend
            return ((), true)
        }
    }

    public func remove(email: String) {
        let normalized = Friend.normalize(email)
        store.mutate { all in
            let originalCount = all.count
            all.removeAll { $0.email == normalized }
            return ((), all.count != originalCount)
        }
    }

    public func setBlocked(_ blocked: Bool, email: String) {
        let normalized = Friend.normalize(email)
        store.mutate { all in
            guard let index = all.firstIndex(where: { $0.email == normalized }),
                  all[index].isBlocked != blocked
            else { return ((), false) }
            all[index].isBlocked = blocked
            return ((), true)
        }
    }

    /// Records that a share from this friend was received. Returns true if this
    /// was the first ever (so the caller can always notify on the first one).
    @discardableResult
    public func markReceivedShare(email: String) -> Bool {
        let normalized = Friend.normalize(email)
        return store.mutate { all in
            guard let index = all.firstIndex(where: { $0.email == normalized }),
                  !all[index].hasReceivedShare
            else { return (false, false) }
            all[index].hasReceivedShare = true
            return (true, true)
        }
    }
}
