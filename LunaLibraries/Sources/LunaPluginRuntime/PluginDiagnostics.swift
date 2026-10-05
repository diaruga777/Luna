//
//  PluginDiagnostics.swift
//  LunaPluginRuntime
//

import Foundation
import LunaModels
import LunaStorage

/// Where a plugin's own lines go.
public protocol PluginDiagnosticsRecording: AnyObject {
    func record(_ message: String, pluginID: String)

    /// Records against one hook invocation when it is still active. A late
    /// callback must be visible in the global log but must not be appended to a
    /// save that has already completed.
    func record(
        _ message: String, pluginID: String, invocation: PluginInvocationDiagnostics?
    )
}

public extension PluginDiagnosticsRecording {
    func record(
        _ message: String, pluginID: String, invocation: PluginInvocationDiagnostics?
    ) {
        record(message, pluginID: pluginID)
    }
}

/// The per-hook diagnostic sink. The recorder is weak so an asynchronous
/// callback cannot keep a completed save alive; `close()` makes the boundary
/// explicit even when the save object itself is still retained by a caller.
public final class PluginInvocationDiagnostics: @unchecked Sendable {
    public let id: UUID
    private weak var recorder: SaveDiagnosticsRecorder?
    private let lock = NSLock()
    private var isOpen = true

    init(id: UUID, recorder: SaveDiagnosticsRecorder?) {
        self.id = id
        self.recorder = recorder
    }

    func record(_ message: String, category: String) {
        lock.lock()
        guard isOpen else {
            lock.unlock()
            return
        }
        let recorder = self.recorder
        lock.unlock()
        recorder?.record(message, category: category)
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    /// Stops late bridge callbacks from writing to the completed save trace.
    public func close() {
        lock.lock()
        isOpen = false
        recorder = nil
        lock.unlock()
    }
}

/// A plugin's line lands in two places: its own `DiagnosticLog` category, and —
/// while a save is being made — that save's diagnostics trace, so a plugin's
/// classify and ingest steps appear in the failed-save export users already
/// have.
///
/// Plugin JS runs on the runtime's own queue where the ingest task's locals are
/// not visible, so a recorder is carried by an invocation token instead of a
/// process-global mutable property.
public final class PluginDiagnostics: PluginDiagnosticsRecording, @unchecked Sendable {

    public static let shared = PluginDiagnostics()

    private let log: DiagnosticLog
    public init(log: DiagnosticLog = .shared) { self.log = log }

    public func record(_ message: String, pluginID: String) {
        let category = PluginDiagnostics.category(for: pluginID)
        log.record(message, category: category)
        SaveDiagnostics.record(message, category: category)
    }

    public func record(
        _ message: String, pluginID: String, invocation: PluginInvocationDiagnostics?
    ) {
        let category = PluginDiagnostics.category(for: pluginID)
        log.record(message, category: category)
        if let invocation {
            invocation.record(message, category: category)
        } else {
            SaveDiagnostics.record(message, category: category)
        }
    }

    /// The diagnostics category one plugin writes under.
    public static func category(for pluginID: String) -> String { "plugin.\(pluginID)" }
}

/// Drops every line. A caller that wants no diagnostics installs this rather
/// than an optional nobody reads.
public final class DiscardedPluginDiagnostics: PluginDiagnosticsRecording {
    public init() {}
    public func record(_ message: String, pluginID: String) {}
}
