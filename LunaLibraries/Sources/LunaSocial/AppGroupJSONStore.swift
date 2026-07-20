//
//  AppGroupJSONStore.swift
//  LunaSocial
//

import LunaStorage
import Foundation

/// The App-Group-JSON-file boilerplate shared by `FriendsStore`,
/// `PendingRequestsStore`, and `RecentFriendRecipientsStore`: a file URL inside
/// the shared container, a lock serializing mutations, and an atomic-write-then-
/// notify `save()`. Each store still owns its own decoding/sorting/dedup logic —
/// only the on-disk mechanics are generic here.
public final class AppGroupJSONStore<Element: Codable> {

    /// Serializes read-modify-write mutations. Callers lock this around their
    /// own `items()` read and the matching `save(_:)` call.
    public let mutationLock = NSLock()

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let filename: String
    private let changeNotification: Notification.Name

    public init(filename: String, changeNotification: Notification.Name, containerURL: URL? = nil) {
        self.filename = filename
        self.changeNotification = changeNotification
        self.overrideContainerURL = containerURL
    }

    public var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        let url = container.appendingPathComponent(filename)
        BackupPolicy.includeInBackups(url)
        return url
    }

    /// Reads and decodes the current file, or `[]` if it's missing or unreadable.
    public func load() -> [Element] {
        guard let data = try? Data(contentsOf: fileURL),
              let elements = try? JSONDecoder().decode([Element].self, from: data)
        else { return [] }
        return elements
    }

    /// Atomically writes `elements`, then posts `changeNotification` on the main
    /// queue.
    public func save(_ elements: [Element]) {
        if let data = try? JSONEncoder().encode(elements) {
            let url = fileURL
            try? data.write(to: url, options: .atomic)
            BackupPolicy.includeInBackups(url)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: self.changeNotification, object: nil)
        }
    }
}
