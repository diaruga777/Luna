//
//  PluginBrowserDeferring.swift
//  LunaPluginIngest
//

import Foundation
import LunaStorage

/// Records a `luna.browser.open` call a process cannot present
/// (`claudedocs/plans/plugin-platform.md` §8.2).
///
/// The browser bridge — Wave 2, in LunaPluginRuntime — calls this and then
/// rejects with `browser-deferred`, which the stage turns into
/// `Outcome.locked`. It is a seam rather than a direct store call because the
/// bridge deferring in the Safari world writes through native messaging
/// instead, and because the save id is not known until the row is written.
public protocol PluginBrowserDeferring: AnyObject {
    /// Stores the request against `saveID` and reports whether it landed.
    func defer_(request json: String, pluginID: String, saveID: UUID) -> Bool
    /// The result of a completed browser step, once. Nil while the save is
    /// still locked.
    func takeResult(saveID: UUID) -> String?
    /// Whether a completed result is waiting to be taken. Reading it does not
    /// consume it, so the walk can call the hook with `reason: "resume"` and the
    /// bridge can still answer the plugin's own `luna.browser.open` with it.
    func hasCompletedResult(saveID: UUID) -> Bool
}

public extension PluginBrowserDeferring {
    func hasCompletedResult(saveID: UUID) -> Bool { false }
}

/// The App-Group-backed witness. It is what every in-process bridge uses; only
/// the Safari world needs another.
public final class StoredPluginBrowserDeferral: PluginBrowserDeferring {
    private let store: PluginBrowserRequestStore

    public init(store: PluginBrowserRequestStore = .shared) {
        self.store = store
    }

    public func defer_(request json: String, pluginID: String, saveID: UUID) -> Bool {
        store.put(saveID: saveID, pluginID: pluginID, requestJSON: json)
        return store.pending(for: saveID) != nil
    }

    public func takeResult(saveID: UUID) -> String? {
        store.takeResult(saveID: saveID)
    }

    public func hasCompletedResult(saveID: UUID) -> Bool {
        store.record(for: saveID)?.resultJSON != nil
    }
}

/// The installed witness. `PluginPlatformComposition.install()` fills it.
public enum PluginBrowserDeferral {
    public static var witness: (any PluginBrowserDeferring)?
}
