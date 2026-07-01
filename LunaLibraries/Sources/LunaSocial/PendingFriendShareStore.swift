//
//  PendingFriendShareStore.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// One outgoing friend-share queued by the share extension. The extension can't
/// do the CloudKit send (no crypto/identity), so it records the intent here and
/// the main app sends it on next launch/foreground.
public struct PendingFriendShare: Codable, Equatable {
    public let friendUUID: UUID
    public let urlString: String
}

/// App-Group-backed queue of pending outgoing friend shares. The share
/// extension enqueues (via its own copy of the file shape); the main app drains.
public enum PendingFriendShareStore {
    public static let appGroupID = AppConfig.appGroupID

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("pendingFriendShares.json")
    }

    public static func enqueue(_ share: PendingFriendShare) {
        guard let fileURL else { return }
        var queue = load(fileURL)
        queue.append(share)
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Returns and clears the queue.
    public static func drainAll() -> [PendingFriendShare] {
        guard let fileURL else { return [] }
        let queue = load(fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        return queue
    }

    private static func load(_ fileURL: URL) -> [PendingFriendShare] {
        guard let data = try? Data(contentsOf: fileURL),
              let queue = try? JSONDecoder().decode([PendingFriendShare].self, from: data)
        else { return [] }
        return queue
    }
}
