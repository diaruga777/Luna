//
//  InteropAppGroupDefaults.swift
//  LunaInterop
//

import LunaAppConfig
import Foundation

/// The single shared `UserDefaults` suite every `LunaInterop` type reads/writes
/// through by default — the App Group container, so the "interop unlocked" flag
/// and the "app X is installed" markers are visible to every Luna app/extension
/// process. Every public type here accepts an injected `UserDefaults` so tests
/// never touch the real App Group suite.
public enum InteropAppGroupDefaults {
    public static var current: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }
}
