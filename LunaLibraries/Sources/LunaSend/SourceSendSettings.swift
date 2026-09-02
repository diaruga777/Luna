//
//  SourceSendSettings.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// Per-capture-source auto-send configuration for one ereader destination
/// Each source can be enabled independently:
///
///   • App Intents (Shortcuts) and in-app saves — governed by the destination's
///     existing send mode (off / all saves / double save).
///   • Email — on/off.
///   • Share sheet & paste — on/off.
///   • Friend shares — on/off, with a default plus per-friend overrides.
///
/// Persisted in the shared App-Group suite under a per-destination key prefix,
/// with a read-through for the values an older per-app build left in `standard`
/// (`MigratingAppGroupDefaults`) — the central app and the Reader send from ONE
/// connected account, so "email saves go to Kindle" cannot be two answers.
/// Sources other than App Intents default to the legacy "all saves" behavior so
/// existing setups are unchanged until the user touches the new controls.
public enum SourceSendSettings {

    /// Overridable so tests can drive both halves of the read-through without
    /// touching the real container. Production code never sets it.
    static var testDefaultsOverride: MigratingAppGroupDefaults?

    private static var defaults: MigratingAppGroupDefaults {
        testDefaultsOverride ?? MigratingAppGroupDefaults()
    }

    // MARK: Legacy / App-Intents mode (the destination's existing global mode)

    /// The send mode governing App Intents (Shortcuts) and in-app saves. The
    /// two destinations that predate plugins keep their own settings key so
    /// nothing migrates; every other destination reads its own key here and
    /// starts `.off` — a destination a user just installed auto-sends only
    /// once they ask it to.
    public static func appIntentsMode(forDestination id: String) -> ArticleSendMode {
        switch id {
        case ArticleDestinationID.kindle: return KindleSendSettings.sendMode
        case ArticleDestinationID.xteink: return XteinkSendSettings.sendMode
        default:
            return defaults.string(forKey: key(id, "appIntentsMode"))
                .flatMap(ArticleSendMode.init(rawValue:)) ?? .off
        }
    }

    public static func setAppIntentsMode(_ mode: ArticleSendMode, forDestination id: String) {
        switch id {
        case ArticleDestinationID.kindle: KindleSendSettings.sendMode = mode
        case ArticleDestinationID.xteink: XteinkSendSettings.sendMode = mode
        default: defaults.set(mode.rawValue, forKey: key(id, "appIntentsMode"))
        }
    }

    // MARK: Email

    public static func emailEnabled(forDestination id: String) -> Bool {
        // Kindle reuses the existing "Also Send to Kindle" import toggle so the
        // two surfaces never diverge (email only ever arrives via the importer,
        // which historically sent only to Kindle).
        if id == ArticleDestinationID.kindle { return KindleSendSettings.autoSendToKindle }
        return boolWithDefault(key(id, "email"), default: legacyDefault(forDestination: id))
    }

    public static func setEmailEnabled(_ on: Bool, forDestination id: String) {
        if id == ArticleDestinationID.kindle {
            KindleSendSettings.autoSendToKindle = on
            return
        }
        defaults.set(on, forKey: key(id, "email"))
    }

    // MARK: Share sheet & paste

    public static func shareAndPasteEnabled(forDestination id: String) -> Bool {
        boolWithDefault(key(id, "sharePaste"), default: legacyDefault(forDestination: id))
    }

    public static func setShareAndPasteEnabled(_ on: Bool, forDestination id: String) {
        defaults.set(on, forKey: key(id, "sharePaste"))
    }

    // MARK: Friend shares (default + per-friend overrides)

    /// The default for friends without an explicit override.
    public static func friendSharesEnabledDefault(forDestination id: String) -> Bool {
        boolWithDefault(key(id, "friendDefault"), default: legacyDefault(forDestination: id))
    }

    public static func setFriendSharesEnabledDefault(_ on: Bool, forDestination id: String) {
        defaults.set(on, forKey: key(id, "friendDefault"))
    }

    /// Per-friend enablement, falling back to the destination's friend default.
    public static func friendShareEnabled(forDestination id: String, username: String) -> Bool {
        friendOverrides(forDestination: id)[username] ?? friendSharesEnabledDefault(forDestination: id)
    }

    public static func setFriendShareEnabled(_ on: Bool, forDestination id: String, username: String) {
        var overrides = friendOverrides(forDestination: id)
        overrides[username] = on
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: key(id, "friendOverrides"))
        }
    }

    private static func friendOverrides(forDestination id: String) -> [String: Bool] {
        guard let data = defaults.data(forKey: key(id, "friendOverrides")),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }

    // MARK: Resolution

    /// The effective send mode for an item, given its capture source and (for
    /// friend shares) the sharing friend's username.
    public static func sendMode(
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

    /// An absent value is the legacy default; a STORED one is honoured even
    /// when it is `false`, which is the whole reason this is not `bool(forKey:)`.
    private static func boolWithDefault(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? def : defaults.bool(forKey: key)
    }
}
