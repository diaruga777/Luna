//
//  SourceSendSettings.swift
//  Clip
//

import ClipModels
import Foundation

/// Per-capture-source auto-send configuration for one ereader destination
/// (Kindle, Boox). Each source can be enabled independently:
///
///   • App Intents (Shortcuts) and in-app saves — governed by the destination's
///     existing send mode (off / all saves / double save).
///   • Email — on/off.
///   • Share sheet & paste — on/off.
///   • Friend shares — on/off, with a default plus per-friend overrides.
///
/// Persisted in standard defaults under a per-destination key prefix. Sources
/// other than App Intents default to the legacy "all saves" behavior so existing
/// setups are unchanged until the user touches the new controls.
enum SourceSendSettings {

    // MARK: Legacy / App-Intents mode (the destination's existing global mode)

    /// The send mode governing App Intents (Shortcuts) and in-app saves — backed
    /// by the destination's existing `sendMode` so nothing migrates.
    static func appIntentsMode(forDestination id: String) -> ArticleSendMode {
        switch id {
        case ArticleDestinationID.kindle: return KindleSendSettings.sendMode
        case ArticleDestinationID.boox: return BooxSendSettings.sendMode
        default: return .off
        }
    }

    static func setAppIntentsMode(_ mode: ArticleSendMode, forDestination id: String) {
        switch id {
        case ArticleDestinationID.kindle: KindleSendSettings.sendMode = mode
        case ArticleDestinationID.boox: BooxSendSettings.sendMode = mode
        default: break
        }
    }

    // MARK: Email

    static func emailEnabled(forDestination id: String) -> Bool {
        // Kindle reuses the existing "Also Send to Kindle" import toggle so the
        // two surfaces never diverge (email only ever arrives via the importer,
        // which historically sent only to Kindle).
        if id == ArticleDestinationID.kindle { return IncomingMailSettings.autoSendToKindle }
        return boolWithDefault(key(id, "email"), default: legacyDefault(forDestination: id))
    }

    static func setEmailEnabled(_ on: Bool, forDestination id: String) {
        if id == ArticleDestinationID.kindle {
            IncomingMailSettings.autoSendToKindle = on
            return
        }
        UserDefaults.standard.set(on, forKey: key(id, "email"))
    }

    // MARK: Share sheet & paste

    static func shareAndPasteEnabled(forDestination id: String) -> Bool {
        boolWithDefault(key(id, "sharePaste"), default: legacyDefault(forDestination: id))
    }

    static func setShareAndPasteEnabled(_ on: Bool, forDestination id: String) {
        UserDefaults.standard.set(on, forKey: key(id, "sharePaste"))
    }

    // MARK: Friend shares (default + per-friend overrides)

    /// The default for friends without an explicit override.
    static func friendSharesEnabledDefault(forDestination id: String) -> Bool {
        boolWithDefault(key(id, "friendDefault"), default: legacyDefault(forDestination: id))
    }

    static func setFriendSharesEnabledDefault(_ on: Bool, forDestination id: String) {
        UserDefaults.standard.set(on, forKey: key(id, "friendDefault"))
    }

    /// Per-friend enablement, falling back to the destination's friend default.
    static func friendShareEnabled(forDestination id: String, username: String) -> Bool {
        friendOverrides(forDestination: id)[username] ?? friendSharesEnabledDefault(forDestination: id)
    }

    static func setFriendShareEnabled(_ on: Bool, forDestination id: String, username: String) {
        var overrides = friendOverrides(forDestination: id)
        overrides[username] = on
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: key(id, "friendOverrides"))
        }
    }

    private static func friendOverrides(forDestination id: String) -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: key(id, "friendOverrides")),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }

    // MARK: Resolution

    /// The effective send mode for an item, given its capture source and (for
    /// friend shares) the sharing friend's username.
    static func sendMode(
        forDestination id: String, source: CaptureSource, friendUsername: String?
    ) -> ArticleSendMode {
        switch source {
        case .appIntent, .manual:
            return appIntentsMode(forDestination: id)
        case .email:
            return emailEnabled(forDestination: id) ? .allSaves : .off
        case .shareSheet, .paste:
            return shareAndPasteEnabled(forDestination: id) ? .allSaves : .off
        case .friendShare:
            let enabled = friendUsername
                .map { friendShareEnabled(forDestination: id, username: $0) }
                ?? friendSharesEnabledDefault(forDestination: id)
            return enabled ? .allSaves : .off
        }
    }

    // MARK: Helpers

    /// Preserves the legacy behavior: when the destination's mode was "all
    /// saves", everything was sent, so the other sources default on; otherwise
    /// off.
    private static func legacyDefault(forDestination id: String) -> Bool {
        appIntentsMode(forDestination: id) == .allSaves
    }

    private static func key(_ destinationID: String, _ suffix: String) -> String {
        "send.\(destinationID).\(suffix)"
    }

    private static func boolWithDefault(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? def
            : UserDefaults.standard.bool(forKey: key)
    }
}
