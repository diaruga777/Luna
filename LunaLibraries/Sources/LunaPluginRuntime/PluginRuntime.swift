//
//  PluginRuntime.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

/// Which `JSVirtualMachine` a runtime's contexts share.
public enum PluginVirtualMachineScope {
    /// One VM for the whole process — the shipped choice. Contexts are far
    /// cheaper to make on a shared VM, and the cost is that they serialize under
    /// that VM's lock, which the execution queue does anyway.
    case processWide
    /// A VM of this runtime's own. A caller that must not be wedged by another
    /// runtime's plugins uses it; the fixture runner does.
    case isolated
}

/// One plugin the runtime is holding.
public struct LoadedPlugin: Equatable, Sendable {
    public let manifest: PluginManifest
    public let summary: PluginSummary
    public let isBundled: Bool

    public init(manifest: PluginManifest, summary: PluginSummary, isBundled: Bool) {
        self.manifest = manifest
        self.summary = summary
        self.isBundled = isBundled
    }

    public var id: String { manifest.id }
}

/// What one plugin's load attempt produced.
public struct PluginLoadReport: Equatable {
    public let pluginID: String
    public let isLoaded: Bool
    public let failure: PluginJSFailure?
    /// Capabilities the manifest declared that no installer served, so every
    /// call on them rejects with `unavailable-here`.
    public let unavailableCapabilities: [PluginCapabilityName]

    public init(
        pluginID: String, isLoaded: Bool, failure: PluginJSFailure?,
        unavailableCapabilities: [PluginCapabilityName]
    ) {
        self.pluginID = pluginID
        self.isLoaded = isLoaded
        self.failure = failure
        self.unavailableCapabilities = unavailableCapabilities
    }
}

/// Why a plugin is not being called.
public enum PluginDisableReason: Equatable, Sendable {
    /// The runtime stopped calling it after repeated timeouts.
    case stopped
    case loadFailed(String)
    case userDisabled
}

/// Which native process is running plugin JS, and what it can offer a hook.
public struct PluginProcessContext {
    public let kind: PluginProcessKind
    /// Touched by every bridge call, so an idle-budgeted `ingest` survives a
    /// slow server and a plugin that stops asking for anything does not.
    public let idle: PluginIdleTouching?

    public init(kind: PluginProcessKind, idle: PluginIdleTouching? = nil) {
        self.kind = kind
        self.idle = idle
    }
}

/// The JavaScriptCore host: one `JSContext` per loaded plugin, all over one
/// `JSVirtualMachine`, and one serial queue every hook call runs on.
///
/// The runtime owns ORDERING. Plugins are sorted once at load — host-matched
/// before any-host, then priority descending, then id — and `matchedPlugins`
/// applies the host pre-filter in Swift. A plugin never decides when it is
/// asked.
///
/// `invoke` does not block the queue while a hook is pending: a hook that
/// answers a Promise settles from a bridge callback that must re-enter the same
/// queue. The caller waits on its own budget instead.
public final class PluginRuntime: PluginHookInvoking, PluginCallbackScheduling {

    /// Consecutive timeouts before the runtime stops calling a plugin. Each
    /// timeout may abandon a thread that never comes back, so a plugin that
    /// keeps hanging must not keep collecting them.
    public static let timeoutsBeforeDisable = 3

    /// How often a pending call is checked. Small enough that a fast hook is not
    /// held up, large enough that an eight-second budget costs a few hundred
    /// wake-ups.
    static let pollInterval: TimeInterval = 0.01

    /// Receives every failure, including those a walk swallows to carry on to
    /// the next plugin. Held strongly — a reporter is a launch seam, not a
    /// view's delegate.
    public var exceptionReporter: PluginExceptionReporting?

    private static let sharedVirtualMachine = JSVirtualMachine()!

    private let store: PluginStore
    private let bundled: BundledPluginCatalog
    private let capabilities: PluginCapabilityRegistry
    private let processContext: PluginProcessContext
    private let virtualMachine: JSVirtualMachine
    private let executionQueue: PluginExecutionQueue
    private let diagnostics: PluginDiagnosticsRecording

    private let lock = NSLock()
    /// Load order: host-matched before any-host, then priority descending, then
    /// id.
    private var ordered: [(plugin: LoadedPlugin, context: PluginContext)] = []
    private var disabledReasons: [String: PluginDisableReason] = [:]
    private var timeoutCounts: [String: Int] = [:]
    private var invocationID = "boot"
    /// The call whose idle budget the bridges are feeding, if any.
    private var activeCall: PluginPendingCall?

    public init(
        store: PluginStore = .shared,
        bundled: BundledPluginCatalog,
        capabilities: PluginCapabilityRegistry = PluginCapabilityRegistry(),
        processContext: PluginProcessContext,
        diagnostics: PluginDiagnosticsRecording = PluginDiagnostics.shared,
        virtualMachine scope: PluginVirtualMachineScope = .processWide
    ) {
        self.store = store
        self.bundled = bundled
        self.capabilities = capabilities
        self.processContext = processContext
        self.diagnostics = diagnostics
        switch scope {
        case .processWide: virtualMachine = PluginRuntime.sharedVirtualMachine
        case .isolated: virtualMachine = JSVirtualMachine()!
        }
        executionQueue = PluginExecutionQueue(label: "com.hsanabria.luna.pluginRuntime")
    }

    // MARK: - Loading

    /// Builds a context for every enabled plugin, imported and bundled.
    @discardableResult
    public func loadAll() -> [PluginLoadReport] {
        let installed = store.installedPlugins()
        let candidates = installed + bundled.plugins(shadowedBy: installed)
        lock.lock()
        ordered.removeAll()
        disabledReasons.removeAll()
        timeoutCounts.removeAll()
        lock.unlock()
        var reports: [PluginLoadReport] = []
        for candidate in candidates {
            guard candidate.state.isEnabled else {
                lock.lock()
                disabledReasons[candidate.id] = .userDisabled
                lock.unlock()
                reports.append(PluginLoadReport(
                    pluginID: candidate.id, isLoaded: false, failure: nil,
                    unavailableCapabilities: []))
                continue
            }
            reports.append(load(candidate))
        }
        sortLoaded()
        return reports
    }

    public func reloadAll() { loadAll() }

    /// Rebuilds one plugin's context from what the store holds now.
    @discardableResult
    public func reload(pluginID: String) -> PluginLoadReport {
        unload(pluginID: pluginID)
        let installed = store.plugin(id: pluginID)
        let candidate = installed ?? bundled.plugins().first { $0.id == pluginID }
        guard let candidate else {
            return PluginLoadReport(
                pluginID: pluginID, isLoaded: false,
                failure: PluginJSFailure(
                    pluginID: pluginID, hook: "<load>", reason: .notLoaded,
                    message: "no plugin with that id is installed"),
                unavailableCapabilities: [])
        }
        guard candidate.state.isEnabled else {
            lock.lock()
            disabledReasons[pluginID] = .userDisabled
            lock.unlock()
            return PluginLoadReport(
                pluginID: pluginID, isLoaded: false, failure: nil, unavailableCapabilities: [])
        }
        let report = load(candidate)
        sortLoaded()
        return report
    }

    public func unload(pluginID: String) {
        lock.lock()
        ordered.removeAll { $0.plugin.id == pluginID }
        disabledReasons[pluginID] = nil
        timeoutCounts[pluginID] = nil
        lock.unlock()
    }

    private func load(_ installed: InstalledPlugin) -> PluginLoadReport {
        guard let source = installed.sourceText() else {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .notLoaded,
                message: "the plugin file could not be read"))
        }
        let context = PluginContext(
            manifest: installed.manifest, virtualMachine: virtualMachine,
            registry: capabilities, processKind: processContext.kind,
            invocationID: { [weak self] in self?.currentInvocationID ?? "boot" },
            log: { [weak self, id = installed.id] line in
                self?.diagnostics.record(line, pluginID: id)
            })
        if let failure = context.evaluate(source: source) {
            return fail(installed, failure)
        }
        if let failure = context.registrationFailure {
            return fail(installed, failure)
        }
        let missing = installed.manifest.requiredHooks.subtracting(context.registeredHooks)
        if !missing.isEmpty {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "register", reason: .missingHook,
                message: "the manifest needs these hooks, which the plugin did not register: "
                    + missing.map(\.rawValue).sorted().joined(separator: ", ")))
        }
        context.seal()
        // The grant a plugin can SEE and the grant its manifest asked for are
        // produced by two different things. A disagreement is a wiring fault:
        // an undeclared namespace reaching a plugin would be an ungranted
        // capability, and a granted one missing would be a silent degradation.
        let granted = context.grantedNamespaces
        let declared = Set(installed.manifest.capabilities)
        let stray = context.strayNamespaces
        guard granted == declared, stray.isEmpty else {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "<capabilities>", reason: .capabilityMismatch,
                message: Self.mismatchMessage(
                    granted: granted, declared: declared, stray: stray)))
        }
        let plugin = LoadedPlugin(
            manifest: installed.manifest,
            summary: installed.manifest.summary(
                hooks: context.registeredHooks, isBundled: installed.isBundled),
            isBundled: installed.isBundled)
        lock.lock()
        ordered.append((plugin, context))
        lock.unlock()
        let unavailable = installed.manifest.capabilities
            .filter { capabilities.installer(for: $0) == nil }
        return PluginLoadReport(
            pluginID: installed.id, isLoaded: true, failure: nil,
            unavailableCapabilities: unavailable)
    }

    private func fail(_ installed: InstalledPlugin, _ failure: PluginJSFailure) -> PluginLoadReport {
        lock.lock()
        disabledReasons[installed.id] = .loadFailed(failure.message)
        lock.unlock()
        report(failure)
        return PluginLoadReport(
            pluginID: installed.id, isLoaded: false, failure: failure,
            unavailableCapabilities: [])
    }

    private static func mismatchMessage(
        granted: Set<PluginCapabilityName>, declared: Set<PluginCapabilityName>,
        stray: Set<String>
    ) -> String {
        var parts: [String] = []
        let extra = granted.subtracting(declared).map(\.rawValue).sorted()
        let missing = declared.subtracting(granted).map(\.rawValue).sorted()
        if !extra.isEmpty {
            parts.append("luna.\(extra.joined(separator: ", luna.")) was injected without a grant")
        }
        if !missing.isEmpty {
            parts.append("luna.\(missing.joined(separator: ", luna.")) was granted but never injected")
        }
        if !stray.isEmpty {
            parts.append("luna.\(stray.sorted().joined(separator: ", luna.")) is not a capability")
        }
        return "the plugin's grant and its bridge injection disagree: "
            + parts.joined(separator: "; ")
    }

    private func sortLoaded() {
        lock.lock()
        ordered.sort { left, right in
            let a = left.plugin.summary
            let b = right.plugin.summary
            if a.matchesAnyHost != b.matchesAnyHost { return !a.matchesAnyHost }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.id < b.id
        }
        lock.unlock()
    }

    // MARK: - What is loaded

    public var loaded: [LoadedPlugin] {
        lock.lock()
        defer { lock.unlock() }
        return ordered.map(\.plugin)
    }

    public var loadedPlugins: [PluginSummary] { loaded.map(\.summary) }

    /// Plugins the runtime will not call, and why, in the words Settings shows.
    public var disabled: [String: PluginDisableReason] {
        lock.lock()
        defer { lock.unlock() }
        return disabledReasons
    }

    public var disabledPlugins: [String: String] {
        disabled.mapValues { reason in
            switch reason {
            case .stopped: return "stopped"
            case .userDisabled: return "off"
            case .loadFailed(let message): return message
            }
        }
    }

    /// True while an abandoned hook still holds the execution queue.
    public var isWedged: Bool { executionQueue.isWedged }

    /// The host pre-filter, preserving load order: host-matched plugins first,
    /// then the any-host ones, whatever their priority (§3.2).
    public func matchedPlugins(forHost host: String) -> [PluginSummary] {
        loadedPlugins.filter { $0.matches(host: host) }
    }

    private var currentInvocationID: String {
        lock.lock()
        defer { lock.unlock() }
        return invocationID
    }

    // MARK: - Calling a hook

    public func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable,
        timeout: TimeInterval, decode: T.Type
    ) async -> Result<T, PluginInvocationFailure> {
        switch await settle(hook, pluginID: pluginID, argument: argument, timeout: timeout) {
        case .failure(let failure):
            report(failure)
            return .failure(failure.invocationFailure)
        case .success(let json):
            do {
                // The settled value may be a bare `null` or a number, which a
                // top-level decode does not accept everywhere. Boxing it makes
                // every hook's answer one shape.
                let boxed = Data("{\"value\":\(json)}".utf8)
                let box = try JSONDecoder().decode(PluginResultBox<T>.self, from: boxed)
                return .success(box.value)
            } catch {
                let failure = PluginJSFailure(
                    pluginID: pluginID, hook: hook.rawValue, reason: .malformedResult,
                    message: "\(hook.rawValue) answered a shape Luna cannot read: \(error)")
                report(failure)
                return .failure(failure.invocationFailure)
            }
        }
    }

    /// Runs the hook and waits on its budget. `.ingest` is idle-budgeted: every
    /// bridge call resets the clock, so a slow page is not a timeout.
    func settle(
        _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval
    ) async -> Result<String, PluginJSFailure> {
        lock.lock()
        let entry = ordered.first { $0.plugin.id == pluginID }
        let disabledReason = disabledReasons[pluginID]
        lock.unlock()
        guard let entry else {
            return .failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue,
                reason: disabledReason == nil ? .notLoaded : .disabled,
                message: disabledReason == nil
                    ? "no context is loaded for \(pluginID)"
                    : "the runtime is not calling this plugin"))
        }
        guard !executionQueue.isWedged else {
            return .failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .wedged,
                message: "an earlier abandoned plugin call still holds the execution queue"))
        }
        let argumentJSON: String
        do {
            argumentJSON = String(
                decoding: try JSONEncoder().encode(PluginArgumentBox(argument)), as: UTF8.self)
        } catch {
            return .failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .runtime,
                message: "the hook's argument could not be encoded: \(error)"))
        }

        let call = PluginPendingCall()
        let item = PluginQueueItem()
        lock.lock()
        invocationID = UUID().uuidString
        activeCall = call
        lock.unlock()
        executionQueue.enqueue(item: item) {
            entry.context.call(hook, argumentJSON: argumentJSON) { call.settle($0) }
        }

        let isIdleBudget = hook == .ingest
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let outcome = call.outcome { noteSettled(pluginID); return outcome }
            let expired = isIdleBudget
                ? call.idleSeconds >= timeout
                : Date() >= deadline
            if expired { break }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
        if let outcome = call.outcome { noteSettled(pluginID); return outcome }
        // The caller stops waiting. A body still running holds the queue, so the
        // runtime reports itself wedged until it returns.
        if !item.hasReturned { executionQueue.abandon(item) }
        call.abandon()
        noteTimeout(pluginID)
        lock.lock()
        if activeCall === call { activeCall = nil }
        lock.unlock()
        return .failure(PluginJSFailure(
            pluginID: pluginID, hook: hook.rawValue, reason: .timeout,
            message: "\(hook.rawValue) passed its \(Int(timeout))s budget and was abandoned; "
                + "the JavaScript may keep running"))
    }

    /// Clears the strike count after a hook that answered, and drops the active
    /// call so a later bridge callback touches nothing.
    private func noteSettled(_ pluginID: String) {
        lock.lock()
        timeoutCounts[pluginID] = 0
        activeCall = nil
        lock.unlock()
    }

    private func noteTimeout(_ pluginID: String) {
        lock.lock()
        let count = (timeoutCounts[pluginID] ?? 0) + 1
        timeoutCounts[pluginID] = count
        if count >= PluginRuntime.timeoutsBeforeDisable {
            disabledReasons[pluginID] = .stopped
            ordered.removeAll { $0.plugin.id == pluginID }
        }
        lock.unlock()
    }

    private func report(_ failure: PluginJSFailure) {
        diagnostics.record(failure.logLine, pluginID: failure.pluginID)
        exceptionReporter?.pluginDidFail(failure)
    }

    // MARK: - PluginCallbackScheduling

    public func schedulePluginCallback(_ work: @escaping () -> Void) {
        executionQueue.enqueue(work)
    }

    public func notePluginActivity() {
        lock.lock()
        let call = activeCall
        let idle = processContext.idle
        lock.unlock()
        call?.touch()
        idle?.touchIdle()
    }
}

/// The fetch service reports byte progress here, so a long download keeps an
/// idle-budgeted `ingest` alive rather than being abandoned mid-transfer.
extension PluginRuntime: PluginIdleTouching {
    public func touchIdle() { notePluginActivity() }
}

/// One pending hook call: its settled value, and when it last saw progress.
final class PluginPendingCall {
    private let lock = NSLock()
    private var settled: Result<String, PluginJSFailure>?
    private var abandoned = false
    private var lastActivity = Date()

    var outcome: Result<String, PluginJSFailure>? {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    /// Seconds since the last bridge call. The ingest budget reads this rather
    /// than a wall clock.
    var idleSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    func settle(_ outcome: Result<String, PluginJSFailure>) {
        lock.lock()
        if settled == nil, !abandoned { settled = outcome }
        lock.unlock()
    }

    func touch() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    /// The caller gave up. A later settle is dropped rather than delivered to
    /// nobody.
    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }
}

/// Boxes a hook's answer so a bare `null`, string or number decodes the same way
/// an object does.
struct PluginResultBox<T: Decodable>: Decodable {
    let value: T
}

/// Encodes an `Encodable` existential, which `JSONEncoder` will not take
/// directly in the package's Swift 5 language mode.
struct PluginArgumentBox: Encodable {
    private let wrapped: Encodable

    init(_ wrapped: Encodable) { self.wrapped = wrapped }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
