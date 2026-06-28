//
//  FriendsStore.swift
//  Clip
//

import ClipStorage
import Foundation

public extension Notification.Name {
    /// Posted whenever the friends list changes (add/update/delete).
    public static let friendsListChanged = Notification.Name("friendsListChanged")
}

/// A user this user has exchanged identities with.
public struct Friend: Codable, Equatable {
    public var card: IdentityCard
    public var dateAdded: Date
}

/// Persists the friends list as JSON in the App Group container, mirroring
/// the `ReadingListStore` pattern (fresh disk reads, lock-serialized
/// mutations, change notification).
public final class FriendsStore {

    public static let shared = FriendsStore()

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let mutationLock = NSLock()

    /// The shared store uses the App Group container; tests pass a scratch
    /// directory so they never touch real data.
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

    public func friend(withUUID uuid: UUID) -> Friend? {
        items().first { $0.card.uuid == uuid }
    }

    /// Adds (or refreshes) a friend. Re-adding the same UUID updates the
    /// profile fields and keys rather than duplicating.
    public func add(_ card: IdentityCard) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        if let index = all.firstIndex(where: { $0.card.uuid == card.uuid }) {
            guard all[index].card != card else { return }
            all[index].card = card
        } else {
            all.insert(Friend(card: card, dateAdded: Date()), at: 0)
        }
        save(all)
    }

    public func delete(uuid: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        all.removeAll { $0.card.uuid == uuid }
        save(all)
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
