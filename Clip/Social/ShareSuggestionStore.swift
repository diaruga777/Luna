//
//  ShareSuggestionStore.swift
//  Clip
//

import Foundation

/// Tracks who gets which links so saves can suggest (or automate) re-sharing:
/// sharing links from the same site (base URL = host minus "www.") to the same
/// friend twice in a row arms a suggestion for the next save; the user's
/// choice can suppress it or upgrade it to always-share. State machine:
///
///   manual share   → streak +1 (same friend) / reset to 1 (new friend);
///                    un-suppresses that friend (manual share re-enables).
///   new save       → auto-send to "always" friends; arm pendingSuggestion
///                    when streak ≥ 2 and the friend isn't suppressed/always.
///   choice         → Don't Share = suppress; Share Once = send + counts as
///                    a manual share; Always Share = auto-share from now on.
///
/// Persisted as JSON in the App Group (the intents run in the app process but
/// may be separated by process death between "save" and "apply choice").
final class ShareSuggestionStore {

    static let shared = ShareSuggestionStore()

    /// Suggestion/automation state for one base URL.
    struct SiteRule: Codable {
        var streakFriendUUID: UUID?
        var streakFriendUsername: String?
        var streakCount: Int = 0
        var suppressedFriendUUIDs: Set<UUID> = []
        /// UUID → username, for the Friends-screen display.
        var alwaysFriends: [UUID: String] = [:]
    }

    /// A suggestion armed by the most recent save, consumed by the intents.
    struct PendingSuggestion: Codable, Equatable {
        var baseURL: String
        var friendUUID: UUID
        var friendUsername: String
        var urlString: String
    }

    private struct State: Codable {
        var rules: [String: SiteRule] = [:]
        var pending: PendingSuggestion?
    }

    /// How many consecutive shares arm a suggestion.
    static let streakThreshold = 2

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let mutationLock = NSLock()

    init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    private var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        return container.appendingPathComponent("shareSuggestions.json")
    }

    /// Base URL for suggestion purposes: host, lowercased, minus "www.".
    static func baseURL(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Events

    /// A user-initiated share (in-app sheet, or a Share Once / Always choice).
    func recordManualShare(urlString: String, friendUUID: UUID, friendUsername: String) {
        guard let base = Self.baseURL(of: urlString) else { return }
        mutate { state in
            var rule = state.rules[base] ?? SiteRule()
            if rule.streakFriendUUID == friendUUID {
                rule.streakCount += 1
            } else {
                rule.streakFriendUUID = friendUUID
                rule.streakFriendUsername = friendUsername
                rule.streakCount = 1
            }
            // Manually sharing to a suppressed friend re-enables suggestions.
            rule.suppressedFriendUUIDs.remove(friendUUID)
            state.rules[base] = rule
        }
    }

    /// A NEW URL was just saved (never called for duplicate presses). Returns
    /// the friends to auto-share to, and arms/clears the pending suggestion.
    func handleNewSave(urlString: String) -> [(uuid: UUID, username: String)] {
        guard let base = Self.baseURL(of: urlString) else { return [] }
        var autoShareTargets: [(UUID, String)] = []
        mutate { state in
            let rule = state.rules[base] ?? SiteRule()
            autoShareTargets = rule.alwaysFriends.map { ($0.key, $0.value) }

            if let friendUUID = rule.streakFriendUUID,
               let username = rule.streakFriendUsername,
               rule.streakCount >= Self.streakThreshold,
               !rule.suppressedFriendUUIDs.contains(friendUUID),
               rule.alwaysFriends[friendUUID] == nil {
                state.pending = PendingSuggestion(
                    baseURL: base, friendUUID: friendUUID,
                    friendUsername: username, urlString: urlString)
            } else {
                state.pending = nil
            }
        }
        return autoShareTargets.map { (uuid: $0.0, username: $0.1) }
    }

    /// The suggestion armed by the last save, if any.
    func pendingSuggestion() -> PendingSuggestion? {
        loadState().pending
    }

    /// The user's answer to a surfaced suggestion.
    enum Choice: String, CaseIterable {
        case dontShare = "Don't Share"
        case shareOnce = "Share Once"
        case alwaysShare = "Always Share"
    }

    /// Applies a choice to the pending suggestion and clears it. Returns the
    /// suggestion so the caller can perform the actual send for
    /// `.shareOnce`/`.alwaysShare` (sends also count as manual shares).
    @discardableResult
    func applyChoice(_ choice: Choice) -> PendingSuggestion? {
        var consumed: PendingSuggestion?
        mutate { state in
            guard let pending = state.pending else { return }
            consumed = pending
            state.pending = nil
            var rule = state.rules[pending.baseURL] ?? SiteRule()
            switch choice {
            case .dontShare:
                rule.suppressedFriendUUIDs.insert(pending.friendUUID)
            case .shareOnce:
                break // recordManualShare runs after the send succeeds
            case .alwaysShare:
                rule.alwaysFriends[pending.friendUUID] = pending.friendUsername
            }
            state.rules[pending.baseURL] = rule
        }
        return consumed
    }

    // MARK: - Friends-screen support

    /// A friend to suggest sharing a given URL with, based on this site's
    /// history: the current streak friend, else any auto-share friend. Used by
    /// the end-of-article share UI. nil when there's nothing to suggest.
    func suggestedFriend(forURLString urlString: String) -> (uuid: UUID, username: String)? {
        guard let base = Self.baseURL(of: urlString),
              let rule = loadState().rules[base]
        else { return nil }
        if let uuid = rule.streakFriendUUID, let name = rule.streakFriendUsername,
           rule.streakCount >= 1, !rule.suppressedFriendUUIDs.contains(uuid) {
            return (uuid, name)
        }
        if let (uuid, name) = rule.alwaysFriends.first {
            return (uuid, name)
        }
        return nil
    }

    /// Whether a base URL is auto-shared to a friend.
    func isAlwaysShared(baseURL: String, friendUUID: UUID) -> Bool {
        loadState().rules[baseURL]?.alwaysFriends[friendUUID] != nil
    }

    /// Directly turns auto-share for a base URL to a friend on or off (the
    /// friend-detail toggle, independent of the suggestion streak).
    func setAlwaysShare(
        baseURL: String, friendUUID: UUID, friendUsername: String, enabled: Bool
    ) {
        mutate { state in
            var rule = state.rules[baseURL] ?? SiteRule()
            if enabled {
                rule.alwaysFriends[friendUUID] = friendUsername
                rule.suppressedFriendUUIDs.remove(friendUUID)
            } else {
                rule.alwaysFriends.removeValue(forKey: friendUUID)
            }
            state.rules[baseURL] = rule
        }
    }

    /// Base URLs auto-shared to a friend.
    func alwaysSharedBaseURLs(friendUUID: UUID) -> [String] {
        loadState().rules
            .filter { $0.value.alwaysFriends[friendUUID] != nil }
            .map(\.key)
            .sorted()
    }

    /// Stops auto-sharing one base URL to a friend.
    func removeAlwaysShare(baseURL: String, friendUUID: UUID) {
        mutate { state in
            state.rules[baseURL]?.alwaysFriends.removeValue(forKey: friendUUID)
        }
    }

    /// Wipes ALL suggestion/automation state involving a friend.
    func wipe(friendUUID: UUID) {
        mutate { state in
            for (base, var rule) in state.rules {
                rule.alwaysFriends.removeValue(forKey: friendUUID)
                rule.suppressedFriendUUIDs.remove(friendUUID)
                if rule.streakFriendUUID == friendUUID {
                    rule.streakFriendUUID = nil
                    rule.streakFriendUsername = nil
                    rule.streakCount = 0
                }
                state.rules[base] = rule
            }
            if state.pending?.friendUUID == friendUUID {
                state.pending = nil
            }
        }
    }

    // MARK: - Persistence

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func mutate(_ body: (inout State) -> Void) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var state = loadState()
        body(&state)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
