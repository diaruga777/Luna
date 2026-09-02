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
}

/// A plugin's line lands in two places: its own `DiagnosticLog` category, and —
/// while a save is being made — that save's diagnostics trace, so a plugin's
/// classify and ingest steps appear in the failed-save export users already
/// have.
///
/// The save recorder is a PROPERTY rather than a task-local, because plugin JS
/// runs on the runtime's own queue where the ingest task's locals are not
/// visible. The ingest stage binds it around the hook calls of one save.
public final class PluginDiagnostics: PluginDiagnosticsRecording, @unchecked Sendable {

    public static let shared = PluginDiagnostics()

    private let log: DiagnosticLog
    private let lock = NSLock()
    private var recorder: SaveDiagnosticsRecorder?

    public init(log: DiagnosticLog = .shared) { self.log = log }

    /// The trace of the save being made right now, or nil between saves.
    public var saveRecorder: SaveDiagnosticsRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return recorder }
        set { lock.lock(); recorder = newValue; lock.unlock() }
    }

    public func record(_ message: String, pluginID: String) {
        let category = PluginDiagnostics.category(for: pluginID)
        log.record(message, category: category)
        saveRecorder?.record(message, category: category)
        SaveDiagnostics.record(message, category: category)
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
