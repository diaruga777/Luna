//
//  MigratingAppGroupDefaults.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// A preference store on the shared App-Group suite that still answers with a
/// value an earlier build left in the process's own `standard` defaults.
///
/// A setting kept in `standard` is per-app: the central Luna app and Luna Reader
/// each hold their own copy even when both describe the ONE connected email
/// account. Reading through the group suite converges them. A read finds the
/// group value when there is one; otherwise it takes the legacy value, copies it
/// into the group, and returns it — so whichever app wrote first supplies the
/// starting value and later reads never consult `standard` again. Writes only
/// ever go to the group.
///
/// When the group suite cannot be opened (no entitlement), group and legacy are
/// the same store and every access lands in `standard`.
public struct MigratingAppGroupDefaults {
    private let group: UserDefaults
    private let legacy: UserDefaults

    /// The real App Group suite over `standard`.
    public init(appGroupID: String = AppConfig.appGroupID, legacy: UserDefaults = .standard) {
        self.group = resolvedAppGroupDefaults(appGroupID: appGroupID, testOverride: nil) ?? legacy
        self.legacy = legacy
    }

    /// Two explicit suites, so a test can drive both halves of the read-through.
    public init(group: UserDefaults, legacy: UserDefaults) {
        self.group = group
        self.legacy = legacy
    }

    /// The group's value for `key`, else the legacy value — which is written
    /// into the group before it is returned.
    public func object(forKey key: String) -> Any? {
        if let value = group.object(forKey: key) { return value }
        guard group !== legacy, let value = legacy.object(forKey: key) else { return nil }
        group.set(value, forKey: key)
        return value
    }

    public func set(_ value: Any?, forKey key: String) {
        group.set(value, forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        (object(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    public func integer(forKey key: String) -> Int {
        (object(forKey: key) as? NSNumber)?.intValue ?? 0
    }

    public func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    public func stringArray(forKey key: String) -> [String]? {
        object(forKey: key) as? [String]
    }

    public func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }
}
