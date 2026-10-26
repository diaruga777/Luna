import Foundation
import LunaModels
import UserNotifications

@MainActor
protocol HappyHourNotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func remove(identifiers: [String])
}

@MainActor
private struct SystemHappyHourNotifications: HappyHourNotificationClient {
    private let center = UNUserNotificationCenter.current()
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@MainActor
public final class PremiumHappyHourReminders {
    public static let shared = PremiumHappyHourReminders(client: SystemHappyHourNotifications())
    public static let identifiers = ["luna.premium.happyhour.saturday", "luna.premium.happyhour.sunday"]
    private let client: any HappyHourNotificationClient

    init(client: any HappyHourNotificationClient) { self.client = client }

    public var isEnabled: Bool {
        get async {
            let status = await client.authorizationStatus()
            guard status == .authorized || status == .provisional || status == .ephemeral else { return false }
            let pending = await client.pendingRequests()
            return Set(Self.identifiers).isSubset(of: Set(pending.map(\.identifier)))
        }
    }

    /// Called only after an explicit tap. No permission prompt on launch or sheet presentation.
    public func enable() async throws -> Bool {
        guard try await client.requestAuthorization() else { return false }
        do {
            for request in Self.requests() { try await client.add(request) }
        } catch {
            cancel() // Do not leave just one weekend day scheduled after a partial failure.
            throw error
        }
        return true
    }

    public func cancel() { client.remove(identifiers: Self.identifiers) }

    static func requests() -> [UNNotificationRequest] {
        zip(identifiers, [7, 1]).map { identifier, weekday in
            let content = UNMutableNotificationContent()
            content.title = L10n.string("Premium_happyHourNotificationTitle")
            content.body = L10n.string("Premium_happyHourNotificationBody")
            content.sound = .default
            // Leave timeZone unset so delivery follows local wall-clock time when travelling.
            var components = DateComponents()
            components.weekday = weekday
            components.hour = 14
            components.minute = 0
            components.second = 0
            return UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        }
    }
}
