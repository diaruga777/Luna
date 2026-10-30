import Foundation
import LunaStorage
import UserNotifications

public protocol TriggerNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

public struct SystemTriggerNotificationCenter: TriggerNotificationCenter {
    public init() {}
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
    public func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// One-shot local notifications, separate from the mutation notification outbox.
public enum TriggerNotificationScheduler {
    public enum SchedulingError: LocalizedError {
        case invalidDelay, emptyTitle, invalidMetadata, invalidBadge, notificationsDenied
        public var errorDescription: String? {
            switch self {
            case .invalidDelay: return "Delay must be a finite number of seconds, at least 0."
            case .emptyTitle: return "Enter a notification title."
            case .invalidMetadata: return "User Info must be a JSON object with no null values."
            case .invalidBadge: return "Badge must be at least 0, or left blank."
            case .notificationsDenied: return "Allow notifications for Luna Reader in Settings, then try again."
            }
        }
    }

    public static let identifierPrefix = "luna.trigger."

    public static func request(delay: TimeInterval, title: String, subtitle: String? = nil,
                               body: String? = nil, userInfoJSON: String? = nil,
                               identifier: String? = nil, threadIdentifier: String? = nil,
                               categoryIdentifier: String? = nil, playSound: Bool = false,
                               badge: Int? = nil,
                               interruptionLevel: UNNotificationInterruptionLevel = .passive) throws -> UNNotificationRequest {
        guard delay.isFinite, delay >= 0 else { throw SchedulingError.invalidDelay }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SchedulingError.emptyTitle }
        if let badge, badge < 0 { throw SchedulingError.invalidBadge }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle ?? ""
        content.body = body ?? ""
        content.userInfo = try metadata(from: userInfoJSON)
        content.threadIdentifier = threadIdentifier ?? ""
        content.categoryIdentifier = categoryIdentifier ?? ""
        content.sound = playSound ? .default : nil
        content.badge = badge.map(NSNumber.init(value:))
        content.interruptionLevel = interruptionLevel

        let suppliedID = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // IDs returned by this action can be passed back without double-prefixing.
        let id = suppliedID.isEmpty ? identifierPrefix + UUID().uuidString
            : (suppliedID.hasPrefix(identifierPrefix) ? suppliedID : identifierPrefix + suppliedID)
        let trigger = delay == 0 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    /// Validate/build before requesting permission. Await add so failures reach
    /// the shortcut rather than returning a false scheduling success.
    public static func schedule(_ request: UNNotificationRequest,
                                center: any TriggerNotificationCenter = SystemTriggerNotificationCenter()) async throws -> String {
        let status = await center.authorizationStatus()
        NotificationAuthorizationState.recordSystemStatus(determined: status != .notDetermined)
        switch status {
        case .notDetermined:
            NotificationAuthorizationState.markRequested()
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) else {
                throw SchedulingError.notificationsDenied
            }
        case .authorized, .provisional, .ephemeral: break
        default: throw SchedulingError.notificationsDenied
        }
        try await center.add(request)
        return request.identifier
    }

    private static func metadata(from json: String?) throws -> [String: Any] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dictionary = value as? [String: Any],
              PropertyListSerialization.propertyList(dictionary, isValidFor: .binary) else {
            throw SchedulingError.invalidMetadata
        }
        return dictionary
    }
}
