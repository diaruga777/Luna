import AppIntents
import CoreSpotlight
import Foundation
import UIKit
import LunaAppConfig

struct DataChangeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Data Change"
    static var defaultQuery = DataChangeQuery()
    var id: String
    @Property(title: "Item ID") var itemID: String
    @Property(title: "Item Type") var kind: String
    @Property(title: "Operation") var operation: String
    @Property(title: "App") var app: String
    @Property(title: "Sequence") var sequence: Int
    @Property(title: "Date") var date: Date
    @Property(title: "Notification Title") var notificationTitle: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(notificationTitle)", subtitle: "\(itemID)") }
    init(_ change: AutomationChange) {
        id = change.id; itemID = change.itemID; kind = change.kind; operation = change.operation
        date = change.date; notificationTitle = change.notificationTitle
        app = change.app.rawValue; sequence = Int(clamping: change.sequence)
    }
}
struct DataChangeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DataChangeEntity] {
        guard let app = AutomationApp.current else { throw AutomationError.unavailable }
        return try AppAutomation(app: app).changes(withIDs: identifiers).map(DataChangeEntity.init)
    }
}
struct DataChangePageEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Change Page"
    @Property(title: "Changes") var changes: [DataChangeEntity]
    @Property(title: "Next Token") var nextToken: String
    @Property(title: "Has More") var hasMore: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(changes.count) changes") }
    init() { changes = []; nextToken = ""; hasMore = false }
    init(_ page: AutomationChangePage) {
        changes = page.changes.map(DataChangeEntity.init); nextToken = page.nextToken; hasMore = page.hasMore
    }
}
struct GetDataChangesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Data Changes"
    static var description = IntentDescription("Get item IDs changed since a saved token. Keep Next Token after processing the page. An empty token starts with retained history.")
    static var openAppWhenRun = false
    @Parameter(title: "After Token", description: "Next Token from your previous Get Data Changes result. Leave blank to start at the beginning of retained history.") var token: String?
    @Parameter(title: "Maximum Changes", description: "The most changes to return in one page, from 1 to 500.", default: 100, inclusiveRange: (1, 500)) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Get Data Changes") {
            \.$token
            \.$limit
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<DataChangePageEntity> {
        guard let app = AutomationApp.current else { throw AutomationError.unavailable }
        return .result(value: DataChangePageEntity(try AppAutomation(app: app).changes(after: token, limit: limit)))
    }
}
struct DismissChangeNotificationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss Change Notifications"
    static var description = IntentDescription("Dismiss this app’s change notifications. Leave Changes empty to dismiss all change notifications. History and tokens are preserved.")
    @Parameter(title: "Changes") var changes: [DataChangeEntity]?
    static var parameterSummary: some ParameterSummary {
        Summary("Dismiss Change Notifications") {
            \.$changes
        }
    }
    func perform() async throws -> some IntentResult {
        guard let app = AutomationApp.current else { throw AutomationError.unavailable }
        await AppAutomation(app: app).dismissNotifications(eventIDs: changes?.map(\.id) ?? [])
        return .result()
    }
}

/// One serial refresh per app. Indexing is a projection; queries always re-read
/// the owning store, and removed objects stop resolving immediately.
@MainActor enum AutomationEntityIndex {
    private static var foregroundObserver: NSObjectProtocol?
    private static var observer: NSObjectProtocol?
    private static var pending: Task<Void, Never>?
    private static var refresh: (() async throws -> Void)?
    private static var refreshing = false
    private static var dirty = false
    static func install(_ action: @escaping () async throws -> Void) {
        guard observer == nil else { return }
        refresh = action
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in schedule() }
        }
        observer = NotificationCenter.default.addObserver(forName: .lunaAutomationChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in schedule() }
        }
        schedule()
    }
    static func replace<T: IndexedEntity>(_ type: T.Type, entities: [T]) async throws {
        let index = CSSearchableIndex(name: "Luna.Automation")
        try await index.deleteAppEntities(ofType: type)
        for start in stride(from: 0, to: entities.count, by: 250) {
            try await index.indexAppEntities(Array(entities[start..<min(start + 250, entities.count)]), priority: 10)
        }
    }
    private static func schedule() {
        if let app = AutomationApp.current { Task { await AppAutomation(app: app).deliverPendingNotifications() } }
        dirty = true
        guard !refreshing else { return }
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            refreshing = true
            repeat {
                dirty = false
                do { try await refresh?() } catch { NSLog("Luna entity index: %@", error.localizedDescription) }
            } while dirty
            refreshing = false
        }
    }
}
