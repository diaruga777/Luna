//
//  IncomingMailSettings.swift
//  Luna
//

import Foundation

/// Settings for turning incoming emails (from allowed senders) into reading-list
/// items. Reuses the send-to-Kindle Gmail account + app password. Persisted in
/// standard defaults; the UID cursor dedupes processed mail.
public enum IncomingMailSettings {
    private static let enabledKey = "incomingMailEnabled"
    private static let sendersKey = "incomingMailAllowedSenders"
    private static let subjectFiltersKey = "incomingMailSubjectFilters"
    private static let lastUIDKey = "incomingMailLastUID"
    private static let uidValidityKey = "incomingMailUIDValidity"
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

    /// Highest IMAP UID processed (dedupe cursor).
    public static var lastUID: Int {
        get { UserDefaults.standard.integer(forKey: lastUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastUIDKey) }
    }

    /// Mailbox UIDVALIDITY the cursor belongs to (0 = unknown). A change resets
    /// the cursor.
    public static var uidValidity: Int {
        get { UserDefaults.standard.integer(forKey: uidValidityKey) }
        set { UserDefaults.standard.set(newValue, forKey: uidValidityKey) }
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
