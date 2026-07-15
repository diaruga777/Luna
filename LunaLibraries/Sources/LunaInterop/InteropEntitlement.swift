//
//  InteropEntitlement.swift
//  LunaInterop
//

import Foundation

/// The shared "cross-app interop unlocked" flag: a single App Group boolean any
/// of the three Luna apps can set (after a verified StoreKit purchase in ANY of
/// them) and every app trusts. There is no per-app entitlement — one non-consumable
/// bought in one Luna app unlocks cross-app saving in all three, because they all
/// read the same App Group flag.
///
/// Injectable `UserDefaults` so tests never touch the real App Group suite.
public struct InteropEntitlement {
    /// `group.<namespace>` App Group key. Never renamed casually — it's read by
    /// every Luna app/extension process via `InteropAppGroupDefaults`.
    public static let unlockedKey = "interop.unlocked"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = InteropAppGroupDefaults.current) {
        self.defaults = defaults
    }

    /// The default instance, reading/writing the real App Group suite. Production
    /// call sites use this; tests construct their own `InteropEntitlement` with a
    /// scratch `UserDefaults(suiteName:)`.
    public static let shared = InteropEntitlement()

    /// Whether ANY Luna app has ever recorded a verified interop purchase on this
    /// device.
    public var isUnlocked: Bool {
        defaults.bool(forKey: Self.unlockedKey)
    }

    /// Records a verified purchase (StoreKit transaction, in this app or a
    /// restore) as unlocking cross-app interop for every Luna app sharing this
    /// App Group. Idempotent — safe to call for every verified transaction,
    /// including ones already recorded.
    public func recordUnlocked() {
        defaults.set(true, forKey: Self.unlockedKey)
    }
}
