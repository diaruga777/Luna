import AppIntents
import LunaIntents
import UserNotifications

enum TriggerNotificationDelivery: String, AppEnum {
    case passive, active, timeSensitive
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Notification Delivery"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .passive: "Quiet", .active: "Standard", .timeSensitive: "Time Sensitive"
    ]
    var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .passive: return .passive
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        }
    }
}

struct ScheduleTriggerNotificationIntent: AppIntent {
    static var title: LocalizedStringResource = "Schedule Trigger Notification"
    static var description = IntentDescription("Schedule a one-time Luna Reader notification. Use its title, subtitle or body in a Shortcuts notification automation. Returns the notification ID. System notification settings can delay delivery.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Delay (Seconds)", description: "Seconds from now. Use 0 to send immediately.", default: 60)
    var delay: Double
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Subtitle") var subtitle: String?
    @Parameter(title: "Body", description: "The notification message. Put data your shortcut needs to read here, such as JSON.") var body: String?
    @Parameter(title: "User Info (JSON)", description: "Optional custom metadata as a JSON object with no null values. Shortcuts notification input may not expose userInfo; use Body for shortcut data.") var userInfoJSON: String?
    @Parameter(title: "Notification ID", description: "Leave blank for a new notification. Reuse an ID to replace a pending trigger notification.") var identifier: String?
    @Parameter(title: "Thread ID", description: "Notifications with the same thread ID are grouped together.") var threadIdentifier: String?
    @Parameter(title: "Category ID", description: "An existing notification category registered by the app, if needed.") var categoryIdentifier: String?
    @Parameter(title: "Play Sound", default: false) var playSound: Bool
    @Parameter(title: "Badge", description: "Leave blank to keep the current badge. Use 0 to clear it.") var badge: Int?
    @Parameter(title: "Delivery", description: "Quiet delivers to Notification Center. Standard can show a banner. Time Sensitive still follows your notification settings.", default: .passive) var delivery: TriggerNotificationDelivery

    static var parameterSummary: some ParameterSummary {
        Summary("Schedule \(\.$title) in \(\.$delay) seconds") {
            \.$subtitle
            \.$body
            \.$userInfoJSON
            \.$identifier
            \.$threadIdentifier
            \.$categoryIdentifier
            \.$playSound
            \.$badge
            \.$delivery
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let request = try TriggerNotificationScheduler.request(
            delay: delay, title: title, subtitle: subtitle, body: body, userInfoJSON: userInfoJSON,
            identifier: identifier, threadIdentifier: threadIdentifier, categoryIdentifier: categoryIdentifier,
            playSound: playSound, badge: badge, interruptionLevel: delivery.interruptionLevel)
        return .result(value: try await TriggerNotificationScheduler.schedule(request))
    }
}
