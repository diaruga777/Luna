//
//  DoubleSaveActionStore.swift
//  Luna
//

import LunaAppConfig
import Foundation
import LunaModels

/// What a Reader double save (the same URL saved twice within 7 seconds via the
/// Action Button's Save App Intent — no other save surface) should do.
public enum DoubleSaveAction: String, CaseIterable {
    /// Email the article's EPUB to the configured Kindle address (the existing
    /// send-to-Kindle pipeline). The default.
    case sendToKindle
    /// Email the article to one or more friends (the existing email-based
    /// friend-sharing pipeline), per `DoubleSaveFriendMode`.
    case sendToFriend

    public var displayName: String {
        switch self {
        case .sendToKindle: return L10n.string("Send to Kindle")
        case .sendToFriend: return L10n.string("Send to Contact")
        }
    }
}

/// How a `sendToFriend` double save picks its recipients.
public enum DoubleSaveFriendMode: String, CaseIterable {
    /// Send to the preset recipient emails immediately, no UI.
    case preset
    /// Open Luna and present the friend-selector share screen for the item.
    case askEveryTime

    public var displayName: String {
        switch self {
        case .preset: return L10n.string("Preset Contacts")
        case .askEveryTime: return L10n.string("Ask Every Time")
        }
    }
}

/// App-Group-backed, per-surface settings for the double-save action, plus the
/// one-shot "friend prompt pending" hand-off the Save App Intent writes right
/// before it asks the Shortcut to open Luna (the `askEveryTime` path): the
/// foregrounding scene consumes it and presents the friend selector.
public final class DoubleSaveActionStore {

    public static let shared = DoubleSaveActionStore()

    /// How long a written friend prompt stays valid. Foregrounding usually
    /// happens within a second or two of the intent; anything older is a stale
    /// leftover (e.g. the user dismissed the shortcut's open) and is dropped.
    public static let friendPromptLifetime: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let now: () -> Date

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
        self.now = now
    }

    private func actionKey(forSurface surface: String) -> String {
        "doubleSave.action.\(surface)"
    }

    private func friendModeKey(forSurface surface: String) -> String {
        "doubleSave.friendMode.\(surface)"
    }

    private func presetEmailsKey(forSurface surface: String) -> String {
        "doubleSave.presetFriendEmails.\(surface)"
    }

    private func promptURLKey(forSurface surface: String) -> String {
        "doubleSave.pendingFriendPromptURL.\(surface)"
    }

    private func promptDateKey(forSurface surface: String) -> String {
        "doubleSave.pendingFriendPromptDate.\(surface)"
    }

    // MARK: - Settings

    public func action(forSurface surface: String) -> DoubleSaveAction {
        defaults.string(forKey: actionKey(forSurface: surface))
            .flatMap(DoubleSaveAction.init(rawValue:)) ?? .sendToKindle
    }

    public func setAction(_ action: DoubleSaveAction, forSurface surface: String) {
        defaults.set(action.rawValue, forKey: actionKey(forSurface: surface))
    }

    public func friendMode(forSurface surface: String) -> DoubleSaveFriendMode {
        defaults.string(forKey: friendModeKey(forSurface: surface))
            .flatMap(DoubleSaveFriendMode.init(rawValue:)) ?? .askEveryTime
    }

    public func setFriendMode(_ mode: DoubleSaveFriendMode, forSurface surface: String) {
        defaults.set(mode.rawValue, forKey: friendModeKey(forSurface: surface))
    }

    /// The preset recipient emails (lowercased addresses), in selection order.
    public func presetFriendEmails(forSurface surface: String) -> [String] {
        defaults.stringArray(forKey: presetEmailsKey(forSurface: surface)) ?? []
    }

    public func setPresetFriendEmails(_ emails: [String], forSurface surface: String) {
        defaults.set(emails, forKey: presetEmailsKey(forSurface: surface))
    }

    // MARK: - Ask-every-time hand-off

    /// Records that the app, once foregrounded, should present the friend
    /// selector for `urlString`.
    public func setPendingFriendPrompt(urlString: String, forSurface surface: String) {
        defaults.set(urlString, forKey: promptURLKey(forSurface: surface))
        defaults.set(now().timeIntervalSinceReferenceDate,
                     forKey: promptDateKey(forSurface: surface))
    }

    /// One-shot consume: returns the pending prompt's URL (clearing it), or nil
    /// when there is none or it has gone stale.
    public func takePendingFriendPrompt(forSurface surface: String) -> String? {
        defer {
            defaults.removeObject(forKey: promptURLKey(forSurface: surface))
            defaults.removeObject(forKey: promptDateKey(forSurface: surface))
        }
        guard let urlString = defaults.string(forKey: promptURLKey(forSurface: surface)),
              defaults.object(forKey: promptDateKey(forSurface: surface)) != nil
        else { return nil }
        let written = Date(timeIntervalSinceReferenceDate:
            defaults.double(forKey: promptDateKey(forSurface: surface)))
        guard now().timeIntervalSince(written) < Self.friendPromptLifetime else { return nil }
        return urlString
    }
}
