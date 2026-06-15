//
//  IncomingMailSettings.swift
//  Clip
//

import Foundation

/// Settings for turning incoming emails (from allowed senders) into reading-list
/// items. Reuses the send-to-Kindle Gmail account + app password. Persisted in
/// standard defaults; the UID cursor dedupes processed mail.
enum IncomingMailSettings {
    private static let enabledKey = "incomingMailEnabled"
    private static let sendersKey = "incomingMailAllowedSenders"
    private static let lastUIDKey = "incomingMailLastUID"
    private static let uidValidityKey = "incomingMailUIDValidity"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Allowed sender email addresses; mail from these is imported.
    static var allowedSenders: [String] {
        get { UserDefaults.standard.stringArray(forKey: sendersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: sendersKey) }
    }

    /// Highest IMAP UID processed (dedupe cursor).
    static var lastUID: Int {
        get { UserDefaults.standard.integer(forKey: lastUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastUIDKey) }
    }

    /// Mailbox UIDVALIDITY the cursor belongs to (0 = unknown). A change resets
    /// the cursor.
    static var uidValidity: Int {
        get { UserDefaults.standard.integer(forKey: uidValidityKey) }
        set { UserDefaults.standard.set(newValue, forKey: uidValidityKey) }
    }

    static func addSender(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !allowedSenders.contains(trimmed) else { return }
        allowedSenders.append(trimmed)
    }

    static func removeSender(at index: Int) {
        guard allowedSenders.indices.contains(index) else { return }
        allowedSenders.remove(at: index)
    }
}
