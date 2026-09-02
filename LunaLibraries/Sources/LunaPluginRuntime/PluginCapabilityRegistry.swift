//
//  PluginCapabilityRegistry.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// What a capability installer is told about the plugin it is installing for.
public struct PluginBridgeTarget {
    public let pluginID: String
    public let manifest: PluginManifest
    /// Names the scratch directory and the diagnostics of ONE hook call. The
    /// runtime rotates it per invocation.
    public let invocationID: () -> String

    public init(pluginID: String, manifest: PluginManifest, invocationID: @escaping () -> String) {
        self.pluginID = pluginID
        self.manifest = manifest
        self.invocationID = invocationID
    }
}

/// The `luna` object of one plugin's context, handed to a capability installer
/// so it can add its own namespace.
///
/// A value must be JavaScriptCore-bridgeable: a `@convention(block)` closure
/// (which becomes a callable JS function), a `JSValue` built in `context`, or a
/// plain `String` / number / array / dictionary of those.
public final class PluginCapabilityNamespace {
    public let target: PluginBridgeTarget
    public let context: JSContext
    private let object: JSValue

    init(target: PluginBridgeTarget, context: JSContext, object: JSValue) {
        self.target = target
        self.context = context
        self.object = object
    }

    public var pluginID: String { target.pluginID }

    /// Installs `value` at `luna.<name>`.
    public func install(_ value: Any, as name: String) {
        object.setObject(value, forKeyedSubscript: name as NSString)
    }

    /// A fresh empty object, for a capability that groups several functions
    /// under one name (`luna.storage.collection`).
    public func makeNamespaceObject() -> JSValue {
        JSValue(newObjectIn: context)
    }
}

/// One capability's bridge. The runtime knows only the name and calls `install`
/// for the plugins that declared it.
public protocol PluginCapabilityInstalling: AnyObject {
    var capabilityName: PluginCapabilityName { get }
    func install(into namespace: PluginCapabilityNamespace)
}

/// The injection table, keyed by capability name.
///
/// A namespace a plugin did not declare is never installed, so
/// `luna.mail === undefined` is a plugin's honest feature detection. A
/// capability the plugin DID declare but that this process cannot serve gets
/// the `unavailable-here` stand-in instead (§7.2) — the grant stays honest and
/// `Object.keys(luna)` still matches the manifest.
public final class PluginCapabilityRegistry {

    private var installers: [PluginCapabilityName: PluginCapabilityInstalling] = [:]

    public init() {}

    /// Registering a second installer for the same name replaces the first — a
    /// composition root installs each capability once.
    public func register(_ installer: PluginCapabilityInstalling) {
        installers[installer.capabilityName] = installer
    }

    public func installer(for name: PluginCapabilityName) -> PluginCapabilityInstalling? {
        installers[name]
    }

    public var registeredCapabilities: Set<PluginCapabilityName> { Set(installers.keys) }
}

/// The stand-in for a capability this process cannot serve.
///
/// It is a `Proxy`, so EVERY property answers a rejecting function — the bridge
/// cannot know the method names a higher tier would have installed, and a
/// missing method that reads as `undefined` would surface as a TypeError the
/// plugin author cannot act on.
enum PluginUnavailableNamespace {

    static func install(_ name: PluginCapabilityName, into namespace: PluginCapabilityNamespace) {
        let context = namespace.context
        guard let factory = context.evaluateScript(
            """
            (function (ns) {
                return new Proxy({}, {
                    get: function (_target, property) {
                        if (property === "then") { return undefined; }
                        return function () {
                            return Promise.reject(new luna.LunaError(
                                "unavailable-here",
                                "luna." + ns + "." + String(property)
                                    + " is not available in this process"));
                        };
                    }
                });
            })
            """)
        else { return }
        let object = factory.call(withArguments: [name.rawValue])
        namespace.install(object ?? JSValue(undefinedIn: context) as Any, as: name.rawValue)
    }
}
