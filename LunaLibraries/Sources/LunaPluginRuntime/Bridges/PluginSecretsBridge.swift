//
//  PluginSecretsBridge.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// `luna.secrets` (§6.6): one Keychain item per (plugin, key).
///
/// An extension may READ what the app wrote, and nothing else: an export plugin
/// running in the share sheet needs the token it was given, and has no business
/// minting a new one where the user cannot see the prompt that produced it.
public final class PluginSecretsBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.secrets

    private let store: PluginSecretsStore
    private let scheduler: PluginCallbackScheduling
    private let isWritable: Bool
    private let workQueue = DispatchQueue(
        label: "com.hsanabria.luna.pluginSecrets", qos: .userInitiated)

    public init(
        store: PluginSecretsStore = .shared, scheduler: PluginCallbackScheduling,
        processKind: PluginProcessKind
    ) {
        self.store = store
        self.scheduler = scheduler
        self.isWritable = processKind == .app
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let pluginID = namespace.pluginID
        let secrets = namespace.makeNamespaceObject()
        let store = self.store
        let scheduler = self.scheduler
        let workQueue = self.workQueue
        let isWritable = self.isWritable

        let get: @convention(block) (String?) -> JSValue? = { key in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard let key, !key.isEmpty else {
                box.fail("luna.secrets.get needs a key", code: "bad-argument")
                return promise
            }
            workQueue.async {
                box.fulfill(store.secret(pluginID: pluginID, key: key) ?? NSNull())
            }
            return promise
        }

        let set: @convention(block) (String?, String?) -> JSValue? = { key, value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard isWritable else {
                box.fail(
                    "luna.secrets.set runs in the app only", code: "unavailable-here")
                return promise
            }
            guard let key, !key.isEmpty, let value else {
                box.fail("luna.secrets.set needs a key and a value", code: "bad-argument")
                return promise
            }
            workQueue.async {
                store.setSecret(value, pluginID: pluginID, key: key)
                box.fulfill(NSNull())
            }
            return promise
        }

        let remove: @convention(block) (String?) -> JSValue? = { key in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(
                in: context, scheduler: scheduler, pluginID: pluginID)
            guard isWritable else {
                box.fail(
                    "luna.secrets.delete runs in the app only", code: "unavailable-here")
                return promise
            }
            guard let key, !key.isEmpty else {
                box.fail("luna.secrets.delete needs a key", code: "bad-argument")
                return promise
            }
            workQueue.async {
                store.removeSecret(pluginID: pluginID, key: key)
                box.fulfill(NSNull())
            }
            return promise
        }

        secrets.setObject(get, forKeyedSubscript: "get" as NSString)
        secrets.setObject(set, forKeyedSubscript: "set" as NSString)
        secrets.setObject(remove, forKeyedSubscript: "delete" as NSString)
        namespace.install(secrets, as: capabilityName.rawValue)
    }
}
