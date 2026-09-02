//
//  PluginSettingsBridge.swift
//  LunaPluginUI
//

import Foundation
import JavaScriptCore
import LunaPluginKit
import LunaPluginRuntime

/// `luna.settings` — a plugin reading and writing its own settings values
/// (`claudedocs/plans/plugin-platform.md` §6.11).
///
/// Values are the JSON fragments the schema declares. A secret field reads back
/// as an empty string when it is set: a plugin needs to know whether the user
/// filled it in, never what they typed — the value goes to the network through
/// `luna.secrets`, not through JavaScript.
///
/// `set` is the app's alone. An extension writing a settings value would be
/// changing what the user sees in Settings from a process the user cannot see.
public final class PluginSettingsBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.settings

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling

    public init(processKind: PluginProcessKind, scheduler: PluginCallbackScheduling) {
        self.processKind = processKind
        self.scheduler = scheduler
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let schema = namespace.target.manifest.settings
        let bridge = self

        let get: @convention(block) (String?) -> JSValue? = { key in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard let key, !key.isEmpty else {
                box.fail("luna.settings.get needs a key", code: "bad-argument")
                return promise
            }
            box.fulfill(
                PluginBridgeValue.jsonValue(
                    bridge.value(pluginID: pluginID, key: key, schema: schema)) ?? NSNull())
            return promise
        }

        let set: @convention(block) (String?, JSValue?) -> JSValue? = { key, value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail(
                    "luna.settings.set is available in the app only", code: "unavailable-here")
                return promise
            }
            guard let key, !key.isEmpty else {
                box.fail("luna.settings.set needs a key", code: "bad-argument")
                return promise
            }
            // A manifest cannot declare a key starting with `_`; those are
            // Luna's own, and `_status` is the one a destination plugin writes
            // to drive its share row's dot (§9.3).
            guard key.hasPrefix("_") || schema.contains(where: { $0.key == key }) else {
                box.fail(
                    "\(pluginID) declares no setting named \"\(key)\"", code: "bad-argument")
                return promise
            }
            let json = value.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toObject() }
                .flatMap(PluginBridgeValue.jsonText)
            do {
                try PluginPlatformServices.settings?
                    .setValueJSON(json, pluginID: pluginID, key: key)
                box.fulfill(NSNull())
            } catch {
                box.fail("\(error)", code: "bridge-failed")
            }
            return promise
        }

        let all: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            var values: [String: Any] = [:]
            for field in schema {
                guard let json = bridge.value(
                    pluginID: pluginID, key: field.key, schema: schema),
                    let value = PluginBridgeValue.jsonValue(json)
                else { continue }
                values[field.key] = value
            }
            box.fulfill(values)
            return promise
        }

        let settings = namespace.makeNamespaceObject()
        settings.setObject(get, forKeyedSubscript: "get" as NSString)
        settings.setObject(set, forKeyedSubscript: "set" as NSString)
        settings.setObject(all, forKeyedSubscript: "all" as NSString)
        namespace.install(settings, as: capabilityName.rawValue)
    }

    /// The stored value, or the field's default, with a secret masked to `""`.
    private func value(
        pluginID: String, key: String, schema: [PluginSettingField]
    ) -> String? {
        if key.hasPrefix("_") {
            return PluginPlatformServices.settings?.valueJSON(pluginID: pluginID, key: key)
        }
        guard let field = schema.first(where: { $0.key == key }) else { return nil }
        let stored = PluginPlatformServices.settings?.valueJSON(pluginID: pluginID, key: key)
        // A set secret reads back as an empty string: the plugin needs to know
        // whether the user filled it in, and gets the value itself only where
        // it is used — `luna.secrets`, natively.
        guard field.isSecret else { return stored ?? field.defaultJSON }
        return stored == nil ? nil : "\"\""
    }
}
