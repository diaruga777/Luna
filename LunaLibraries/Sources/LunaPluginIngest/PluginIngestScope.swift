//
//  PluginIngestScope.swift
//  LunaPluginIngest
//

import Foundation
import LunaPluginKit

/// The save one `ingest` hook call belongs to, readable from the bridges that
/// call answers into (`claudedocs/plans/plugin-platform.md` §8).
///
/// `luna.browser.open` needs the save id, and the JavaScript that calls it runs
/// on the runtime's own serial queue rather than inside the walk's task — so a
/// task-local never reaches it. The runtime already holds ONE call in flight
/// (`activeCall`, `invocationID`); this is the same shape for the same reason,
/// and `run` restores whatever it displaced.
public enum PluginIngestScope {

    private static let lock = NSLock()
    private static var scope: (saveID: UUID, reason: PluginIngestReason)?

    /// The save whose `ingest` hook is running, or nil outside one.
    public static var currentSaveID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return scope?.saveID
    }

    /// Publishes `saveID` for the length of `body`, which is one hook call.
    public static func run<T>(
        saveID: UUID?, reason: PluginIngestReason, _ body: () async -> T
    ) async -> T {
        let previous = swap(saveID.map { ($0, reason) })
        let result = await body()
        _ = swap(previous)
        return result
    }

    private static func swap(
        _ next: (saveID: UUID, reason: PluginIngestReason)?
    ) -> (saveID: UUID, reason: PluginIngestReason)? {
        lock.lock()
        defer { lock.unlock() }
        let previous = scope
        scope = next
        return previous
    }
}
