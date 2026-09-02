//
//  PluginNotificationsBridge.swift
//  LunaPluginExport
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import LunaPluginRuntime
import UserNotifications

/// Posts one local notification and reads whether Luna may. It exists so a test
/// can assert that nothing ever ASKS for authorization.
public protocol PluginNotificationPosting: AnyObject {
    /// True when Luna already holds authorization. It never requests any.
    func isAuthorizedForPluginNotifications() async -> Bool
    func postPluginNotification(
        title: String, body: String?, identifier: String, deepLink: String?)
    /// Removes one notification, or every notification whose identifier
    /// carries `prefix` when `identifier` is nil.
    func clearPluginNotifications(identifier: String?, prefix: String)
}

/// `luna.notifications` (`claudedocs/plans/plugin-platform.md` §6.14).
///
/// It NEVER requests authorization. Luna asks at the three moments a user opts
/// into something it will notify about, and a plugin's hook is not one of them:
/// a prompt fired from JavaScript would spend the one-time decision with
/// nothing on screen to explain it. Unauthorized therefore answers
/// `{ posted: false }` rather than prompting.
public final class PluginNotificationsBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.notifications

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let center: any PluginNotificationPosting

    public init(
        processKind: PluginProcessKind,
        scheduler: PluginCallbackScheduling,
        center: (any PluginNotificationPosting)? = nil
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.center = center ?? SystemPluginNotificationCenter()
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let bridge = self
        let pluginID = namespace.pluginID
        let notifications = namespace.makeNamespaceObject()

        let post: @convention(block) (JSValue?) -> JSValue? = { value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.notifications.post needs the app", code: "unavailable-here")
                return promise
            }
            let object = PluginBridgeValue.dictionary(value)
            guard let title = PluginBridgeValue.string(object, "title") else {
                box.fail("luna.notifications.post needs a title", code: "bad-argument")
                return promise
            }
            let body = PluginBridgeValue.string(object, "body")
            let deepLink = PluginBridgeValue.string(object, "deepLink")
            // Every identifier is namespaced, so one plugin can never clear
            // another's notification — or Luna's own.
            let identifier = Self.identifierPrefix(pluginID)
                + (PluginBridgeValue.string(object, "identifier") ?? UUID().uuidString)
            Task {
                guard await bridge.center.isAuthorizedForPluginNotifications() else {
                    box.fulfill(["posted": false])
                    return
                }
                bridge.center.postPluginNotification(
                    title: title, body: body, identifier: identifier, deepLink: deepLink)
                box.fulfill(["posted": true])
            }
            return promise
        }

        let clear: @convention(block) (JSValue?) -> JSValue? = { value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.notifications.clear needs the app", code: "unavailable-here")
                return promise
            }
            bridge.center.clearPluginNotifications(
                identifier: PluginBridgeValue.optionalString(value)
                    .map { Self.identifierPrefix(pluginID) + $0 },
                prefix: Self.identifierPrefix(pluginID))
            box.fulfill(NSNull())
            return promise
        }

        notifications.setObject(post, forKeyedSubscript: "post" as NSString)
        notifications.setObject(clear, forKeyedSubscript: "clear" as NSString)
        namespace.install(notifications, as: capabilityName.rawValue)
    }

    /// The namespace one plugin's notification identifiers live in.
    public static func identifierPrefix(_ pluginID: String) -> String {
        "plugin.\(pluginID)."
    }
}

/// `UNUserNotificationCenter`, read-only about authorization.
public final class SystemPluginNotificationCenter: PluginNotificationPosting {

    /// The `userInfo` key carrying a plugin notification's deep link.
    public static let deepLinkKey = "lunaPluginDeepLink"

    public init() {}

    public func isAuthorizedForPluginNotifications() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    public func postPluginNotification(
        title: String, body: String?, identifier: String, deepLink: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        if let deepLink { content.userInfo = [Self.deepLinkKey: deepLink] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil))
    }

    public func clearPluginNotifications(identifier: String?, prefix: String) {
        let center = UNUserNotificationCenter.current()
        guard let identifier else {
            center.getDeliveredNotifications { delivered in
                let ids = delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix(prefix) }
                guard !ids.isEmpty else { return }
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            center.getPendingNotificationRequests { pending in
                let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
                guard !ids.isEmpty else { return }
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
            return
        }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
