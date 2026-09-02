//
//  PluginRuntime.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaPluginKit

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

    private static let sharedVirtualMachine = JSVirtualMachine()!
    /// Every runtime on the process-wide virtual machine runs its JavaScript on
    /// THIS queue. The queue is what serializes entry into a virtual machine,
    /// so one queue per runtime would let two runtimes enter one machine from
    /// two threads. Two runtimes do coexist: a second `install` replaces the
    /// runtime while the seams the first wired still hold it.
    private static let sharedExecutionQueue = PluginExecutionQueue(
        label: "com.hsanabria.luna.pluginRuntime")

    private let store: PluginStore
    private let bundled: BundledPluginCatalog
    private let capabilities: PluginCapabilityRegistry
    private let processContext: PluginProcessContext
    private let virtualMachine: JSVirtualMachine
    private let executionQueue: PluginExecutionQueue
    private let diagnostics: PluginDiagnosticsRecording
    /// Opens a plugin's scratch generation for the length of a call. Nil where
    /// no scratch store is wired, and then nothing writes files either.
    private let scratch: (any PluginScratchGenerating)?

    private let lock = NSLock()
    /// Load order: host-matched before any-host, then priority descending, then
    /// id.
    private var ordered: [(plugin: LoadedPlugin, context: PluginContext)] = []
    private var disabledReasons: [String: PluginDisableReason] = [:]
    private var timeoutCounts: [String: Int] = [:]
    /// Plugin id → the calls of that plugin the runtime is still waiting on.
    ///
    /// Hooks DO overlap: `onBluetooth` → `luna.exports.deliverQueued()` runs an
    /// `export` inside a live `onBluetooth`, and a save walk can run beside a
    /// media re-resolve. One slot per runtime made the inner call's bookkeeping
    /// erase the outer one's.
    private var inFlight: [String: [PluginPendingCall]] = [:]
    /// Promises a bridge has not settled, by plugin. An abandoned call drops
    /// them: a box holding its `resolve`/`reject` values pins the plugin's whole
    /// `JSContext`.
    private var pendingPromises: [String: [WeakPluginPromiseBox]] = [:]

    public init(
        store: PluginStore = .shared,
        bundled: BundledPluginCatalog,
        capabilities: PluginCapabilityRegistry = PluginCapabilityRegistry(),
        processContext: PluginProcessContext,
        diagnostics: PluginDiagnosticsRecording = PluginDiagnostics.shared,
        scratch: (any PluginScratchGenerating)? = nil
    ) {
        self.store = store
        self.bundled = bundled
        self.capabilities = capabilities
        self.processContext = processContext
        self.diagnostics = diagnostics
        self.scratch = scratch
        virtualMachine = PluginRuntime.sharedVirtualMachine
        executionQueue = PluginRuntime.sharedExecutionQueue
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

    /// Builds one plugin's context.
    ///
    /// Every step of this runs JavaScript, so all of it enters the virtual
    /// machine from the execution queue — a load on the calling thread would
    /// race a hook already running there, and would block that thread behind a
    /// plugin that never returns.
    private func load(_ installed: InstalledPlugin) -> PluginLoadReport {
        guard let source = installed.sourceText() else {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .notLoaded,
                message: "the plugin file could not be read"))
        }
        guard !executionQueue.isWedged else {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .wedged,
                message: "an earlier abandoned plugin call still holds the execution queue"))
        }
        // Whatever a killed process left under this plugin's scratch root is
        // reaped before its new context can serve a handle out of it. A
        // generation something still holds — a call in flight, or an export
        // between its hook and its share — is left alone.
        if scratch?.hasOpenScratchGeneration(pluginID: installed.id) != true {
            scratch?.reapAll(pluginID: installed.id)
        }
        let context = executionQueue.sync {
            PluginContext(
                manifest: installed.manifest, virtualMachine: virtualMachine,
                registry: capabilities, processKind: processContext.kind,
                scratchGeneration: { [weak self] in
                    self?.scratchGeneration(pluginID: installed.id)
                        ?? PluginScratchStore.idleGeneration
                },
                log: { [weak self, id = installed.id] line in
                    self?.diagnostics.record(line, pluginID: id)
                })
        }
        if let failure = executionQueue.sync({ context.evaluate(source: source) }) {
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
        // The grant a plugin can SEE and the grant its manifest asked for are
        // produced by two different things. A disagreement is a wiring fault:
        // an undeclared namespace reaching a plugin would be an ungranted
        // capability, and a granted one missing would be a silent degradation.
        let (granted, stray) = executionQueue.sync { () -> (Set<PluginCapabilityName>, Set<String>) in
            context.seal()
            return (context.grantedNamespaces, context.strayNamespaces)
        }
        let declared = Set(installed.manifest.capabilities)
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

    /// The scratch generation this plugin's bridges write into now.
    private func scratchGeneration(pluginID: String) -> String {
        scratch?.currentScratchGeneration(pluginID: pluginID)
            ?? PluginScratchStore.idleGeneration
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
        beginCall(pluginID: pluginID, call: call)
        executionQueue.enqueue(item: item) {
            // The budget's clock starts here, so a call that waited behind
            // another plugin is not charged for the wait.
            call.touch()
            entry.context.call(hook, argumentJSON: argumentJSON) { call.settle($0) }
        }

        let isIdleBudget = hook == .ingest
        let enqueuedAt = Date()
        var neverStarted = false
        while true {
            if let outcome = call.outcome { noteSettled(pluginID, call: call); return outcome }
            if let startedAt = item.startedAt {
                let expired = isIdleBudget
                    ? call.idleSeconds >= timeout
                    : Date().timeIntervalSince(startedAt) >= timeout
                if expired { break }
            } else if Date().timeIntervalSince(enqueuedAt) >= timeout {
                neverStarted = true
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
        if let outcome = call.outcome { noteSettled(pluginID, call: call); return outcome }
        // The caller stops waiting. A body still running holds the queue, so the
        // runtime reports itself wedged until it returns; one that never started
        // is cancelled and costs the plugin nothing.
        if !item.hasReturned { executionQueue.abandon(item) }
        call.abandon()
        if !neverStarted { noteTimeout(pluginID) }
        endCall(pluginID: pluginID, call: call)
        return .failure(PluginJSFailure(
            pluginID: pluginID, hook: hook.rawValue, reason: .timeout,
            message: neverStarted
                ? "\(hook.rawValue) waited \(Int(timeout))s for the plugin queue and never ran"
                : "\(hook.rawValue) passed its \(Int(timeout))s budget and was abandoned; "
                    + "the JavaScript may keep running"))
    }

    // MARK: - In-flight calls

    /// Counts one call in and opens the plugin's scratch generation if it is the
    /// first.
    private func beginCall(pluginID: String, call: PluginPendingCall) {
        lock.lock()
        inFlight[pluginID, default: []].append(call)
        lock.unlock()
        scratch?.openScratchGeneration(pluginID: pluginID)
    }

    /// Counts one call out. The generation is reaped when the last holder goes.
    private func endCall(pluginID: String, call: PluginPendingCall) {
        lock.lock()
        var calls = inFlight[pluginID] ?? []
        calls.removeAll { $0 === call }
        inFlight[pluginID] = calls.isEmpty ? nil : calls
        let dropped = calls.isEmpty ? pendingPromises.removeValue(forKey: pluginID) : nil
        lock.unlock()
        for box in dropped ?? [] { box.value?.discard() }
        scratch?.closeScratchGeneration(pluginID: pluginID)
    }

    /// Clears the strike count after a hook that answered.
    private func noteSettled(_ pluginID: String, call: PluginPendingCall) {
        lock.lock()
        timeoutCounts[pluginID] = 0
        lock.unlock()
        endCall(pluginID: pluginID, call: call)
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
    }

    // MARK: - PluginCallbackScheduling

    public func schedulePluginCallback(_ work: @escaping () -> Void) {
        executionQueue.enqueue(work)
    }

    /// Touches EVERY in-flight call of `pluginID`, because a bridge callback
    /// cannot tell which of a plugin's overlapping hooks its continuation
    /// belongs to. Two concurrent calls of one plugin therefore keep each other
    /// alive while either is active. A caller that cannot name a plugin — a
    /// bridge above this tier — touches them all.
    public func notePluginActivity(pluginID: String?) {
        lock.lock()
        let calls = pluginID.map { inFlight[$0] ?? [] } ?? inFlight.values.flatMap { $0 }
        let idle = processContext.idle
        lock.unlock()
        for call in calls { call.touch() }
        idle?.touchIdle(pluginID: pluginID ?? "")
    }

    public func trackPendingPromise(_ box: PluginPromiseBox, pluginID: String?) {
        guard let pluginID else { return }
        lock.lock()
        var boxes = (pendingPromises[pluginID] ?? []).filter { $0.value != nil }
        boxes.append(WeakPluginPromiseBox(box))
        pendingPromises[pluginID] = boxes
        lock.unlock()
    }
}

/// The fetch service reports byte progress here, so a long download keeps an
/// idle-budgeted `ingest` alive rather than being abandoned mid-transfer.
extension PluginRuntime: PluginIdleTouching {
    public func touchIdle(pluginID: String) { notePluginActivity(pluginID: pluginID) }
}

/// One tracked promise, held weakly so a settled box is freed on schedule.
struct WeakPluginPromiseBox {
    weak var value: PluginPromiseBox?
    init(_ value: PluginPromiseBox) { self.value = value }
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
