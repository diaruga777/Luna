//
//  FriendNotificationSettings.swift
//  Clip
//

import Foundation

/// Whether the user gets a local notification when a friend shares an article.
/// Off by default; the per-friend toggle stores the friends opted IN. Separately
/// tracks which friends have EVER shared with us, so the first share from a new
/// friend can always notify (with a hint to enable future notifications).
public enum FriendNotificationSettings {
    private static let enabledKey = "notifyOnShareFriendUUIDs"
    private static let everSharedKey = "everSharedFriendUUIDs"

    public static func isNotifyEnabled(friendUUID: UUID) -> Bool {
        enabledUUIDs().contains(friendUUID.uuidString)
    }

    public static func setNotify(_ enabled: Bool, friendUUID: UUID) {
        var ids = enabledUUIDs()
        if enabled {
            ids.insert(friendUUID.uuidString)
        } else {
            ids.remove(friendUUID.uuidString)
        }
        UserDefaults.standard.set(Array(ids), forKey: enabledKey)
    }

    /// Whether this friend has shared with us before (at all). False the first time.
    public static func hasSharedBefore(friendUUID: UUID) -> Bool {
        everSharedUUIDs().contains(friendUUID.uuidString)
    }

    /// Records that this friend has now shared with us (idempotent).
    public static func markHasShared(friendUUID: UUID) {
        var ids = everSharedUUIDs()
        ids.insert(friendUUID.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: everSharedKey)
    }

    private static func enabledUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
    }

    private static func everSharedUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: everSharedKey) ?? [])
    }
}
