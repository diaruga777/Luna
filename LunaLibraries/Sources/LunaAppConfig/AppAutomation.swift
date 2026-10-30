import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Public automation vocabulary. Notifications contain IDs, never item contents.
public enum AutomationApp: String, Codable, CaseIterable, Sendable {
    case reader, music, vault, keyboard, writer
    public var bundleIdentifier: String {
        AppConfig.productBundlePrefix + (self == .reader ? "" : "." + rawValue)
    }
    public static var current: Self? { app(forBundleIdentifier: Bundle.main.bundleIdentifier ?? "") }

    public static func app(forBundleIdentifier bundle: String) -> Self? {
        // Reader owns only its known extensions. Matching its namespace prefix
        // would impersonate Writer, retired apps, test runners and Mac helpers.
        for app in [Self.keyboard, .music, .vault, .writer] {
            if bundle == app.bundleIdentifier || bundle.hasPrefix(app.bundleIdentifier + ".") { return app }
        }
        let reader = Self.reader.bundleIdentifier
        return [reader, reader + ".share", reader + ".action2", reader + ".safari", reader + ".liveactivity"].contains(bundle) ? .reader : nil
    }
}

/// A committed domain edit, before the journal assigns its identity and order.
public struct AutomationMutation: Sendable {
    public let kind: String
    public let itemID: String
    public let operation: String
    public init(kind: String, itemID: String, operation: String) {
        self.kind = kind; self.itemID = itemID; self.operation = operation
    }
}

public struct AutomationChange: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sequence: Int64
    public let date: Date
    public let app: AutomationApp
    public let kind: String
    public let itemID: String
    public let operation: String
    public var notificationTitle: String { "Luna.\(app.rawValue).\(kind).\(operation)" }
    public var notificationIdentifier: String { "luna.change." + id }
}

public struct AutomationChangePage: Sendable {
    public let changes: [AutomationChange]
    public let nextToken: String
    public let hasMore: Bool
}

/// The independently configurable kinds of automation change notifications.
public enum AutomationChangeOperation: String, CaseIterable, Sendable {
    case created, read, unread, updated, deleted

    public var title: String {
        switch self {
        case .created: return "New Items"
        case .read: return "Items Marked as Read"
        case .unread: return "Items Marked as Unread"
        case .updated: return "Updated Items"
        case .deleted: return "Deleted Items"
        }
    }
}

public enum AutomationError: LocalizedError {
    case unavailable, invalidToken, expiredToken, notificationsDenied
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Automation history could not be opened."
        case .invalidToken: return "This change token belongs to another app or is invalid."
        case .expiredToken: return "This change token is too old. Get a fresh list of items and start again without a token."
        case .notificationsDenied: return "Allow notifications for this app in Settings, then try again."
        }
    }
}

/// Cross-process journal shared by the app, intents and extensions. The stable
/// lock file is separate from the atomically replaced JSON snapshot. A cursor
/// includes a journal generation, so reinstall/reset never silently loses events.
public final class AppAutomation: @unchecked Sendable {
    private struct History: Codable {
        var generation = UUID().uuidString
        var sequence: Int64 = 0
        var changes: [AutomationChange] = []
        var pendingNotifications: [String]?
    }
    private struct Cursor: Codable { let app: AutomationApp; let generation: String; let sequence: Int64 }
    public let app: AutomationApp
    private let root: URL?
    private let defaults: UserDefaults
    public init(app: AutomationApp, directory: URL? = AppConfig.sharedContainerURL(),
                defaults: UserDefaults = UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard) {
        self.app = app; root = directory?.appendingPathComponent("Automation", isDirectory: true); self.defaults = defaults
    }
    private var legacySettingKey: String { "automation.\(app.rawValue).notifications" }
    private func settingKey(for operation: String) -> String { "automation.\(app.rawValue).notifications.\(operation)" }
    public var notificationsEnabled: Bool { AutomationChangeOperation.allCases.contains { notificationsEnabled(for: $0.rawValue) } }
    public func notificationsEnabled(for operation: String) -> Bool {
        let key = settingKey(for: operation)
        return defaults.object(forKey: key) == nil ? defaults.bool(forKey: legacySettingKey) : defaults.bool(forKey: key)
    }
    public func setNotificationsEnabled(_ enabled: Bool, for operation: AutomationChangeOperation) async throws {
        #if canImport(UserNotifications)
        if enabled {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard try await center.requestAuthorization(options: [.alert, .provisional]) else {
                    throw AutomationError.notificationsDenied
                }
            } else if settings.authorizationStatus == .denied { throw AutomationError.notificationsDenied }
        }
        #endif
        defaults.set(enabled, forKey: settingKey(for: operation.rawValue))
        if !enabled {
            let matchingEvents = (try? locked(write: false) { history in
                history.changes.filter { $0.operation == operation.rawValue }.map(\.id)
            }) ?? []
            try locked { history in history.pendingNotifications?.removeAll { matchingEvents.contains($0) } }
            await dismissNotifications(eventIDs: matchingEvents)
        } else { await deliverPendingNotifications() }
    }
    @discardableResult public func record(kind: String, itemID: String, operation: String) throws -> AutomationChange {
        try record([AutomationMutation(kind: kind, itemID: itemID, operation: operation)])[0]
    }

    /// Feed merges and imports append in one snapshot write instead of encoding
    /// the entire retained history again for every item in the same commit.
    @discardableResult public func record(_ mutations: [AutomationMutation]) throws -> [AutomationChange] {
        guard !mutations.isEmpty else { return [] }
        let events = try locked { history in
            let events = mutations.map { mutation in
                history.sequence += 1
                return AutomationChange(id: UUID().uuidString, sequence: history.sequence, date: Date(),
                    app: app, kind: mutation.kind, itemID: mutation.itemID, operation: mutation.operation)
            }
            history.changes.append(contentsOf: events)
            let eligible = events.filter { notificationsEnabled(for: $0.operation) }
            if !eligible.isEmpty { history.pendingNotifications = (history.pendingNotifications ?? []) + eligible.map(\.id) }
            if history.changes.count > 10_000 {
                history.changes.removeFirst(history.changes.count - 10_000)
                let retained = Set(history.changes.map(\.id))
                history.pendingNotifications?.removeAll { !retained.contains($0) }
            }
            return events
        }
        #if canImport(UserNotifications)
        if events.contains(where: { notificationsEnabled(for: $0.operation) }), AutomationApp.current == app {
            Task { await deliverPendingNotifications() }
        }
        #endif
        NotificationCenter.default.post(name: .lunaAutomationChanged, object: app.rawValue)
        return events
    }
    /// Logging must never turn a successfully committed domain edit into a failure.
    public static func record(_ app: AutomationApp, kind: String, id: String, operation: String) {
        record(app, mutations: [AutomationMutation(kind: kind, itemID: id, operation: operation)])
    }
    public static func record(_ app: AutomationApp, mutations: [AutomationMutation]) {
        do { try AppAutomation(app: app).record(mutations) }
        catch { NSLog("Luna automation journal: %@", error.localizedDescription) }
    }
    public func changes(after token: String? = nil, limit: Int = 100) throws -> AutomationChangePage {
        try locked(write: false) { history in
            let sequence: Int64
            if let token, !token.isEmpty {
                guard let data = Data(base64Encoded: token), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
                      cursor.app == app, cursor.sequence >= 0, cursor.sequence <= history.sequence else {
                    throw AutomationError.invalidToken
                }
                guard cursor.generation == history.generation,
                      cursor.sequence >= (history.changes.first?.sequence ?? 1) - 1 else { throw AutomationError.expiredToken }
                sequence = cursor.sequence
            } else { sequence = (history.changes.first?.sequence ?? 1) - 1 }
            let pending = history.changes.filter { $0.sequence > sequence }
            let page = Array(pending.prefix(max(1, min(500, limit))))
            let cursor = Cursor(app: app, generation: history.generation, sequence: page.last?.sequence ?? history.sequence)
            return AutomationChangePage(changes: page, nextToken: try JSONEncoder().encode(cursor).base64EncodedString(), hasMore: pending.count > page.count)
        }
    }
    public func changes(withIDs identifiers: [String]) throws -> [AutomationChange] {
        guard !identifiers.isEmpty else { return [] }
        return try locked(write: false) { history in
            let requested = Set(identifiers)
            let matches = Dictionary(uniqueKeysWithValues: history.changes.filter { requested.contains($0.id) }.map { ($0.id, $0) })
            return identifiers.compactMap { matches[$0] }
        }
    }

    private func locked<T>(write: Bool = true, _ body: (inout History) throws -> T) throws -> T {
        guard let root else { throw AutomationError.unavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(app.rawValue + ".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AutomationError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AutomationError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        let file = root.appendingPathComponent(app.rawValue + ".json")
        var history = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(History.self, from: Data(contentsOf: file)) : History()
        let result = try body(&history)
        // Persist even the first empty read, keeping its cursor generation valid.
        if write || !FileManager.default.fileExists(atPath: file.path) {
            try JSONEncoder().encode(history).write(to: file, options: .atomic)
        }
        return result
    }
    public func deliverPendingNotifications() async {
        await AutomationNotificationDelivery.shared.flush(self)
    }
    fileprivate func flushPendingNotifications() async {
        #if canImport(UserNotifications)
        guard AutomationApp.current == app else { return }
        do {
            while true {
                let pending = try locked(write: false) { history in
                    let ids = Set(history.pendingNotifications ?? [])
                    return history.changes.filter { ids.contains($0.id) }
                }
                guard !pending.isEmpty else { break }
                var deliveredAny = false
                for event in pending {
                    guard notificationsEnabled(for: event.operation) else {
                        try locked { $0.pendingNotifications?.removeAll { $0 == event.id } }
                        continue
                    }
                    if await deliver(event) {
                        try locked { $0.pendingNotifications?.removeAll { $0 == event.id } }
                        deliveredAny = true
                    }
                }
                if !deliveredAny { break }
            }
        } catch { NSLog("Luna automation outbox: %@", error.localizedDescription) }
        #endif
    }
    public func dismissNotifications(eventIDs: [String] = []) async {
        #if canImport(UserNotifications)
        do {
            try locked { history in
                if eventIDs.isEmpty { history.pendingNotifications = [] }
                else { history.pendingNotifications?.removeAll { eventIDs.contains($0) } }
            }
        } catch { NSLog("Luna automation dismissal: %@", error.localizedDescription) }
        let center = UNUserNotificationCenter.current()
        let ids: [String]
        if eventIDs.isEmpty {
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            ids = delivered.map(\.request.identifier).filter { $0.hasPrefix("luna.change.") }
                + pending.map(\.identifier).filter { $0.hasPrefix("luna.change.") }
        } else { ids = eventIDs.map { "luna.change." + $0 } }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        #endif
    }
    #if canImport(UserNotifications)
    private func deliver(_ event: AutomationChange) async -> Bool {
        guard notificationsEnabled(for: event.operation) else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus), notificationsEnabled(for: event.operation) else { return false }
        // A shortcut may dismiss this event while authorization is being read.
        guard (try? locked(write: false, { ($0.pendingNotifications ?? []).contains(event.id) })) == true else { return true }
        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.interruptionLevel = .passive
        content.threadIdentifier = "luna.changes"
        content.userInfo = ["eventID": event.id, "itemID": event.itemID, "kind": event.kind,
                            "operation": event.operation, "app": event.app.rawValue,
                            "sequence": event.sequence, "date": event.date.timeIntervalSince1970]
        do {
            try await center.add(UNNotificationRequest(identifier: event.notificationIdentifier, content: content, trigger: nil))
            if !notificationsEnabled(for: event.operation) || (try? locked(write: false, { ($0.pendingNotifications ?? []).contains(event.id) })) != true { center.removeDeliveredNotifications(withIdentifiers: [event.notificationIdentifier]); center.removePendingNotificationRequests(withIdentifiers: [event.notificationIdentifier]) }
            return true
        } catch { NSLog("Luna automation notification: %@", error.localizedDescription); return false }
    }
    #endif
}

public extension Notification.Name {
    static let lunaAutomationChanged = Notification.Name("lunaAutomationChanged")
}

private actor AutomationNotificationDelivery {
    static let shared = AutomationNotificationDelivery()
    private var running: Set<AutomationApp> = []
    func flush(_ journal: AppAutomation) async {
        guard running.insert(journal.app).inserted else { return }
        defer { running.remove(journal.app) }
        await journal.flushPendingNotifications()
    }
}
