//
//  PluginBridgeSupport.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore

/// Runs a bridge's completion back on the queue plugin JavaScript runs on.
///
/// A bridge never re-enters a context from the thread its work finished on: the
/// contexts share one virtual machine and one serial queue, and entering from
/// anywhere else races both.
public protocol PluginCallbackScheduling: AnyObject {
    func schedulePluginCallback(_ work: @escaping () -> Void)
    /// Schedules a callback and restores the invocation that created it.
    func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?
    )
    /// Schedules a continuation with the context generation that created it.
    /// A replacement plugin with the same id must never receive this callback.
    func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?,
        generationID: String?
    )
    /// The invocation currently entering JavaScript on this scheduler's queue.
    var currentPluginInvocation: PluginInvocationDiagnostics? { get }
    var currentPluginID: String? { get }
    var currentPluginGenerationID: String? { get }
    /// Records that the plugin is still doing useful work, so an idle-budgeted
    /// hook is not abandoned mid-fetch. A nil `pluginID` touches every plugin
    /// in flight, which is what a bridge that cannot name one must ask for.
    func notePluginActivity(pluginID: String?)
    func notePluginActivity(pluginID: String?, generationID: String?)
    /// Hands over a promise no bridge has settled yet. The runtime releases its
    /// two `JSValue`s when the plugin's last call is abandoned, so an unsettled
    /// bridge cannot pin the plugin's `JSContext` for the life of the process.
    func trackPendingPromise(_ box: PluginPromiseBox, pluginID: String?)
    func trackPendingPromise(
        _ box: PluginPromiseBox, pluginID: String?, generationID: String?
    )
    /// Starts work that can outlive the synchronous hook body. The returned
    /// lease keeps the context generation and its scratch directory alive until
    /// completion or cancellation.
    func beginPluginOperation(
        pluginID: String, generationID: String
    ) -> PluginOperationLease?
}

public extension PluginCallbackScheduling {
    func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?
    ) {
        schedulePluginCallback(work)
    }

    func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?,
        generationID: String?
    ) {
        schedulePluginCallback(work, invocation: invocation)
    }

    var currentPluginInvocation: PluginInvocationDiagnostics? { nil }
    var currentPluginID: String? { nil }
    var currentPluginGenerationID: String? { nil }

    func notePluginActivity(pluginID: String?, generationID: String?) {
        notePluginActivity(pluginID: pluginID)
    }

    func trackPendingPromise(_ box: PluginPromiseBox, pluginID: String?) {}
    func trackPendingPromise(
        _ box: PluginPromiseBox, pluginID: String?, generationID: String?
    ) {}
    func beginPluginOperation(
        pluginID: String, generationID: String
    ) -> PluginOperationLease? { nil }
}

/// Runs a callback on the calling thread. A caller driving one context by hand
/// uses this; the app uses the runtime.
public final class ImmediatePluginCallbackScheduler: PluginCallbackScheduling {
    public init() {}
    public func schedulePluginCallback(_ work: @escaping () -> Void) { work() }
    public func notePluginActivity(pluginID: String?) {}
}

/// A cancellable hold on a runtime generation. Cancellation is idempotent and
/// safe from an arbitrary worker queue; bridges use `isValid` immediately
/// before writing a file or delivering a completion to prevent stale work from
/// recreating an abandoned generation.
public final class PluginOperationLease {
    private let lock = NSLock()
    private var valid = true
    private let onRelease: () -> Void

    public init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    public func cancel() {
        lock.lock()
        guard valid else {
            lock.unlock()
            return
        }
        valid = false
        lock.unlock()
        onRelease()
    }

    deinit { cancel() }
}

/// The value conversions every bridge does at the JavaScript boundary.
///
/// Values crossing the boundary are JSON. A `JSValue` is read INSIDE the call
/// that produced it and turned into Swift values there — nothing hands one to a
/// Swift API that outlives the call.
public enum PluginBridgeValue {

    /// A JS object read as a Swift dictionary, or empty for anything else.
    public static func dictionary(_ value: JSValue?) -> [String: Any] {
        guard let value, value.isObject, let raw = value.toDictionary() else { return [:] }
        var result: [String: Any] = [:]
        for (key, item) in raw {
            guard let name = key as? String else { continue }
            result[name] = item
        }
        return result
    }

    public static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let text = object[key] as? String, !text.isEmpty else { return nil }
        return text
    }

    public static func int(_ object: [String: Any], _ key: String) -> Int? {
        (object[key] as? NSNumber)?.intValue
    }

    public static func double(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    public static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        (object[key] as? NSNumber)?.boolValue
    }

    public static func stringDictionary(_ object: [String: Any], _ key: String) -> [String: String] {
        guard let raw = object[key] as? [String: Any] else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }

    /// JSON text for a value a plugin handed over, or nil when it is not JSON.
    public static func jsonText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return "null" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON text parsed for handing back to JavaScript.
    public static func jsonValue(_ text: String?) -> Any? {
        guard let text else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// Raises a JS exception in `context`. The context's one exception handler
    /// catches it, so the plugin author sees the message with a stack.
    public static func raise(_ message: String, in context: JSContext) {
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    /// An optional string argument a plugin may leave out.
    ///
    /// A `@convention(block)` parameter typed `String?` does NOT answer nil for a
    /// missing argument: JavaScriptCore converts `undefined` through
    /// `JSValue.toString()`, so the block receives the literal text
    /// "undefined". Every optional string a bridge takes is therefore a
    /// `JSValue` read through this.
    public static func optionalString(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        guard let text = value.toString(), !text.isEmpty else { return nil }
        return text
    }

    /// Reads `data` written as text or as `{ base64: "…" }`.
    public static func data(from value: Any?) -> Data? {
        if let text = value as? String { return Data(text.utf8) }
        if let object = value as? [String: Any], let base64 = object["base64"] as? String {
            return Data(base64Encoded: base64)
        }
        return nil
    }
}

/// One in-flight promise a bridge will settle later.
///
/// Both settle functions are JavaScript values, so both live only until the
/// promise settles and both are called on the plugin queue.
public final class PluginPromiseBox {
    private var resolve: JSValue?
    private var reject: JSValue?
    private let scheduler: PluginCallbackScheduling
    private let pluginID: String?
    private let generationID: String?
    private let operation: PluginOperationLease?
    private let invocation: PluginInvocationDiagnostics?
    private let lock = NSLock()

    private init(
        scheduler: PluginCallbackScheduling, pluginID: String?, generationID: String?,
        invocation: PluginInvocationDiagnostics?, operation: PluginOperationLease?
    ) {
        self.scheduler = scheduler
        self.pluginID = pluginID
        self.generationID = generationID
        self.invocation = invocation
        self.operation = operation
    }

    /// Makes a pending promise in `context` and the box that settles it.
    ///
    /// A bridge that names its plugin gets two things: its idle touches reach
    /// that plugin's in-flight calls, and an abandoned call releases the box's
    /// settle functions.
    public static func make(
        in context: JSContext, scheduler: PluginCallbackScheduling, pluginID: String? = nil,
        generationID: String? = nil
    ) -> (promise: JSValue, box: PluginPromiseBox) {
        let resolvedPluginID = pluginID ?? scheduler.currentPluginID
        let resolvedGenerationID = generationID ?? scheduler.currentPluginGenerationID
        let box = PluginPromiseBox(
            scheduler: scheduler, pluginID: resolvedPluginID,
            generationID: resolvedGenerationID,
            invocation: scheduler.currentPluginInvocation,
            operation: resolvedPluginID.flatMap { id in
                resolvedGenerationID.flatMap { generation in
                    scheduler.beginPluginOperation(pluginID: id, generationID: generation)
                }
            })
        let promise = JSValue(newPromiseIn: context) { resolve, reject in
            box.resolve = resolve
            box.reject = reject
        }
        scheduler.trackPendingPromise(
            box, pluginID: resolvedPluginID, generationID: resolvedGenerationID)
        return (promise ?? JSValue(undefinedIn: context), box)
    }

    public func fulfill(_ value: Any) { settle(value, rejecting: false) }

    /// The worker side of a bridge must check this before performing a side
    /// effect. It becomes false when the hook times out and its promise is
    /// discarded, even if the worker callback arrives much later.
    public var isOperationValid: Bool { operation?.isValid ?? true }

    /// Fulfils with JavaScript `undefined` rather than `null`. A key that holds
    /// nothing and a key holding a stored `null` must answer differently.
    public func fulfillUndefined() { settle(PluginPromiseBox.undefined, rejecting: false) }

    /// Releases the settle functions of a promise nothing will settle.
    func discard() {
        lock.lock()
        resolve = nil
        reject = nil
        lock.unlock()
        operation?.cancel()
    }

    /// The marker `fulfillUndefined` settles with, turned into the calling
    /// context's own `undefined` at settle time.
    private enum Undefined { case value }
    private static let undefined = Undefined.value

    /// Rejects with a `LunaError` carrying `code`, so a plugin can branch on the
    /// reason rather than on a message it has to match by text.
    public func fail(_ message: String, code: String = "bridge-failed") {
        settle(["code": code, "message": message], rejecting: true)
    }

    private func settle(_ value: Any, rejecting: Bool) {
        scheduler.notePluginActivity(pluginID: pluginID, generationID: generationID)
        scheduler.schedulePluginCallback({ [self] in
            lock.lock()
            let function = rejecting ? reject : resolve
            let context = function?.context
            resolve = nil
            reject = nil
            lock.unlock()
            guard let function, let context else { return }
            if rejecting, let object = value as? [String: Any] {
                let error = Self.makeLunaError(
                    code: object["code"] as? String ?? "bridge-failed",
                    message: object["message"] as? String ?? "", in: context)
                function.call(withArguments: [error as Any])
            } else if value is Undefined {
                function.call(withArguments: [JSValue(undefinedIn: context) as Any])
            } else {
                function.call(withArguments: [value])
            }
            operation?.cancel()
        }, invocation: invocation, generationID: generationID)
    }

    /// A `LunaError` built in the plugin's own context, so `instanceof` and
    /// `error.code` both work on the plugin's side.
    static func makeLunaError(code: String, message: String, in context: JSContext) -> JSValue? {
        guard let constructor = context.objectForKeyedSubscript("luna")?
            .objectForKeyedSubscript("LunaError"),
            !constructor.isUndefined
        else { return JSValue(newErrorFromMessage: message, in: context) }
        return constructor.construct(withArguments: [code, message])
    }
}
