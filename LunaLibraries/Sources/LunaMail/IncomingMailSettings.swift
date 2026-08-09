//
//  IncomingMailSettings.swift
//  Luna
//

import Foundation
import LunaMailAccount

/// Settings for turning incoming emails (from allowed senders) into reading-list
/// items. Reuses the send-to-Kindle Gmail account + app password. Persisted in
/// standard defaults; the cursor dedupes processed mail.
public enum IncomingMailSettings {
    private static let enabledKey = "incomingMailEnabled"
    private static let sendersKey = "incomingMailAllowedSenders"
    private static let subjectFiltersKey = "incomingMailSubjectFilters"
    private static let autoSendKey = "incomingMailAutoSendToKindle"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// When on (and Send-to-Kindle is configured), imported-email articles are
    /// also sent to Kindle.
    public static var autoSendToKindle: Bool {
        get { UserDefaults.standard.bool(forKey: autoSendKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSendKey) }
    }

    /// Allowed sender email addresses; mail from these is imported.
    public static var allowedSenders: [String] {
        get { UserDefaults.standard.stringArray(forKey: sendersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: sendersKey) }
    }

    /// Subject-line substrings; mail whose subject fuzzily contains any of these
    /// is imported regardless of sender (e.g. "Money Stuff"). Matched
    /// server-side via IMAP `SUBJECT` search (case-insensitive substring).
    public static var subjectFilters: [String] {
        get { UserDefaults.standard.stringArray(forKey: subjectFiltersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: subjectFiltersKey) }
    }

    /// The dedupe cursor persisted between fetches, as one JSON blob under
    /// `cursorKey`. Used to be shredded into three independent prefs (an IMAP
    /// uid, its UIDVALIDITY, and a separate Graph token) that any reader had to
    /// reassemble by hand into a `MailCursor` — reassembly that couldn't tell
    /// which provider's half was meaningful. On first read after upgrading, a
    /// pre-existing installation migrates those three legacy keys once (see
    /// `migrateLegacyCursor`) and never looks at them again.
    public static var cursor: MailCursor {
        get {
            if let data = UserDefaults.standard.data(forKey: cursorKey),
               let decoded = try? JSONDecoder().decode(MailCursor.self, from: data) {
                return decoded
            }
            return migrateLegacyCursor()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: cursorKey)
        }
    }

    private static let cursorKey = "incomingMailCursor"
    private static let legacyLastUIDKey = "incomingMailLastUID"
    private static let legacyUIDValidityKey = "incomingMailUIDValidity"
    private static let legacyCursorTokenKey = "incomingMailCursorToken"

    /// Reconstructs the pre-migration cursor from its three shredded prefs,
    /// persists it under `cursorKey` so this runs at most once, and returns it.
    /// An install with none of the legacy keys set (a fresh install, or one
    /// that already migrated) reads as `.fresh`.
    private static func migrateLegacyCursor() -> MailCursor {
        let defaults = UserDefaults.standard
        let legacyUID = defaults.integer(forKey: legacyLastUIDKey)
        let migrated: MailCursor
        if legacyUID > 0 {
            migrated = .imap(
                uid: legacyUID, uidValidity: defaults.integer(forKey: legacyUIDValidityKey))
        } else if let token = defaults.string(forKey: legacyCursorTokenKey), !token.isEmpty {
            migrated = .graph(token: token)
        } else {
            migrated = .fresh
        }
        cursor = migrated
        return migrated
    }

    public static func addSender(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !allowedSenders.contains(trimmed) else { return }
        allowedSenders.append(trimmed)
    }

    public static func removeSender(at index: Int) {
        guard allowedSenders.indices.contains(index) else { return }
        allowedSenders.remove(at: index)
    }

    public static func addSubjectFilter(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !subjectFilters.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        subjectFilters.append(trimmed)
    }

    public static func removeSubjectFilter(at index: Int) {
        guard subjectFilters.indices.contains(index) else { return }
        subjectFilters.remove(at: index)
    }
}
