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
    /// Identity of the loaded context that owns this bridge.
    public let generationID: String
    /// Names the scratch directory the plugin's files land in. One generation
    /// is open while anything of this plugin is in flight, so a nested call
    /// writes beside the call that started it rather than into a directory of
    /// its own that the outer call's settle would reap.
    public let scratchGeneration: () -> String

    public init(
        pluginID: String, manifest: PluginManifest, scratchGeneration: @escaping () -> String,
        generationID: String = "legacy"
    ) {
        self.pluginID = pluginID
        self.manifest = manifest
        self.generationID = generationID
        self.scratchGeneration = scratchGeneration
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
///
/// The table is read while a plugin loads and written while a composition root
/// installs, and those can be two threads: `PluginPlatformComposition.install`
/// is re-runnable, so a second install registers while an earlier runtime is
/// still loading. The lock is what makes that safe.
public final class PluginCapabilityRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var installers: [PluginCapabilityName: PluginCapabilityInstalling] = [:]

    public init() {}

    /// Registering a second installer for the same name replaces the first — a
    /// composition root installs each capability once.
    public func register(_ installer: PluginCapabilityInstalling) {
        lock.lock()
        installers[installer.capabilityName] = installer
        lock.unlock()
    }

    public func installer(for name: PluginCapabilityName) -> PluginCapabilityInstalling? {
        lock.lock()
        defer { lock.unlock() }
        return installers[name]
    }

    public var registeredCapabilities: Set<PluginCapabilityName> {
        lock.lock()
        defer { lock.unlock() }
        return Set(installers.keys)
    }
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
                function refuse(member) {
                    const where = member ? "luna." + ns + "." + member : "luna." + ns;
                    return Promise.reject(new luna.LunaError(
                        "unavailable-here", where + " is not available in this process"));
                }
                // The target is a FUNCTION, because a namespace may be called
                // directly (`luna.fetch(…)`) as well as read from
                // (`luna.storage.get(…)`). A plain object target would throw a
                // TypeError the plugin author cannot act on.
                return new Proxy(function () {}, {
                    apply: function () { return refuse(null); },
                    get: function (_target, property) {
                        if (property === "then") { return undefined; }
                        return function () { return refuse(String(property)); };
                    }
                });
            })
            """)
        else { return }
        let object = factory.call(withArguments: [name.rawValue])
        namespace.install(object ?? JSValue(undefinedIn: context) as Any, as: name.rawValue)
    }
}
