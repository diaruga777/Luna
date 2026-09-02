//
//  PluginIngestScope.swift
//  LunaPluginIngest
//

import Foundation
import LunaPluginKit

/// The saves whose `ingest` hook is running, per plugin, readable from the
/// bridges that call answers into (`claudedocs/plans/plugin-platform.md` §8).
///
/// `luna.browser.open` needs the save id, and the JavaScript that calls it runs
/// on the runtime's own serial queue rather than inside the walk's task — so a
/// task-local never reaches it. `SavesIngestor` spawns one task per pending row
/// with no concurrency limit, so several walks of one plugin overlap: a single
/// global slot let the second walk's save id displace the first, and the first
/// plugin's deferred browser request was then filed against the wrong save.
public enum PluginIngestScope {

    private static let lock = NSLock()
    /// Plugin id → the saves whose `ingest` hook that plugin is running now.
    private static var inFlight: [String: [UUID]] = [:]

    /// The saves this plugin's `ingest` hook is running for, in the order the
    /// walks started.
    public static func saveIDs(pluginID: String) -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[pluginID] ?? []
    }

    /// Publishes `saveID` for the length of `body`, which is one hook call.
    public static func run<T>(
        saveID: UUID?, pluginID: String, _ body: () async -> T
    ) async -> T {
        guard let saveID else { return await body() }
        add(saveID, pluginID: pluginID)
        let result = await body()
        remove(saveID, pluginID: pluginID)
        return result
    }

    private static func add(_ saveID: UUID, pluginID: String) {
        lock.lock()
        inFlight[pluginID, default: []].append(saveID)
        lock.unlock()
    }

    private static func remove(_ saveID: UUID, pluginID: String) {
        lock.lock()
        var ids = inFlight[pluginID] ?? []
        if let index = ids.firstIndex(of: saveID) { ids.remove(at: index) }
        inFlight[pluginID] = ids.isEmpty ? nil : ids
        lock.unlock()
    }
}
