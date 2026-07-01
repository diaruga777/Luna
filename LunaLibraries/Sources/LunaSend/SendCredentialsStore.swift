//
//  SendCredentialsStore.swift
//  Luna
//

import Foundation
import Security

/// Holds the secrets for the ereader send features: the SMTP app password
/// (Kindle) and the Send2Boox auth token (Boox).
public protocol SendCredentialsStoring {
    /// The stored SMTP password, if any.
    func smtpPassword() -> String?
    /// Stores (or, with nil/empty, deletes) the SMTP password.
    func setSMTPPassword(_ password: String?)
    /// The stored Send2Boox auth token, if any.
    func booxToken() -> String?
    /// Stores (or, with nil/empty, deletes) the Send2Boox auth token.
    func setBooxToken(_ token: String?)
}

/// Keychain-backed credential storage. Sends always run in the main app
/// process, so no shared access group is needed.
public final class KeychainSendCredentialsStore: SendCredentialsStoring {

    public static let shared = KeychainSendCredentialsStore()

    private let smtpService = "com.hsanabria.luna.smtp"
    private let smtpAccount = "smtp-password"
    private let booxService = "com.hsanabria.luna.boox"
    private let booxAccount = "boox-token"

    public func smtpPassword() -> String? { read(service: smtpService, account: smtpAccount) }
    public func setSMTPPassword(_ password: String?) {
        write(password, service: smtpService, account: smtpAccount)
    }

    public func booxToken() -> String? { read(service: booxService, account: booxAccount) }
    public func setBooxToken(_ token: String?) {
        write(token, service: booxService, account: booxAccount)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ value: String?, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}

/// In-memory stand-in for tests.
public final class InMemorySendCredentialsStore: SendCredentialsStoring {
    private var password: String?
    private var token: String?

    public init() {}

    public func smtpPassword() -> String? { password }
    public func setSMTPPassword(_ newPassword: String?) {
        password = (newPassword?.isEmpty ?? true) ? nil : newPassword
    }

    public func booxToken() -> String? { token }
    public func setBooxToken(_ newToken: String?) {
        token = (newToken?.isEmpty ?? true) ? nil : newToken
    }
}
