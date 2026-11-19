//
//  PluginRuntime.swift
//  LunaPluginRuntime
//

import Foundation
import JavaScriptCore
import LunaModels
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

    /// Top-level plugin code is expected to be declarations and setup only.
    /// This bound is used by the disposable activation preflight; production
    /// JavaScriptCore still cannot interrupt a running context.
    public static let activationPreflightTimeout: TimeInterval = 1

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
    // First accessed only from the serial execution queue while loading a
    // context. Constructing the VM must not become foreground setup work.
    private lazy var virtualMachine: JSVirtualMachine = isolated ? JSVirtualMachine()! : Self.sharedVirtualMachine
    private let isolated: Bool
    private let executionQueue: PluginExecutionQueue
    private let diagnostics: PluginDiagnosticsRecording
    /// Opens a plugin's scratch generation for the length of a call. Nil where
    /// no scratch store is wired, and then nothing writes files either.
    private let scratch: (any PluginScratchGenerating)?

    private let lock = NSLock()
    // Serialize catalog mutations without holding the bookkeeping lock during JS evaluation.
    private let reloadLock = NSLock()
    /// Only accessed on `executionQueue`; bridge closures capture this token
    /// before leaving for their own work queue.
    private var activeInvocation: PluginInvocationDiagnostics?
    private var activeGenerationID: String?
    /// Load order: host-matched before any-host, then priority descending, then
    /// id.
    private var ordered: [(plugin: LoadedPlugin, context: PluginContext, generationID: String)] = []
    private var activeGenerationByPlugin: [String: String] = [:]
    /// State is retained after reload until the old context's calls and
    /// asynchronous operations have drained. This is intentionally separate
    /// from `ordered`, which contains only contexts eligible for new calls.
    private var generationStates: [String: RuntimeGenerationState] = [:]
    private var disabledReasons: [String: PluginDisableReason] = [:]
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
        scratch: (any PluginScratchGenerating)? = nil,
        isolated: Bool = false
    ) {
        self.store = store
        self.bundled = bundled
        self.capabilities = capabilities
        self.processContext = processContext
        self.diagnostics = diagnostics
        self.scratch = scratch
        self.isolated = isolated
        executionQueue = isolated
            ? PluginExecutionQueue(label: "com.hsanabria.luna.pluginDraft.\(UUID().uuidString)")
            : PluginRuntime.sharedExecutionQueue
    }

    // MARK: - Loading

    /// Builds a context for every enabled plugin, imported and bundled.
    @discardableResult
    public func loadAll() -> [PluginLoadReport] {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        let installed = store.installedPlugins()
        let candidates = installed + bundled.plugins(shadowedBy: installed)
        lock.lock()
        for entry in ordered { retire(entry.generationID) }
        ordered.removeAll()
        activeGenerationByPlugin.removeAll()
        disabledReasons.removeAll()
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

    /// Validates and activates one imported plugin. The preflight evaluates the
    /// candidate in a disposable VM with unavailable capabilities, so top-level
    /// code cannot perform native side effects before the source is committed
    /// to the live runtime. A timeout quarantines that disposable queue.
    public func activate(pluginID: String) throws {
        let installed = store.plugin(id: pluginID)
        let candidate = installed ?? bundled.plugin(id: pluginID)
        guard let candidate else {
            throw PluginActivationError(failure: .runtime("no plugin with that id is installed"))
        }
        guard candidate.state.isEnabled else {
            throw PluginActivationError(failure: .runtime("the plugin is disabled"))
        }
        if let failure = preflight(candidate) {
            throw PluginActivationError(failure: failure.invocationFailure)
        }
        let report = reload(pluginID: pluginID)
        if let failure = report.failure {
            throw PluginActivationError(failure: failure.invocationFailure)
        }
        guard report.isLoaded else {
            throw PluginActivationError(failure: .runtime("the plugin did not load"))
        }
    }

    /// Moves activation off an actor such as the main UI actor. The synchronous
    /// form remains for launch-time callers that already own a worker thread.
    public func activateAsync(pluginID: String) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try activate(pluginID: pluginID)
        }.value
    }

    /// Rebuilds one plugin's context from what the store holds now.
    @discardableResult
    public func reload(pluginID: String) -> PluginLoadReport {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        lock.lock()
        retireActiveLocked(pluginID: pluginID)
        disabledReasons[pluginID] = nil
        lock.unlock()
        let installed = store.plugin(id: pluginID)
        let candidate = installed ?? bundled.plugin(id: pluginID)
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
        reloadLock.lock()
        defer { reloadLock.unlock() }
        lock.lock()
        retireActiveLocked(pluginID: pluginID)
        disabledReasons[pluginID] = nil
        lock.unlock()
    }

    /// Caller holds `lock`.
    private func retireActiveLocked(pluginID: String) {
        guard let generationID = activeGenerationByPlugin.removeValue(forKey: pluginID) else {
            ordered.removeAll { $0.plugin.id == pluginID }
            return
        }
        ordered.removeAll { $0.plugin.id == pluginID }
        retire(generationID)
    }

    /// Caller holds `lock`; the state itself remains until its final holder
    /// releases. New work can only find contexts in `ordered`.
    private func retire(_ generationID: String) {
        guard let state = generationStates[generationID] else { return }
        state.retired = true
        if state.isDrained { generationStates[generationID] = nil }
    }

    private func hasInFlight(pluginID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generationStates.values.contains { $0.pluginID == pluginID && !$0.isDrained }
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
        let generationID = UUID().uuidString
        // Whatever a killed process left under this plugin's scratch root is
        // reaped before its new context can serve a handle out of it. A
        // generation something still holds — a call in flight, or an export
        // between its hook and its share — is left alone.
        if !hasInFlight(pluginID: installed.id) {
            scratch?.reapAll(pluginID: installed.id)
        }
        guard let evaluation = executionQueue.sync(timeout: Self.activationPreflightTimeout, { [self] in
            let context = PluginContext(
                manifest: installed.manifest, virtualMachine: virtualMachine,
                registry: capabilities, processKind: processContext.kind,
                scratchGeneration: { generationID },
                log: { [weak self, id = installed.id] line in
                    guard let self else { return }
                    self.diagnostics.record(line, pluginID: id, invocation: self.activeInvocation)
                }, generationID: generationID)
            var failure = context.evaluate(source: source) ?? context.registrationFailure
            if failure == nil {
                let missing = installed.manifest.requiredHooks.subtracting(context.registeredHooks)
                if !missing.isEmpty {
                    failure = PluginJSFailure(
                        pluginID: installed.id, hook: "register", reason: .missingHook,
                        message: "the manifest needs these hooks, which the plugin did not register: "
                            + missing.map(\.rawValue).sorted().joined(separator: ", "))
                }
            }
            if failure == nil {
                context.seal()
                let declared = Set(installed.manifest.capabilities)
                let granted = context.grantedNamespaces
                let stray = context.strayNamespaces
                if granted != declared || !stray.isEmpty {
                    failure = PluginJSFailure(
                        pluginID: installed.id, hook: "<capabilities>", reason: .capabilityMismatch,
                        message: Self.mismatchMessage(granted: granted, declared: declared, stray: stray))
                }
            }
            return (context, failure)
        }) else {
            return fail(installed, PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .timeout,
                message: "the plugin's top-level code did not finish before the load deadline"))
        }
        let (context, failure) = evaluation
        if let failure { return fail(installed, failure) }
        let plugin = LoadedPlugin(
            manifest: installed.manifest,
            summary: installed.manifest.summary(
                hooks: context.registeredHooks, isBundled: installed.isBundled),
            isBundled: installed.isBundled)
        lock.lock()
        generationStates[generationID] = RuntimeGenerationState(
            id: generationID, pluginID: installed.id)
        activeGenerationByPlugin[installed.id] = generationID
        ordered.append((plugin, context, generationID))
        lock.unlock()
        let unavailable = installed.manifest.capabilities
            .filter { capabilities.installer(for: $0) == nil }
        return PluginLoadReport(
            pluginID: installed.id, isLoaded: true, failure: nil,
            unavailableCapabilities: unavailable)
    }

    /// Evaluates one candidate in a disposable queue/VM. The result holder is
    /// locked because the queue may still be running when the caller's timeout
    /// expires; that queue is deliberately abandoned and never reused.
    private func preflight(_ installed: InstalledPlugin) -> PluginJSFailure? {
        guard let source = installed.sourceText() else {
            return PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .notLoaded,
                message: "the plugin file could not be read")
        }
        guard let vm = JSVirtualMachine() else {
            return PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .runtime,
                message: "a disposable JavaScript VM could not be created")
        }
        let queue = PluginExecutionQueue(
            label: "com.hsanabria.luna.pluginPreflight.\(UUID().uuidString)")
        let finished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        let processKind = processContext.kind
        var result: PluginJSFailure?
        // An empty registry installs unavailable stubs for declared native
        // capabilities; evaluating a draft therefore cannot fetch, write
        // storage, show UI, send mail or touch a device.
        queue.enqueue {
            let context = PluginContext(
                manifest: installed.manifest, virtualMachine: vm,
                registry: PluginCapabilityRegistry(), processKind: processKind,
                scratchGeneration: { PluginScratchStore.idleGeneration }, log: { _ in })
            var failure = context.evaluate(source: source)
            if failure == nil { failure = context.registrationFailure }
            if failure == nil {
                let missing = installed.manifest.requiredHooks.subtracting(context.registeredHooks)
                if !missing.isEmpty {
                    failure = PluginJSFailure(
                        pluginID: installed.id, hook: "register", reason: .missingHook,
                        message: "the manifest needs these hooks, which the plugin did not register: "
                            + missing.map(\.rawValue).sorted().joined(separator: ", "))
                }
            }
            resultLock.lock()
            result = failure
            resultLock.unlock()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + Self.activationPreflightTimeout) == .success else {
            return PluginJSFailure(
                pluginID: installed.id, hook: "<load>", reason: .timeout,
                message: "the plugin's top-level code did not finish its activation preflight")
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
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
        await invoke(
            hook, pluginID: pluginID, argument: argument, timeout: timeout, decode: decode,
            invocationID: UUID(), diagnosticRecorder: nil)
    }

    /// Invokes one hook with an explicit correlation token and optional save
    /// recorder. The token is copied into every bridge promise so callbacks
    /// arriving after the hook has ended cannot write to a later save.
    public func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable,
        timeout: TimeInterval, decode: T.Type, invocationID: UUID,
        diagnosticRecorder: SaveDiagnosticsRecorder?
    ) async -> Result<T, PluginInvocationFailure> {
        let invocation = PluginInvocationDiagnostics(id: invocationID, recorder: diagnosticRecorder)
        defer { invocation.close() }
        switch await settle(
            hook, pluginID: pluginID, argument: argument, timeout: timeout, invocation: invocation
        ) {
        case .failure(let failure):
            report(failure, invocation: invocation)
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
                report(failure, invocation: invocation)
                return .failure(failure.invocationFailure)
            }
        }
    }

    /// Runs the hook and waits on its budget. `.ingest` is idle-budgeted: every
    /// bridge call resets the clock, so a slow page is not a timeout.
    func settle(
        _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
        invocation: PluginInvocationDiagnostics
    ) async -> Result<String, PluginJSFailure> {
        guard !Task.isCancelled else {
            return .failure(PluginJSFailure(pluginID: pluginID, hook: hook.rawValue,
                reason: .runtime, message: "cancelled: the caller cancelled this hook"))
        }
        guard timeout >= 0 else {
            return .failure(PluginJSFailure(pluginID: pluginID, hook: hook.rawValue,
                reason: .runtime, message: "the hook timeout must be nonnegative"))
        }
        let (entry, disabledReason) = lock.withLock {
            (ordered.first { $0.plugin.id == pluginID }, disabledReasons[pluginID])
        }
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
        let (events, completion) = AsyncStream<PluginCallEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let item = PluginQueueItem()
        guard beginCall(pluginID: pluginID, generationID: entry.generationID, call: call) else {
            return .failure(PluginJSFailure(pluginID: pluginID, hook: hook.rawValue,
                reason: .notLoaded, message: "the plugin was reloaded before the call began"))
        }
        defer { endCall(pluginID: pluginID, generationID: entry.generationID, call: call) }
        let enqueuedAt = ContinuousClock.now
        executionQueue.enqueue(item: item) {
            // The budget's clock starts here, so a call that waited behind
            // another plugin is not charged for the wait.
            call.touch()
            self.withInvocation(invocation, generationID: entry.generationID) {
                entry.context.call(hook, argumentJSON: argumentJSON) { outcome in
                    completion.yield(.settled(outcome))
                    completion.finish()
                }
            }
        }

        // Sleep until the next possible expiry. Starting a queued call or making
        // ingest progress can only move this deadline later. Settlement wakes the
        // caller directly, even when the hook returns before we begin waiting.
        let watchdog = Task {
            // An unbounded budget still responds to settlement and cancellation.
            guard timeout < Double(Int64.max) else { return }
            let budget = Duration.seconds(timeout)
            var deadline = enqueuedAt + budget
            while !Task.isCancelled {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                if item.cancelIfQueued() {
                    completion.yield(.timedOut(neverStarted: true))
                    completion.finish()
                    return
                }
                guard let started = item.startedAt else { return }
                deadline = (hook == .ingest ? max(started, call.lastActivity) : started) + budget
                if deadline <= .now {
                    completion.yield(.timedOut(neverStarted: false))
                    completion.finish()
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            completion.finish()
        }
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        guard !Task.isCancelled, let event else {
            executionQueue.abandon(item)
            call.abandon()
            return .failure(PluginJSFailure(pluginID: pluginID, hook: hook.rawValue,
                reason: .runtime, message: "cancelled: the caller cancelled this hook"))
        }
        switch event {
        case .settled(let outcome):
            lock.withLock { generationStates[entry.generationID]?.timeoutCount = 0 }
            return outcome
        case .timedOut(let neverStarted):
            executionQueue.abandon(item)
            call.abandon()
            if !neverStarted { noteTimeout(pluginID, generationID: entry.generationID) }
            return .failure(PluginJSFailure(
                pluginID: pluginID, hook: hook.rawValue, reason: .timeout,
                message: neverStarted
                    ? "\(hook.rawValue) waited \(Int(timeout))s for the plugin queue and never ran"
                    : "\(hook.rawValue) passed its \(Int(timeout))s budget and was abandoned; "
                        + "the JavaScript may keep running"))
        }
    }

    // MARK: - In-flight calls

    /// Counts one call in and opens the plugin's scratch generation if it is the
    /// first.
    private func beginCall(
        pluginID: String, generationID: String, call: PluginPendingCall
    ) -> Bool {
        lock.lock()
        guard activeGenerationByPlugin[pluginID] == generationID else {
            lock.unlock()
            return false
        }
        inFlight[generationID, default: []].append(call)
        generationStates[generationID]?.callCount += 1
        lock.unlock()
        _ = scratch?.openScratchGeneration(pluginID: pluginID, generationID: generationID)
        return true
    }

    /// Counts one call out. The generation is reaped when the last holder goes.
    private func endCall(
        pluginID: String, generationID: String, call: PluginPendingCall
    ) {
        lock.lock()
        var calls = inFlight[generationID] ?? []
        calls.removeAll { $0 === call }
        inFlight[generationID] = calls.isEmpty ? nil : calls
        generationStates[generationID]?.callCount = max(
            0, (generationStates[generationID]?.callCount ?? 1) - 1)
        let dropped = calls.isEmpty ? pendingPromises.removeValue(forKey: generationID) : nil
        let shouldPrune = calls.isEmpty && (generationStates[generationID]?.operationCount ?? 0) == 0
            && generationStates[generationID]?.retired == true
        if shouldPrune { generationStates[generationID] = nil }
        lock.unlock()
        for box in dropped ?? [] { box.value?.discard() }
        scratch?.closeScratchGeneration(pluginID: pluginID, generationID: generationID)
    }

    private func noteTimeout(_ pluginID: String, generationID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = generationStates[generationID] else { return }
        state.timeoutCount += 1
        if state.timeoutCount >= PluginRuntime.timeoutsBeforeDisable {
            // A late timeout from a retired context must not disable the
            // replacement that now owns this plugin id.
            if activeGenerationByPlugin[pluginID] == generationID {
                disabledReasons[pluginID] = .stopped
                ordered.removeAll { $0.plugin.id == pluginID }
                activeGenerationByPlugin[pluginID] = nil
                retire(generationID)
            }
        }
    }

    private func report(_ failure: PluginJSFailure, invocation: PluginInvocationDiagnostics? = nil) {
        diagnostics.record(failure.logLine, pluginID: failure.pluginID, invocation: invocation)
    }

    // MARK: - PluginCallbackScheduling

    public func schedulePluginCallback(_ work: @escaping () -> Void) {
        executionQueue.enqueue(work)
    }

    public func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?
    ) {
        executionQueue.enqueue { [weak self] in
            self?.withInvocation(invocation, work)
        }
    }

    public func schedulePluginCallback(
        _ work: @escaping () -> Void, invocation: PluginInvocationDiagnostics?,
        generationID: String?
    ) {
        executionQueue.enqueue { [weak self] in
            guard let self else { return }
            self.withInvocation(invocation, generationID: generationID, work)
        }
    }

    public var currentPluginInvocation: PluginInvocationDiagnostics? { activeInvocation }

    public var currentPluginID: String? {
        guard let generationID = activeGenerationID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return generationStates[generationID]?.pluginID
    }

    public var currentPluginGenerationID: String? { activeGenerationID }

    private func withInvocation<T>(_ invocation: PluginInvocationDiagnostics?, _ work: () -> T) -> T {
        let previous = activeInvocation
        activeInvocation = invocation
        defer { activeInvocation = previous }
        return work()
    }

    private func withInvocation<T>(
        _ invocation: PluginInvocationDiagnostics?, generationID: String?, _ work: () -> T
    ) -> T {
        let previousInvocation = activeInvocation
        let previousGeneration = activeGenerationID
        activeInvocation = invocation
        activeGenerationID = generationID
        defer {
            activeInvocation = previousInvocation
            activeGenerationID = previousGeneration
        }
        return work()
    }

    /// Touches EVERY in-flight call of `pluginID`, because a bridge callback
    /// cannot tell which of a plugin's overlapping hooks its continuation
    /// belongs to. Two concurrent calls of one plugin therefore keep each other
    /// alive while either is active. A caller that cannot name a plugin — a
    /// bridge above this tier — touches them all.
    public func notePluginActivity(pluginID: String?) {
        notePluginActivity(pluginID: pluginID, generationID: nil)
    }

    public func notePluginActivity(pluginID: String?, generationID: String?) {
        lock.lock()
        let calls: [PluginPendingCall]
        if let generationID {
            calls = inFlight[generationID] ?? []
        } else if let pluginID {
            let generations = generationStates.values
                .filter { $0.pluginID == pluginID }
                .map(\.id)
            calls = generations.flatMap { inFlight[$0] ?? [] }
        } else {
            calls = inFlight.values.flatMap { $0 }
        }
        let idle = processContext.idle
        lock.unlock()
        for call in calls { call.touch() }
        idle?.touchIdle(pluginID: pluginID ?? "")
    }

    public func trackPendingPromise(_ box: PluginPromiseBox, pluginID: String?) {
        trackPendingPromise(box, pluginID: pluginID, generationID: nil)
    }

    public func trackPendingPromise(
        _ box: PluginPromiseBox, pluginID: String?, generationID: String?
    ) {
        guard let pluginID else { return }
        let key = generationID ?? activeGenerationID ?? pluginID
        lock.lock()
        var boxes = (pendingPromises[key] ?? []).filter { $0.value != nil }
        boxes.append(WeakPluginPromiseBox(box))
        pendingPromises[key] = boxes
        lock.unlock()
    }

    public func beginPluginOperation(
        pluginID: String, generationID: String
    ) -> PluginOperationLease? {
        lock.lock()
        guard let state = generationStates[generationID], state.pluginID == pluginID,
              (!state.retired || state.callCount > 0)
        else {
            lock.unlock()
            return nil
        }
        state.operationCount += 1
        lock.unlock()
        _ = scratch?.openScratchGeneration(pluginID: pluginID, generationID: generationID)
        return PluginOperationLease { [weak self] in
            self?.endPluginOperation(pluginID: pluginID, generationID: generationID)
        }
    }

    private func endPluginOperation(pluginID: String, generationID: String) {
        lock.lock()
        guard let state = generationStates[generationID] else {
            lock.unlock()
            return
        }
        state.operationCount = max(0, state.operationCount - 1)
        let shouldPrune = state.retired && state.callCount == 0 && state.operationCount == 0
        if shouldPrune { generationStates[generationID] = nil }
        lock.unlock()
        scratch?.closeScratchGeneration(pluginID: pluginID, generationID: generationID)
    }
}

/// Mutable bookkeeping for one loaded context. It outlives the active entry
/// during a reload so old callbacks can finish against the old generation
/// without touching the replacement's timeout or scratch state.
private final class RuntimeGenerationState {
    let id: String
    let pluginID: String
    var retired = false
    var callCount = 0
    var operationCount = 0
    var timeoutCount = 0

    init(id: String, pluginID: String) {
        self.id = id
        self.pluginID = pluginID
    }

    var isDrained: Bool { callCount == 0 && operationCount == 0 }
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

private enum PluginCallEvent {
    case settled(Result<String, PluginJSFailure>)
    case timedOut(neverStarted: Bool)
}

final class PluginPendingCall {
    private let lock = NSLock()
    private var abandoned = false
    private var activity = ContinuousClock.now
    // Capture on the caller's task: JSC and URLSession callbacks do not inherit
    // task locals, but must keep the outer ingestion watchdog alive too.
    private let pipelineActivity = IdleTimeLimit.activity

    var lastActivity: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }

    func touch() {
        lock.lock()
        guard !abandoned else { lock.unlock(); return }
        activity = .now
        lock.unlock()
        pipelineActivity?.touch()
    }

    /// Ignore progress arriving after the caller gave up.
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
