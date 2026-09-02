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
    /// Records that the plugin is still doing useful work, so an idle-budgeted
    /// hook is not abandoned mid-fetch.
    func notePluginActivity()
}

/// Runs a callback on the calling thread. A caller driving one context by hand
/// uses this; the app uses the runtime.
public final class ImmediatePluginCallbackScheduler: PluginCallbackScheduling {
    public init() {}
    public func schedulePluginCallback(_ work: @escaping () -> Void) { work() }
    public func notePluginActivity() {}
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
    private let lock = NSLock()

    private init(scheduler: PluginCallbackScheduling) { self.scheduler = scheduler }

    /// Makes a pending promise in `context` and the box that settles it.
    public static func make(
        in context: JSContext, scheduler: PluginCallbackScheduling
    ) -> (promise: JSValue, box: PluginPromiseBox) {
        let box = PluginPromiseBox(scheduler: scheduler)
        let promise = JSValue(newPromiseIn: context) { resolve, reject in
            box.resolve = resolve
            box.reject = reject
        }
        return (promise ?? JSValue(undefinedIn: context), box)
    }

    public func fulfill(_ value: Any) { settle(value, rejecting: false) }

    /// Rejects with a `LunaError` carrying `code`, so a plugin can branch on the
    /// reason rather than on a message it has to match by text.
    public func fail(_ message: String, code: String = "bridge-failed") {
        settle(["code": code, "message": message], rejecting: true)
    }

    private func settle(_ value: Any, rejecting: Bool) {
        scheduler.notePluginActivity()
        scheduler.schedulePluginCallback { [self] in
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
            } else {
                function.call(withArguments: [value])
            }
        }
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
