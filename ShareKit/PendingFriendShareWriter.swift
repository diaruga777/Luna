//
//  PendingFriendShareWriter.swift
//  ClipShare
//

import Foundation

/// Writes outgoing friend-shares to the App Group queue the main app drains
/// (`SocialMessageCenter.drainPendingFriendShares`). The extensions have no
/// CloudKit/crypto, so they can't send directly — they queue, and the main app
/// delivers on next launch/foreground. The JSON shape must match the app's
/// `PendingFriendShare`.
enum PendingFriendShareWriter {
    private struct Share: Codable {
        let friendUUID: UUID
        let urlString: String
    }

    static func enqueue(friendUUID: UUID, urlString: String) {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return }
        guard let fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedReadingListAppender.appGroupID)?
            .appendingPathComponent("pendingFriendShares.json")
        else { return }
        var queue: [Share] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Share].self, from: data) {
            queue = decoded
        }
        queue.append(Share(friendUUID: friendUUID, urlString: url.absoluteString))
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
