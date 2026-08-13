//
//  AppGroupJSONStore.swift
//  LunaSocial
//

import LunaAppConfig
import LunaStorage
import Foundation

/// The App-Group-JSON-file boilerplate shared by `FriendsStore`,
/// `PendingRequestsStore`, and `RecentFriendRecipientsStore`: a file URL inside
/// the shared container, an element array on `CoordinatedJSONFile` (so sibling
/// apps and extensions updating the same file at the same time cannot clobber
/// each other), and a change notification per write.
public final class AppGroupJSONStore<Element: Codable> {

    private let filename: String
    private let overrideContainerURL: URL?
    private let changeNotification: Notification.Name
    private let file: CoordinatedJSONFile<[Element]>

    public init(filename: String, changeNotification: Notification.Name, containerURL: URL? = nil) {
        self.filename = filename
        self.changeNotification = changeNotification
        self.overrideContainerURL = containerURL
        // Resolved per access rather than captured: these files stay eligible for
        // the user's backup, and the flag has to be re-applied to whatever file
        // is there now.
        self.file = CoordinatedJSONFile(
            url: { Self.resolvedURL(filename: filename, containerURL: containerURL) },
            onWrite: { BackupPolicy.includeInBackups($0) },
            empty: { [] })
    }

    public var fileURL: URL {
        Self.resolvedURL(filename: filename, containerURL: overrideContainerURL)
    }

    /// Reads and decodes the current file, or `[]` if it's missing or unreadable.
    public func load() -> [Element] {
        file.read()
    }

    /// Runs one coordinated load-mutate-save transaction. The closure reports
    /// whether it changed the array so no-op operations avoid disk writes and
    /// notifications.
    public func mutate<Result>(
        _ body: @escaping (inout [Element]) -> (result: Result, changed: Bool)
    ) -> Result {
        let outcome = file.mutateIfChanged(body)
        if outcome.didWrite {
            let notification = changeNotification
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notification, object: nil)
            }
        }
        return outcome.result
    }

    private static func resolvedURL(filename: String, containerURL: URL?) -> URL {
        let fileManager = FileManager.default
        let container = containerURL
            ?? AppConfig.sharedContainerURL(fileManager)
            ?? fileManager.temporaryDirectory
        let url = container.appendingPathComponent(filename)
        BackupPolicy.includeInBackups(url)
        return url
    }
}
