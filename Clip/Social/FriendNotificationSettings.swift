//
//  FriendNotificationSettings.swift
//  Clip
//

import Foundation

/// Which friends the user wants a local notification from when they share an
/// article. Stored as a set of friend UUIDs in standard defaults.
enum FriendNotificationSettings {
    private static let key = "notifyOnShareFriendUUIDs"

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
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    private static func enabledUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}
