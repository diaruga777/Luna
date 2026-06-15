//
//  FriendNotificationSettings.swift
//  Clip
//

import Foundation

/// Whether the user gets a local notification when a friend shares an article.
/// Off by default; the per-friend toggle stores the friends opted IN.
enum FriendNotificationSettings {
    private static let enabledKey = "notifyOnShareFriendUUIDs"

    static func isNotifyEnabled(friendUUID: UUID) -> Bool {
        enabledUUIDs().contains(friendUUID.uuidString)
    }

    static func setNotify(_ enabled: Bool, friendUUID: UUID) {
        var ids = enabledUUIDs()
        if enabled {
            ids.insert(friendUUID.uuidString)
        } else {
            ids.remove(friendUUID.uuidString)
        }
        UserDefaults.standard.set(Array(ids), forKey: enabledKey)
    }

    private static func enabledUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
    }
}
