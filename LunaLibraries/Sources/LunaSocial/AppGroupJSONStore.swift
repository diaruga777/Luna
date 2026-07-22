//
//  AppGroupJSONStore.swift
//  LunaSocial
//

import LunaStorage
import Foundation

/// The App-Group-JSON-file boilerplate shared by `FriendsStore`,
/// `PendingRequestsStore`, and `RecentFriendRecipientsStore`: a file URL inside
/// the shared container, coordinated reads and read-modify-write mutations, and
/// change notifications. Coordination matters because sibling apps and extensions
/// can update the same file at the same time.
public final class AppGroupJSONStore<Element: Codable> {

    private enum AccessorResult<Value> {
        case notRun
        case value(Value)
    }
    private let mutationLock = NSLock()
    private let fileCoordinator = NSFileCoordinator(filePresenter: nil)
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
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let url = fileURL
        var result = AccessorResult<[Element]>.notRun
        var coordinationError: NSError?
        fileCoordinator.coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            result = .value(loadUnlocked(from: coordinatedURL))
        }
        switch result {
        case .value(let elements): return elements
        case .notRun: return loadUnlocked(from: url)
        }
    }

    /// Runs one coordinated load-mutate-save transaction. The closure reports
    /// whether it changed the array so no-op operations avoid disk writes and
    /// notifications.
    public func mutate<Result>(
        _ body: @escaping (inout [Element]) -> (result: Result, changed: Bool)
    ) -> Result {
        mutationLock.lock()
        let url = fileURL
        var accessorResult = AccessorResult<Result>.notRun
        var didSave = false
        let perform: (URL) -> Result = { coordinatedURL in
            var elements = self.loadUnlocked(from: coordinatedURL)
            let outcome = body(&elements)
            if outcome.changed {
                didSave = self.saveUnlocked(elements, to: coordinatedURL)
            }
            return outcome.result
        }
        var coordinationError: NSError?
        fileCoordinator.coordinate(
            writingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            accessorResult = .value(perform(coordinatedURL))
        }
        let result: Result
        switch accessorResult {
        case .value(let value): result = value
        case .notRun: result = perform(url)
        }
        mutationLock.unlock()
        if didSave {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: self.changeNotification, object: nil)
            }
        }
        return result
    }

    private func loadUnlocked(from url: URL) -> [Element] {
        guard let data = try? Data(contentsOf: url),
              let elements = try? JSONDecoder().decode([Element].self, from: data)
        else { return [] }
        return elements
    }

    private func saveUnlocked(_ elements: [Element], to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(elements),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return false }
        BackupPolicy.includeInBackups(url)
        return true
    }
}
