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

    public init(email: String, name: String? = nil, dateAdded: Date = Date(),
                notifyOnEveryShare: Bool = false, hasReceivedShare: Bool = false) {
        self.email = Friend.normalize(email)
        self.name = name
        self.dateAdded = dateAdded
        self.notifyOnEveryShare = notifyOnEveryShare
        self.hasReceivedShare = hasReceivedShare
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
/// lock-serialized mutations, change notification.
public final class FriendsStore {

    public static let shared = FriendsStore()

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
        return container.appendingPathComponent("friends.json")
    }

    /// All friends, newest first.
    public func items() -> [Friend] {
        guard let data = try? Data(contentsOf: fileURL),
              let friends = try? JSONDecoder().decode([Friend].self, from: data)
        else { return [] }
        return friends.sorted { $0.dateAdded > $1.dateAdded }
    }

    public func friend(withEmail email: String) -> Friend? {
        let normalized = Friend.normalize(email)
        return items().first { $0.email == normalized }
    }

    public func isFriend(_ email: String) -> Bool { friend(withEmail: email) != nil }

    /// Adds a friend (or updates the name of an existing one). Returns the
    /// resulting friend.
    @discardableResult
    public func add(email: String, name: String? = nil) -> Friend {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        let normalized = Friend.normalize(email)
        if let index = all.firstIndex(where: { $0.email == normalized }) {
            if let name, !name.isEmpty { all[index].name = name }
            save(all)
            return all[index]
        }
        let friend = Friend(email: normalized, name: name)
        all.insert(friend, at: 0)
        save(all)
        return friend
    }

    /// Persists a full friend record (used to flip toggles / flags).
    public func update(_ friend: Friend) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.email == friend.email }) else { return }
        all[index] = friend
        save(all)
    }

    public func remove(email: String) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let normalized = Friend.normalize(email)
        var all = items()
        all.removeAll { $0.email == normalized }
        save(all)
    }

    public func setNotifyOnEveryShare(_ enabled: Bool, email: String) {
        guard var friend = friend(withEmail: email) else { return }
        friend.notifyOnEveryShare = enabled
        update(friend)
    }

    /// Records that a share from this friend was received. Returns true if this
    /// was the first ever (so the caller can always notify on the first one).
    @discardableResult
    public func markReceivedShare(email: String) -> Bool {
        guard var friend = friend(withEmail: email) else { return false }
        let wasFirst = !friend.hasReceivedShare
        if wasFirst {
            friend.hasReceivedShare = true
            update(friend)
        }
        return wasFirst
    }

    private func save(_ friends: [Friend]) {
        if let data = try? JSONEncoder().encode(friends) {
            try? data.write(to: fileURL, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .friendsListChanged, object: nil)
        }
    }
}
