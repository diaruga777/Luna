//
//  PluginJSFailure.swift
//  LunaPluginRuntime
//

import Foundation
import LunaPluginKit

/// A hook call that produced no usable value, with everything the diagnostics
/// reader needs: which plugin, which hook, and the JavaScript's own words.
///
/// `PluginInvocationFailure` (the seam) is what the stages match on; this is
/// what the log records. `invocationFailure` maps one onto the other.
public struct PluginJSFailure: Error, Equatable {
    public enum Reason: String, Equatable, Sendable {
        /// The runtime holds no context for this plugin id.
        case notLoaded
        /// The plugin registered no such hook.
        case missingHook
        /// The hook threw, or evaluating the script threw.
        case exception
        /// The caller stopped waiting. The JS may keep running — see
        /// `PluginExecutionQueue`.
        case timeout
        /// An earlier abandoned call still holds the execution queue.
        case wedged
        /// The settled value did not decode as the expected shape.
        case malformedResult
        /// The plugin timed out repeatedly and the runtime stopped calling it.
        case disabled
        /// `luna.browser.open` was called where no browser can be shown.
        case browserDeferred
        /// The `luna` object the plugin can see does not match its grant. It is
        /// a wiring fault, never a plugin's own.
        case capabilityMismatch
        /// The bridge refused for a reason the plugin cannot fix.
        case runtime
    }

    public let pluginID: String
    public let hook: String
    public let reason: Reason
    public let message: String
    /// The JS stack, when the exception carried one.
    public let stack: String?

    public init(
        pluginID: String, hook: String, reason: Reason, message: String, stack: String? = nil
    ) {
        self.pluginID = pluginID
        self.hook = hook
        self.reason = reason
        self.message = message
        self.stack = stack
    }

    /// The shape the ingest and export stages match on.
    public var invocationFailure: PluginInvocationFailure {
        switch reason {
        case .notLoaded, .disabled: return .notLoaded
        case .missingHook: return .missingHook
        case .timeout: return .timedOut
        case .wedged: return .wedged
        case .exception: return .exception(message: message, stack: stack)
        case .malformedResult: return .malformedResult(message)
        case .browserDeferred: return .browserDeferred
        case .capabilityMismatch, .runtime: return .runtime(message)
        }
    }

    /// The line the diagnostics log records.
    public var logLine: String {
        var line = "\(hook) \(reason.rawValue): \(message)"
        if let stack, !stack.isEmpty { line += "\n\(stack)" }
        return line
    }
}

/// Receives every plugin failure the runtime produces, including those a walk
/// swallows to carry on to the next plugin.
public protocol PluginExceptionReporting: AnyObject {
    func pluginDidFail(_ failure: PluginJSFailure)
}
