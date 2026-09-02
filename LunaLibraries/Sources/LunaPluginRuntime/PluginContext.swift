//
//  PluginContext.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// One plugin's JavaScript context: its own global object and its own `luna`
/// grant, over a `JSVirtualMachine` it shares with every other plugin in the
/// process.
///
/// A context is built when its plugin loads and lives for the process. It is
/// torn down only when the plugin is deleted, disabled or updated, never per
/// call: creating a context costs more than the classify call it would serve.
///
/// Calls arrive on the runtime's serial queue. This type does no locking of its
/// own.
final class PluginContext {

    let pluginID: String
    let manifest: PluginManifest
    /// The hooks `luna.register` was given, by name.
    private(set) var registeredHooks: Set<PluginHook> = []
    /// The capability namespaces actually installed, as the registry reports.
    private(set) var installedCapabilities: Set<PluginCapabilityName> = []

    private let context: JSContext
    private var hooks: JSValue?
    private var registerCount = 0
    /// The last exception the handler saw. Read and cleared around each call.
    private var pendingException: (message: String, stack: String?)?

    /// Names always on `luna`, whatever a manifest asked for (§6.1).
    static let ungatedNames: Set<String> = [
        "register", "parseURL", "log", "bytes", "env", "LunaError", "localize",
    ]

    init(
        manifest: PluginManifest,
        virtualMachine: JSVirtualMachine,
        registry: PluginCapabilityRegistry,
        processKind: PluginProcessKind,
        invocationID: @escaping () -> String,
        log: @escaping (String) -> Void
    ) {
        self.pluginID = manifest.id
        self.manifest = manifest
        context = JSContext(virtualMachine: virtualMachine)
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = (
                exception?.toString() ?? "<no exception value>",
                exception?.objectForKeyedSubscript("stack")?.toString())
        }
        context.evaluateScript(PluginBootstrapScript.source)
        let luna = context.objectForKeyedSubscript("luna")!

        Self.installParseURL(on: luna, in: context)
        Self.installLog(on: luna, log: log)
        // BCP-47 tags, most-preferred first — the same shape `luna.localize`
        // and the manifest parser resolve a copy table against, so `locale`
        // and `languages[0]` always agree (§2.2, R4 "also noticed").
        let languages = Locale.preferredLanguages
        luna.setObject(
            [
                "context": processKind.rawValue,
                "api": PluginAPIVersion.current,
                "pluginId": manifest.id,
                "version": manifest.version.description,
                "locale": languages.first ?? "en",
                "languages": languages,
            ] as [String: Any],
            forKeyedSubscript: "env" as NSString)

        let register: @convention(block) (JSValue?) -> Void = { [weak self] value in
            self?.capture(hooks: value)
        }
        luna.setObject(register, forKeyedSubscript: "register" as NSString)

        let target = PluginBridgeTarget(
            pluginID: manifest.id, manifest: manifest, invocationID: invocationID)
        for name in manifest.capabilities.sorted(by: { $0.rawValue < $1.rawValue }) {
            let namespace = PluginCapabilityNamespace(
                target: target, context: context, object: luna)
            if let installer = registry.installer(for: name) {
                installer.install(into: namespace)
            } else {
                // Declared, but not served here. The stand-in keeps the grant
                // honest: the plugin sees the namespace it consented to, and
                // every call on it rejects with `unavailable-here` (§7.2).
                PluginUnavailableNamespace.install(name, into: namespace)
            }
            installedCapabilities.insert(name)
        }
        pendingException = nil
    }

    // MARK: - Loading

    /// Compiles and evaluates the plugin's source once. The source URL names the
    /// plugin, so a JS stack trace says which plugin threw.
    func evaluate(source: String) -> PluginJSFailure? {
        pendingException = nil
        context.evaluateScript(source, withSourceURL: URL(string: "luna-plugin://\(pluginID).js"))
        return takeException(hook: "<script>")
    }

    /// Freezes `luna` once everything is installed, so a plugin cannot swap a
    /// bridge for one of its own and hand the swapped object to another plugin's
    /// value.
    func seal() {
        context.evaluateScript("Object.freeze(luna); Object.freeze(luna.bytes);")
        pendingException = nil
    }

    /// The namespaces a plugin can actually SEE on its `luna` object, read back
    /// out of the built context rather than from the table that filled it.
    ///
    /// Two different things produce this and `installedCapabilities`: one is
    /// what the registry said it did, the other is what the context holds. The
    /// runtime compares them, so a bridge that installs under a second name — or
    /// under none — cannot pass for a correct grant.
    var grantedNamespaces: Set<PluginCapabilityName> {
        let names = context.evaluateScript("Object.keys(luna)")?.toArray() as? [String] ?? []
        pendingException = nil
        return Set(names.compactMap(PluginCapabilityName.init(rawValue:)))
    }

    /// Names on `luna` that are neither a capability nor an always-present
    /// member. A non-empty answer is a bridge writing where it should not.
    var strayNamespaces: Set<String> {
        let names = context.evaluateScript("Object.keys(luna)")?.toArray() as? [String] ?? []
        pendingException = nil
        return Set(names)
            .subtracting(Self.ungatedNames)
            .subtracting(PluginCapabilityName.allCases.map(\.rawValue))
    }

    /// True once the body called `luna.register` exactly once with an object.
    var isRegistered: Bool { registerCount == 1 && hooks != nil }

    var registrationFailure: PluginJSFailure? {
        switch registerCount {
        case 0:
            return PluginJSFailure(
                pluginID: pluginID, hook: "register", reason: .missingHook,
                message: "the plugin never called luna.register(hooks)")
        case 1 where hooks == nil:
            return PluginJSFailure(
                pluginID: pluginID, hook: "register", reason: .malformedResult,
                message: "luna.register was given something that is not an object of hooks")
        case 1:
            return nil
        default:
            return PluginJSFailure(
                pluginID: pluginID, hook: "register", reason: .malformedResult,
                message: "the plugin called luna.register \(registerCount) times; "
                    + "it must call it exactly once")
        }
    }

    private func capture(hooks value: JSValue?) {
        registerCount += 1
        guard let value, value.isObject else { return }
        hooks = value
        registeredHooks = Set(PluginHook.allCases.filter { hook in
            let function = value.objectForKeyedSubscript(hook.rawValue)
            return function?.isUndefined == false && function?.isNull == false
        })
    }

    // MARK: - Calling a hook

    /// Calls one hook and settles with the JSON text of its answer.
    ///
    /// `settle` runs once. A hook that answers a Promise settles when the
    /// Promise does, on this same queue; a hook that answers a value settles
    /// straight away.
    func call(
        _ hook: PluginHook, argumentJSON: String,
        settle: @escaping (Result<String, PluginJSFailure>) -> Void
    ) {
        pendingException = nil
        guard let hooks, registeredHooks.contains(hook) else {
            settle(.failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .missingHook,
                message: "the plugin registered no \(hook.rawValue) hook")))
            return
        }
        guard let function = hooks.objectForKeyedSubscript(hook.rawValue),
              function.isObject
        else {
            settle(.failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .missingHook,
                message: "\(hook.rawValue) is not a function")))
            return
        }
        guard let argument = parseJSON(argumentJSON) else {
            settle(.failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .runtime,
                message: "the hook's argument could not be built in the plugin's context")))
            return
        }
        let result = function.call(withArguments: [argument])
        if let failure = takeException(hook: hook.rawValue) {
            settle(.failure(failure))
            return
        }
        guard let result else {
            settle(.success("null"))
            return
        }
        guard isThenable(result) else {
            settle(.success(stringify(result)))
            return
        }
        attach(to: result, hook: hook, settle: settle)
    }

    /// Attaches native settle handlers to a returned Promise.
    ///
    /// `luna.browser.open` rejects with `code === "browser-deferred"` where no
    /// browser can be shown, and the plugin lets that propagate — so a rejection
    /// carrying that code is read here as the deferral it is, rather than as the
    /// plugin's own error.
    private func attach(
        to promise: JSValue, hook: PluginHook,
        settle: @escaping (Result<String, PluginJSFailure>) -> Void
    ) {
        let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] value in
            guard let self else { return }
            settle(.success(value.map(self.stringify) ?? "null"))
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] error in
            guard let self else { return }
            settle(.failure(self.failure(fromRejection: error, hook: hook)))
        }
        promise.invokeMethod("then", withArguments: [onFulfilled, onRejected])
        pendingException = nil
    }

    private func failure(fromRejection error: JSValue?, hook: PluginHook) -> PluginJSFailure {
        let code = error?.objectForKeyedSubscript("code")?.toString()
        let message = error?.objectForKeyedSubscript("message")?.toString()
            ?? error?.toString() ?? "<no error value>"
        let stack = error?.objectForKeyedSubscript("stack")?.toString()
        if code == PluginBrowserDeferral.code {
            return PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .browserDeferred,
                message: message)
        }
        return PluginJSFailure(
            pluginID: pluginID, hook: hook.rawValue, reason: .exception,
            message: code.map { "\($0): \(message)" } ?? message, stack: stack)
    }

    // MARK: - JSON at the boundary

    /// `JSON.parse(text)` in the plugin's own context, so the hook's argument is
    /// a plain object the plugin owns rather than a bridged Swift value.
    private func parseJSON(_ text: String) -> JSValue? {
        guard let json = context.objectForKeyedSubscript("JSON"),
              let parse = json.objectForKeyedSubscript("parse")
        else { return nil }
        let value = parse.call(withArguments: [text])
        if pendingException != nil { pendingException = nil; return nil }
        return value
    }

    /// `JSON.stringify(value)`. `undefined` stringifies to nothing, which is the
    /// same answer as `null` for every hook Luna calls.
    private func stringify(_ value: JSValue) -> String {
        guard !value.isUndefined, !value.isNull,
              let json = context.objectForKeyedSubscript("JSON"),
              let stringify = json.objectForKeyedSubscript("stringify"),
              let text = stringify.call(withArguments: [value])?.toString(),
              text != "undefined"
        else { return "null" }
        pendingException = nil
        return text
    }

    private func isThenable(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        let then = value.objectForKeyedSubscript("then")
        return then?.isObject == true && then?.hasProperty("call") == true
    }

    private func takeException(hook: String) -> PluginJSFailure? {
        guard let pending = pendingException else { return nil }
        pendingException = nil
        return PluginJSFailure(
            pluginID: pluginID, hook: hook, reason: .exception,
            message: pending.message, stack: pending.stack)
    }

    // MARK: - Always-present members

    private static func installParseURL(on luna: JSValue, in context: JSContext) {
        let raw: @convention(block) (String, String) -> [String: Any] = { urlString, base in
            guard let parsed = PluginParsedURL.parse(
                urlString, relativeTo: base.isEmpty ? nil : base)
            else { return ["valid": false] }
            return [
                "valid": true,
                "href": parsed.href,
                "protocol": parsed.scheme,
                "host": parsed.host,
                "hostname": parsed.hostname,
                "port": parsed.port,
                "pathname": parsed.pathname,
                "search": parsed.search,
                "hash": parsed.hash,
                "queryPairs": parsed.queryPairs.map { ["name": $0.name, "value": $0.value] },
            ]
        }
        guard let factory = context.evaluateScript(PluginBootstrapScript.parseURLFactory),
              let wrapped = factory.call(withArguments: [raw])
        else { return }
        luna.setObject(wrapped, forKeyedSubscript: "parseURL" as NSString)
    }

    private static func installLog(on luna: JSValue, log: @escaping (String) -> Void) {
        let write: @convention(block) (JSValue?, JSValue?) -> Void = { message, data in
            var line = message?.isString == true
                ? (message?.toString() ?? "")
                : (message?.toString() ?? "")
            if let data, !data.isUndefined, !data.isNull,
               let text = PluginBridgeValue.jsonText(data.toObject()) {
                line += " \(text)"
            }
            log(line)
        }
        luna.setObject(write, forKeyedSubscript: "log" as NSString)
    }
}

/// The `LunaError` code that says a browser step must happen somewhere else.
public enum PluginBrowserDeferral {
    public static let code = "browser-deferred"
}
