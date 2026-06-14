//
//  FriendNotificationSettings.swift
//  Clip
//

import Foundation

/// Whether the user gets a local notification when a friend shares an article.
/// Defaults to ON for every friend; the per-friend toggle stores the muted
/// ones, so notifications work out of the box and can be silenced per friend.
enum FriendNotificationSettings {
    private static let mutedKey = "mutedShareNotificationFriendUUIDs"

    static func isNotifyEnabled(friendUUID: UUID) -> Bool {
        !mutedUUIDs().contains(friendUUID.uuidString)
    }

    static func setNotify(_ enabled: Bool, friendUUID: UUID) {
        var ids = mutedUUIDs()
        if enabled {
            ids.remove(friendUUID.uuidString)
        } else {
            ids.insert(friendUUID.uuidString)
        }
        UserDefaults.standard.set(Array(ids), forKey: mutedKey)
    }

    private static func mutedUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? [])
    }
}
