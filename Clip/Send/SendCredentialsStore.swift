//
//  SendCredentialsStore.swift
//  Clip
//

import Foundation
import Security

/// Holds the SMTP app password (the one secret in the send-to-Kindle feature).
protocol SendCredentialsStoring {
    /// The stored SMTP password, if any.
    func smtpPassword() -> String?
    /// Stores (or, with nil/empty, deletes) the SMTP password.
    func setSMTPPassword(_ password: String?)
}

/// Keychain-backed credential storage. Sends always run in the main app
/// process, so no shared access group is needed.
final class KeychainSendCredentialsStore: SendCredentialsStoring {

    static let shared = KeychainSendCredentialsStore()

    private let service = "com.hpiddy.clip.smtp"
    private let account = "smtp-password"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func smtpPassword() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func setSMTPPassword(_ password: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// In-memory stand-in for tests.
final class InMemorySendCredentialsStore: SendCredentialsStoring {
    private var password: String?
    func smtpPassword() -> String? { password }
    func setSMTPPassword(_ newPassword: String?) {
        password = (newPassword?.isEmpty ?? true) ? nil : newPassword
    }
}
