//
//  ExtensionFriendsReader.swift
//  ClipShare
//

import Foundation

/// A friend as the extensions need it: just the id and name. The full `Friend` /
/// `IdentityCard` types live in the main app (with crypto keys), so the
/// extensions decode only these fields from the App Group `friends.json` (whose
/// shape is `[{ card: { uuid, username, … }, dateAdded }]`).
struct ExtensionFriend: Equatable {
    let uuid: UUID
    let username: String
}

/// Reads the friends list from the App Group for the extension share flow.
enum ExtensionFriendsReader {

    /// Friends newest-first (matching `FriendsStore.items()`). Empty when none
    /// or the file is unreadable.
    static func friends() -> [ExtensionFriend] {
        guard let fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedReadingListAppender.appGroupID)?
            .appendingPathComponent("friends.json"),
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([StoredFriend].self, from: data)
        else { return [] }
        return stored
            .sorted { $0.dateAdded > $1.dateAdded }
            .map { ExtensionFriend(uuid: $0.card.uuid, username: $0.card.username) }
    }

    /// Decodes only the fields the extension needs; extra keys (keys/email/…)
    /// are ignored. Uses a plain `JSONDecoder` to match `FriendsStore`'s default
    /// date encoding.
    private struct StoredFriend: Decodable {
        struct Card: Decodable {
            let uuid: UUID
            let username: String
        }
        let card: Card
        let dateAdded: Date
    }
}
