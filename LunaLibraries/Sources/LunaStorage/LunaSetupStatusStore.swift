//
//  LunaSetupStatusStore.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// Shared "has ever worked" markers for the left setup tray.
///
/// Faceted apps share one completion marker. Central Luna intentionally keeps
/// its own marker because its own Safari extension and shortcut must each run.
public final class LunaSetupStatusStore {
    public static let shared = LunaSetupStatusStore()

    public static let sharedSafariKey = "setup.safari.hasRun.shared"
    public static let centralSafariKey = "setup.safari.hasRun.luna"
    public static let sharedShortcutKey = "setup.shortcut.hasRun.shared"
    public static let centralShortcutKey = "setup.shortcut.hasRun.luna"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    public func safariHasRun(isCentral: Bool) -> Bool {
        defaults.bool(forKey: isCentral ? Self.centralSafariKey : Self.sharedSafariKey)
    }

    public func shortcutHasRun(isCentral: Bool) -> Bool {
        defaults.bool(forKey: isCentral ? Self.centralShortcutKey : Self.sharedShortcutKey)
    }

    public func recordShortcutRun(isCentral: Bool) {
        defaults.set(true, forKey: isCentral ? Self.centralShortcutKey : Self.sharedShortcutKey)
    }
}

